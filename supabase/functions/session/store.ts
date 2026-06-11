// =============================================================================
// SessionStore — the DB operations the `session` handler needs (Phase G).
// =============================================================================
// The handler depends on this interface, not on the Supabase client, so the
// §14.6 staleness re-check is unit-testable with an in-memory fake (no Postgres,
// no LemonSqueezy). The production impl (SupabaseSessionStore) wraps the SHARED
// service-role client + the SHARED rate limiter (check_rate_limit) and reuses
// buildEntitlementSnapshot so `session` and `entitlement` can't drift. We do NOT
// weaken RLS: every read/write goes through the service role inside the function.
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { EntitlementSnapshot } from "../_shared/types.ts";
import type { Tier } from "../_shared/config.ts";
import { buildEntitlementSnapshot, type SubscriptionRow } from "../_shared/entitlement.ts";

/** The subscription fields the session flow + the staleness re-check read. */
export interface SessionSubRow {
  id: string;
  ls_subscription_id: string;
  tier: Tier;
  status: "active" | "past_due" | "cancelled" | "expired";
  credits_limit: number;
  current_period_end: string | null;
  /** Phase 5 metadata; NULL on pre-Phase-5 rows (treated as monthly). E8: the
   *  snapshot shows a yearly sub its NEXT MONTHLY refresh date, not year end. */
  billing_interval?: "monthly" | "yearly" | null;
  /** Mirror freshness anchor: last webhook write OR live re-check reconcile. */
  updated_at: string | null;
}

export interface SessionStore {
  /** TRUE if within the limit for the current window (fail-open on infra error). */
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
  /** The subscription mirror row for a license-key hash, or null. */
  findByKeyHash(keyHash: string): Promise<SessionSubRow | null>;
  /**
   * Reconcile the mirror's status to a live LemonSqueezy answer (§14.6). Any
   * write resets the freshness anchor (`updated_at`) via set_updated_at, so a
   * just-reconciled subscription skips the next live re-check. Idempotent.
   */
  reconcileStatus(id: string, status: SessionSubRow["status"]): Promise<void>;
  /** Build the display snapshot (credits remaining / reset date) for a row. */
  buildSnapshot(sub: SessionSubRow): Promise<EntitlementSnapshot>;
}

export class SupabaseSessionStore implements SessionStore {
  constructor(private readonly db: SupabaseClient) {}

  async rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_rate_limit", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      // Fail OPEN on limiter infra error: a broken limiter must not lock out a
      // paying user. (Spend is still gated server-side at generate time.)
      console.error(JSON.stringify({ fn: "session", op: "rateLimit", error: error.message }));
      return true;
    }
    return data === true;
  }

  async findByKeyHash(keyHash: string): Promise<SessionSubRow | null> {
    const { data, error } = await this.db
      .from("subscriptions")
      .select("id, ls_subscription_id, tier, status, credits_limit, current_period_end, billing_interval, updated_at")
      .eq("license_key_hash", keyHash)
      .maybeSingle();
    if (error) {
      console.error(JSON.stringify({ fn: "session", op: "findByKeyHash", error: error.message }));
      throw error;
    }
    return (data as SessionSubRow) ?? null;
  }

  async reconcileStatus(id: string, status: SessionSubRow["status"]): Promise<void> {
    const { error } = await this.db
      .from("subscriptions")
      .update({ status })
      .eq("id", id);
    if (error) {
      // A failed reconcile is not fatal to THIS request (we already have the
      // live answer and act on it); the next stale re-check will retry.
      console.error(JSON.stringify({ fn: "session", op: "reconcileStatus", error: error.message }));
    }
  }

  buildSnapshot(sub: SessionSubRow): Promise<EntitlementSnapshot> {
    return buildEntitlementSnapshot(this.db, sub as SubscriptionRow);
  }
}
