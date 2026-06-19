// Builds the read-only entitlement snapshot (tier / status / credits remaining /
// reset date) from a subscription row. Shared by `session` and `entitlement` so
// the two endpoints can never drift in how they compute credits-remaining.
//
// credits_remaining (Phase 4 / F4) = the COMBINED spendable balance:
//   plan remaining (credits_limit - credits_used of the LATEST usage_period,
//   greatest period_start) + non-expired top-up credits —
// the same two buckets, same filters, the 2-arg consume_credit spends against,
// so the number the app displays matches what the spend path will allow. The
// plan-only figures ride alongside (plan_credits_used/_limit) for the usage
// meter, and the top-up balance is broken out for the settings view.
// A `past_due` subscriber therefore shows the *remaining* credits of the last
// paid period (no fresh allowance until payment_success), per §9.1.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { EntitlementSnapshot } from "./types.ts";
import type { Tier } from "./config.ts";

export interface SubscriptionRow {
  id: string;
  tier: Tier;
  status: "active" | "past_due" | "cancelled" | "expired";
  credits_limit: number;
  current_period_end: string | null;
  /** Phase 5 metadata; NULL on pre-Phase-5 rows (treated as monthly). */
  billing_interval?: "monthly" | "yearly" | null;
  /** The trial_grants row this subscriber converted from, or null. When set, the
   *  grant's remaining credits are spendable FIRST (consume_combined_credit), so
   *  the displayed combined balance must include them — see below. */
  trial_grant_id?: string | null;
}

/**
 * Postgres `+ interval '1 month'` semantics: the day-of-month clamps to the
 * target month's length (Jan 31 → Feb 28), time-of-day preserved. Must match
 * refresh_yearly_credit_periods()'s anchor arithmetic so the displayed reset
 * date is the date the cron job will actually roll the next period.
 */
function addOneMonthClamped(from: Date): Date {
  const d = new Date(from);
  const day = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + 1);
  const daysInTarget = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  d.setUTCDate(Math.min(day, daysInTarget));
  return d;
}

export async function buildEntitlementSnapshot(
  db: SupabaseClient,
  sub: SubscriptionRow,
): Promise<EntitlementSnapshot> {
  // Latest period for this subscription (matches consume_credit's target row).
  const { data: period } = await db
    .from("usage_periods")
    .select("credits_used, period_start")
    .eq("subscription_id", sub.id)
    .order("period_start", { ascending: false })
    .limit(1)
    .maybeSingle();

  const used = period?.credits_used ?? sub.credits_limit; // no period → treat as exhausted
  const planRemaining = Math.max(0, sub.credits_limit - used);

  // Non-expired top-up packs (Phase 4 / F4) — same expiry filter the spend path
  // (consume_credit 2-arg) applies. A read error counts as 0: fail-SAFE — the
  // display may briefly undercount, but it never shows credits the spend path
  // would refuse.
  const { data: topups, error: topupError } = await db
    .from("topup_credits")
    .select("credits_total, credits_used")
    .eq("subscription_id", sub.id)
    .gt("expires_at", new Date().toISOString());
  if (topupError) {
    console.error(JSON.stringify({ fn: "entitlement", op: "topupRemaining", error: topupError.message }));
  }
  const topupRemaining = (topups ?? []).reduce(
    (sum, t) => sum + Math.max(0, Number(t.credits_total) - Number(t.credits_used)),
    0,
  );

  // Linked trial remainder (the conversion link). A converted user spends the
  // trial remainder FIRST (consume_combined_credit), so the headline combined
  // balance MUST include it or the displayed number would understate what the
  // spend path allows — the contract this file's header promises. Only a
  // VERIFIED grant contributes; a read error counts as 0 (fail-SAFE: the display
  // may briefly undercount, never overstate). Broken out as
  // trial_credits_remaining for transparency.
  let trialRemaining = 0;
  if (sub.trial_grant_id) {
    const { data: grant, error: grantError } = await db
      .from("trial_grants")
      .select("trial_credits_limit, trial_credits_used, verified_at")
      .eq("id", sub.trial_grant_id)
      .maybeSingle();
    if (grantError) {
      console.error(JSON.stringify({ fn: "entitlement", op: "trialRemaining", error: grantError.message }));
    } else if (grant && grant.verified_at) {
      trialRemaining = Math.max(0, Number(grant.trial_credits_limit) - Number(grant.trial_credits_used));
    }
  }

  // reset_date (E8): for a MONTHLY sub, credits reset at the period end LS
  // renews on — current_period_end. For a YEARLY sub, current_period_end is the
  // ANNUAL renewal, but credits actually refresh monthly via the
  // refresh-yearly-credits cron job (refresh_yearly_credit_periods), so the
  // app's "Resets {date}" must show the NEXT monthly anchor: latest
  // period_start + 1 month, capped at the year end (strict < in the job — at
  // the boundary the annual renewal itself is the reset). Money is unaffected;
  // this is display only.
  let resetDate = sub.current_period_end;
  if (sub.billing_interval === "yearly" && sub.current_period_end && period?.period_start) {
    const anchor = addOneMonthClamped(new Date(period.period_start));
    const yearEnd = new Date(sub.current_period_end);
    resetDate = (anchor.getTime() < yearEnd.getTime() ? anchor : yearEnd).toISOString();
  }

  return {
    tier: sub.tier,
    status: sub.status,
    credits_remaining: planRemaining + topupRemaining + trialRemaining,
    credits_limit: sub.credits_limit,
    reset_date: resetDate,
    plan_credits_used: Math.min(used, sub.credits_limit),
    plan_credits_limit: sub.credits_limit,
    topup_credits_remaining: topupRemaining,
    trial_credits_remaining: trialRemaining,
  };
}
