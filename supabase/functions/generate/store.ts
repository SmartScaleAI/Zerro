// =============================================================================
// BillingStore — the DB operations the `generate` handler needs (Phase D2).
// =============================================================================
// The handler depends on this interface, not on the Supabase client, so tests
// inject an in-memory fake (InMemoryBillingStore) and never touch Postgres. The
// production impl (SupabaseBillingStore) wraps the SHARED service-role client and
// the SHARED SQL primitives — consume_credit / check_rate_limit (D1) and
// acquire/release_generation_slot (D2 migration). We do NOT reinvent any of
// them, and we do NOT weaken RLS: every read/write goes through the service role
// inside the function (the only principal RLS permits).
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { Tier } from "../_shared/config.ts";

export interface SubRow {
  id: string;
  tier: Tier;
  status: "active" | "past_due" | "cancelled" | "expired";
  credits_limit: number;
}

export interface GenerationLogRow {
  subscriptionId: string;
  tokensIn: number | null;
  tokensOut: number | null;
  estCostUsd: number | null;
  success: boolean;
}

export interface BillingStore {
  loadSubscription(id: string): Promise<SubRow | null>;
  /** Remaining credits on the subscription's LATEST period (consume_credit's target). */
  creditsRemaining(subId: string, creditsLimit: number): Promise<number>;
  /** Atomic spend; remaining after, or null if none could be spent. */
  consumeCredit(subId: string): Promise<number | null>;
  acquireSlot(subId: string, staleSeconds: number): Promise<boolean>;
  releaseSlot(subId: string): Promise<void>;
  /** TRUE if within the limit for the current window (fail-open on infra error). */
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
  logGeneration(row: GenerationLogRow): Promise<void>;
}

export class SupabaseBillingStore implements BillingStore {
  constructor(private readonly db: SupabaseClient) {}

  async loadSubscription(id: string): Promise<SubRow | null> {
    const { data, error } = await this.db
      .from("subscriptions")
      .select("id, tier, status, credits_limit")
      .eq("id", id)
      .maybeSingle();
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "loadSubscription", error: error.message }));
      throw error;
    }
    return (data as SubRow) ?? null;
  }

  async creditsRemaining(subId: string, creditsLimit: number): Promise<number> {
    // Latest period = the row consume_credit targets, so the availability check
    // and the actual spend agree.
    const { data } = await this.db
      .from("usage_periods")
      .select("credits_used")
      .eq("subscription_id", subId)
      .order("period_start", { ascending: false })
      .limit(1)
      .maybeSingle();
    const used = data?.credits_used ?? creditsLimit; // no period → exhausted
    return Math.max(0, creditsLimit - used);
  }

  async consumeCredit(subId: string): Promise<number | null> {
    const { data, error } = await this.db.rpc("consume_credit", { p_subscription_id: subId });
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "consumeCredit", error: error.message }));
      throw error;
    }
    return data === null || data === undefined ? null : Number(data);
  }

  async acquireSlot(subId: string, staleSeconds: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("acquire_generation_slot", {
      p_subscription_id: subId,
      p_stale_seconds: staleSeconds,
    });
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "acquireSlot", error: error.message }));
      throw error;
    }
    return data === true;
  }

  async releaseSlot(subId: string): Promise<void> {
    const { error } = await this.db.rpc("release_generation_slot", { p_subscription_id: subId });
    if (error) {
      // A failed release is not fatal: the slot's stale-reclaim window frees it.
      console.error(JSON.stringify({ fn: "generate", op: "releaseSlot", error: error.message }));
    }
  }

  async rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_rate_limit", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      // Fail OPEN: a broken limiter must not lock out a paying user. Spend is
      // still gated by the credit check + consume_credit.
      console.error(JSON.stringify({ fn: "generate", op: "rateLimit", error: error.message }));
      return true;
    }
    return data === true;
  }

  async logGeneration(row: GenerationLogRow): Promise<void> {
    // Token counts + cost + success ONLY. NEVER transcript / audio / frames /
    // prompt (§14.5). The table has no content columns by design.
    const { error } = await this.db.from("generation_log").insert({
      subscription_id: row.subscriptionId,
      tokens_in: row.tokensIn,
      tokens_out: row.tokensOut,
      est_cost_usd: row.estCostUsd,
      success: row.success,
    });
    if (error) {
      // Logging is best-effort analytics; never fail a paid generation over it.
      console.error(JSON.stringify({ fn: "generate", op: "logGeneration", error: error.message }));
    }
  }
}
