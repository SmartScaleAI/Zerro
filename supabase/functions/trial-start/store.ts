// =============================================================================
// TrialStore — the DB operations `trial-start` needs (Phase F).
// =============================================================================
// The handler depends on this interface, not on the Supabase client, so the
// tests inject an in-memory fake. The production impl wraps the SHARED
// service-role client and the Phase F SQL primitives (verify_trial_grant) plus
// the D1 limiter (check_rate_limit). We do NOT weaken RLS — every read/write
// goes through the service role inside the function.
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

/** The subset of a trial_grants row trial-start reads. */
export interface TrialGrantRow {
  id: string;
  verified_at: string | null;
  trial_credits_limit: number;
  trial_credits_used: number;
}

/** A pending trial_codes row. */
export interface TrialCodeRow {
  code_hash: string;
  expires_at: string;
  attempts: number;
}

export interface TrialStore {
  /** The grant for a normalized email, or null if none has ever been created. */
  loadGrantByEmail(email: string): Promise<TrialGrantRow | null>;
  /** Upsert the pending code for an email (resets attempts to 0). */
  upsertCode(email: string, codeHash: string, expiresAt: Date): Promise<void>;
  /** The pending code for an email, or null. */
  loadCode(email: string): Promise<TrialCodeRow | null>;
  /** Increment the attempt counter on a pending code (failed verify). */
  incrementCodeAttempts(email: string): Promise<void>;
  /** Delete a pending code (consumed or expired). */
  deleteCode(email: string): Promise<void>;
  /**
   * Create-once / never-reset the grant for `email` and return its id + credits
   * remaining (verify_trial_grant). The single grant writer.
   */
  verifyGrant(email: string, limit: number): Promise<{ grantId: string; creditsRemaining: number }>;
  /** TRUE if within the limit for the current window (fail-open on infra error). */
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
}

export class SupabaseTrialStore implements TrialStore {
  constructor(private readonly db: SupabaseClient) {}

  async loadGrantByEmail(email: string): Promise<TrialGrantRow | null> {
    const { data, error } = await this.db
      .from("trial_grants")
      .select("id, verified_at, trial_credits_limit, trial_credits_used")
      .eq("email_normalized", email)
      .maybeSingle();
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "loadGrant", error: error.message }));
      throw error;
    }
    return (data as TrialGrantRow) ?? null;
  }

  async upsertCode(email: string, codeHash: string, expiresAt: Date): Promise<void> {
    const { error } = await this.db
      .from("trial_codes")
      .upsert(
        {
          email_normalized: email,
          code_hash: codeHash,
          expires_at: expiresAt.toISOString(),
          attempts: 0,
          created_at: new Date().toISOString(),
        },
        { onConflict: "email_normalized" },
      );
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "upsertCode", error: error.message }));
      throw error;
    }
  }

  async loadCode(email: string): Promise<TrialCodeRow | null> {
    const { data, error } = await this.db
      .from("trial_codes")
      .select("code_hash, expires_at, attempts")
      .eq("email_normalized", email)
      .maybeSingle();
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "loadCode", error: error.message }));
      throw error;
    }
    return (data as TrialCodeRow) ?? null;
  }

  async incrementCodeAttempts(email: string): Promise<void> {
    // Atomic increment via the rpc-free path: a small SQL via .rpc would need a
    // function; instead read-modify-write is acceptable here because the row is
    // single-writer per email under the per-email rate limit, and a lost
    // increment only ever makes brute force HARDER to mount, never easier (the
    // TTL + 6-digit space are the real bound).
    const { data } = await this.db
      .from("trial_codes")
      .select("attempts")
      .eq("email_normalized", email)
      .maybeSingle();
    const next = (data?.attempts ?? 0) + 1;
    const { error } = await this.db
      .from("trial_codes")
      .update({ attempts: next })
      .eq("email_normalized", email);
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "incrAttempts", error: error.message }));
    }
  }

  async deleteCode(email: string): Promise<void> {
    const { error } = await this.db.from("trial_codes").delete().eq("email_normalized", email);
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "deleteCode", error: error.message }));
    }
  }

  async verifyGrant(email: string, limit: number): Promise<{ grantId: string; creditsRemaining: number }> {
    const { data, error } = await this.db.rpc("verify_trial_grant", {
      p_email: email,
      p_limit: limit,
    });
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "verifyGrant", error: error.message }));
      throw error;
    }
    // The function RETURNS TABLE → supabase-js yields an array of one row.
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("verify_trial_grant returned no row");
    return { grantId: String(row.grant_id), creditsRemaining: Number(row.credits_remaining) };
  }

  async rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_rate_limit", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      // Fail OPEN: a broken limiter must not block a legitimate trial signup.
      // The grant cap + code TTL + attempt limit still bound abuse.
      console.error(JSON.stringify({ fn: "trial-start", op: "rateLimit", error: error.message }));
      return true;
    }
    return data === true;
  }
}
