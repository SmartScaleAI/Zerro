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

/** The subset of a trial_grants row the trial generate branch reads (Phase F). */
export interface TrialGrantRow {
  id: string;
  verified_at: string | null;
  trial_credits_limit: number;
  trial_credits_used: number;
}

export interface GenerationLogRow {
  /** Subscription id, or null for a trial generation (no subscription FK). */
  subscriptionId: string | null;
  tokensIn: number | null;
  tokensOut: number | null;
  estCostUsd: number | null;
  success: boolean;
  /** Phase 4 — the VALIDATED selected model + its provider (non-content
   *  attribution metadata, §14.5-compatible). Known from validation on, so
   *  failure rows are attributable too (per-model failure-rate calibration). */
  model: string;
  provider: string;
}

/** A cached generation result, replayed verbatim for a retry carrying the same
 *  Idempotency-Key (M1). The one persisted-content shape (documented §14.5
 *  carve-out — see idempotency_cache migration). */
export interface IdempotentResult {
  prompt: string;
  usage: { input_tokens: number; output_tokens: number; model: string };
  creditsRemaining: number;
  /** Credits charged for the ORIGINAL generation (D2) — replayed verbatim so a
   *  retry reports the same charge (0 on the uncharged-race path). */
  creditsCharged: number;
}

export interface BillingStore {
  loadSubscription(id: string): Promise<SubRow | null>;
  /** COMBINED remaining balance: the latest plan period + non-expired top-up
   *  packs (Phase 4 / F4) — the same definition the 2-arg consume_credit spends
   *  against, so the availability check and the spend can't disagree. */
  creditsRemaining(subId: string, creditsLimit: number): Promise<number>;
  /** Atomically spend `credits` (plan first, then top-ups FIFO by expiry —
   *  Phase 1's consume_credit(uuid, integer)). All-or-nothing: COMBINED
   *  remaining after the spend, or null with NOTHING spent if the combined
   *  balance can't cover it. */
  consumeCredit(subId: string, credits: number): Promise<number | null>;
  acquireSlot(subId: string, staleSeconds: number): Promise<boolean>;
  releaseSlot(subId: string): Promise<void>;
  /** TRUE if within the limit for the current window (fail-open on infra error). */
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
  logGeneration(row: GenerationLogRow): Promise<void>;

  // ---- Idempotency cache (M1) — dedupes a charged-but-dropped /generate so a
  // retry carrying the same key replays the result instead of charging again.
  /** Cached result for (identityKey, idemKey) if present and newer than
   *  ttlSeconds; else null. Fail-OPEN (null) on infra error — a broken cache
   *  must never block a paid generation. */
  getIdempotent(
    identityKey: string,
    idemKey: string,
    ttlSeconds: number,
  ): Promise<IdempotentResult | null>;
  /** Cache a charged result, then opportunistically prune rows older than
   *  ttlSeconds (the content-retention window). Best-effort: a failed write
   *  never fails an already-charged generation. */
  putIdempotent(
    identityKey: string,
    idemKey: string,
    value: IdempotentResult,
    ttlSeconds: number,
  ): Promise<void>;

  // ---- Trial path (Phase F) — mirrors the subscription primitives, keyed on a
  // trial_grants row id instead of a subscription id.
  /** The trial grant for `grantId`, or null if it doesn't exist. */
  loadTrialGrant(grantId: string): Promise<TrialGrantRow | null>;
  /** Remaining trial credits on the grant (single bucket — no top-ups). */
  trialCreditsRemaining(grantId: string): Promise<number>;
  /** Atomically spend `credits` from the grant (Phase 1's 2-arg RPC).
   *  All-or-nothing: remaining after, or null with nothing spent. */
  consumeTrialCredit(grantId: string, credits: number): Promise<number | null>;
  acquireTrialSlot(grantId: string, staleSeconds: number): Promise<boolean>;
  releaseTrialSlot(grantId: string): Promise<void>;
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
    const planRemaining = Math.max(0, creditsLimit - used);

