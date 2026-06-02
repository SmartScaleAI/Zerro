// Builds the read-only entitlement snapshot (tier / status / credits remaining /
// reset date) from a subscription row. Shared by `session` and `entitlement` so
// the two endpoints can never drift in how they compute credits-remaining.
//
// credits_remaining = credits_limit - credits_used of the LATEST usage_period
// (greatest period_start) — the same "current period" definition consume_credit
// uses, so the number the app displays matches what the spend path will allow.
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
}

export async function buildEntitlementSnapshot(
  db: SupabaseClient,
  sub: SubscriptionRow,
): Promise<EntitlementSnapshot> {
  // Latest period for this subscription (matches consume_credit's target row).
  const { data: period } = await db
    .from("usage_periods")
    .select("credits_used")
    .eq("subscription_id", sub.id)
    .order("period_start", { ascending: false })
    .limit(1)
    .maybeSingle();

  const used = period?.credits_used ?? sub.credits_limit; // no period → treat as exhausted
  const remaining = Math.max(0, sub.credits_limit - used);

  return {
    tier: sub.tier,
    status: sub.status,
    credits_remaining: remaining,
    credits_limit: sub.credits_limit,
    reset_date: sub.current_period_end,
  };
}