    // Plus non-expired top-up packs (Phase 4 / F4) — the same filter the 2-arg
    // consume_credit spends against. On a read error, count top-ups as 0: the
    // fail-SAFE direction (undercount → at worst a spurious 402, never a spend
    // the atomic consume wouldn't also allow; consume_credit stays the guard).
    const { data: topups, error: topupError } = await this.db
      .from("topup_credits")
      .select("credits_total, credits_used")
      .eq("subscription_id", subId)
      .gt("expires_at", new Date().toISOString());
    if (topupError) {
      console.error(JSON.stringify({ fn: "generate", op: "topupRemaining", error: topupError.message }));
      return planRemaining;
    }
    const topupRemaining = (topups ?? []).reduce(
      (sum, t) => sum + Math.max(0, Number(t.credits_total) - Number(t.credits_used)),
      0,
    );
    return planRemaining + topupRemaining;
  }

  async consumeCredit(subId: string, credits: number): Promise<number | null> {
    // The 2-arg overload (Phase 1): variable, two-bucket, all-or-nothing.
    const { data, error } = await this.db.rpc("consume_credit", {
      p_subscription_id: subId,
      p_credits: credits,
    });
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
      model: row.model,
      provider: row.provider,
    });
    if (error) {
      // Logging is best-effort analytics; never fail a paid generation over it.
      console.error(JSON.stringify({ fn: "generate", op: "logGeneration", error: error.message }));
    }
  }

  // ---- Idempotency cache (M1) -----------------------------------------------

  async getIdempotent(
    identityKey: string,
    idemKey: string,
    ttlSeconds: number,
  ): Promise<IdempotentResult | null> {
    const cutoff = new Date(Date.now() - ttlSeconds * 1000).toISOString();
    const { data, error } = await this.db
      .from("idempotency_cache")
      .select("prompt, usage, credits_remaining, credits_charged")
      .eq("identity_key", identityKey)
      .eq("idempotency_key", idemKey)
      .gt("created_at", cutoff) // ignore rows past the retention window
      .maybeSingle();
    if (error) {
      // Fail OPEN: a broken cache read must not block a paid generation. The
      // worst case is the pre-M1 behavior (the retry re-charges) — never a
      // lock-out. Spend is still gated by consume_credit.
      console.error(JSON.stringify({ fn: "generate", op: "getIdempotent", error: error.message }));
      return null;
    }
    if (!data) return null;
    return {
      prompt: String(data.prompt),
      usage: data.usage as IdempotentResult["usage"],
      creditsRemaining: Number(data.credits_remaining),
      // NULL only on pre-D2 rows, which age out within the TTL.
      creditsCharged: Number(data.credits_charged ?? 0),
    };
  }

  async putIdempotent(
    identityKey: string,
    idemKey: string,
    value: IdempotentResult,
    ttlSeconds: number,
  ): Promise<void> {
    const { error } = await this.db.from("idempotency_cache").upsert({
      identity_key: identityKey,
      idempotency_key: idemKey,
      prompt: value.prompt,
      usage: value.usage,
      credits_remaining: value.creditsRemaining,
      credits_charged: value.creditsCharged,
      created_at: new Date().toISOString(),
    }, { onConflict: "identity_key,idempotency_key" });
    if (error) {
      // Best-effort, like logGeneration: never fail an already-charged
      // generation over the cache. A lost write just means a retry could
      // re-charge (the rare pre-M1 case), not a broken response.
      console.error(JSON.stringify({ fn: "generate", op: "putIdempotent", error: error.message }));
    }

    // Opportunistic prune so a generated prompt never lingers past the TTL even
    // without a scheduled sweep (the §14.5 carve-out is time-bounded by design).
    const cutoff = new Date(Date.now() - ttlSeconds * 1000).toISOString();
    const { error: pruneError } = await this.db
      .from("idempotency_cache")
      .delete()
      .lt("created_at", cutoff);
    if (pruneError) {
      console.error(JSON.stringify({ fn: "generate", op: "pruneIdempotent", error: pruneError.message }));
    }
  }

  // ---- Trial path (Phase F) -------------------------------------------------

  async loadTrialGrant(grantId: string): Promise<TrialGrantRow | null> {
    const { data, error } = await this.db
      .from("trial_grants")
      .select("id, verified_at, trial_credits_limit, trial_credits_used")
      .eq("id", grantId)
      .maybeSingle();
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "loadTrialGrant", error: error.message }));
      throw error;
    }
    return (data as TrialGrantRow) ?? null;
  }

  async trialCreditsRemaining(grantId: string): Promise<number> {
    const grant = await this.loadTrialGrant(grantId);
    if (!grant) return 0;
    return Math.max(0, grant.trial_credits_limit - grant.trial_credits_used);
  }

  async consumeTrialCredit(grantId: string, credits: number): Promise<number | null> {
    // The 2-arg overload (Phase 1): variable all-or-nothing single-bucket spend.
    const { data, error } = await this.db.rpc("consume_trial_credit", {
      p_grant_id: grantId,
      p_credits: credits,
    });
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "consumeTrialCredit", error: error.message }));
      throw error;
    }
    return data === null || data === undefined ? null : Number(data);
  }

  async acquireTrialSlot(grantId: string, staleSeconds: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("acquire_trial_slot", {
      p_grant_id: grantId,
      p_stale_seconds: staleSeconds,
    });
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "acquireTrialSlot", error: error.message }));
      throw error;
    }
    return data === true;
  }

  async releaseTrialSlot(grantId: string): Promise<void> {
    const { error } = await this.db.rpc("release_trial_slot", { p_grant_id: grantId });
    if (error) {
      console.error(JSON.stringify({ fn: "generate", op: "releaseTrialSlot", error: error.message }));
    }
  }
}
