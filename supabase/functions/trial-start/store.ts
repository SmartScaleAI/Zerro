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
import {
  type RateLimitKeyKind,
  type RateLimitOnError,
  rateLimiterErrorVerdict,
} from "./ratelimit.ts";

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

/**
 * The outcome of a device-aware grant verification. Either a normal grant
 * (create-once / never-reset) or the "device already used under a DIFFERENT
 * email" hard block — distinct from a normally exhausted grant so the handler
 * can return the dedicated `device_trial_used` status.
 */
export type VerifyGrantResult =
  | { deviceBlocked: false; grantId: string; creditsRemaining: number }
  | { deviceBlocked: true };

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
   * Create-once / never-reset the grant for `email`, bound to `deviceIdHash`,
   * and return its id + credits remaining (verify_trial_grant). The single grant
   * writer. A non-null `deviceIdHash` already used under a DIFFERENT email yields
   * `{ deviceBlocked: true }` — nothing is created.
   */
  verifyGrant(email: string, limit: number, deviceIdHash: string | null): Promise<VerifyGrantResult>;
  /**
   * TRUE if a grant already exists for `deviceIdHash` under an email OTHER than
   * `email`. A cheap read used to hard-block the `request` step before any code
   * is generated/emailed. (A grant under the SAME email is a legitimate
   * reinstall/resume, not a block.)
   */
  deviceAlreadyGranted(deviceIdHash: string, email: string): Promise<boolean>;
  /**
   * TRUE if within the limit for the current window. `onError` is the fail
   * posture when the limiter ITSELF errors (C-07): "allow" = fail open,
   * "deny" = fail closed — the caller decides per key (see handler.ts).
   * `keyKind` labels the rate_limiter_error alert log; it is passed by the
   * call site, never parsed out of the key.
   */
  rateLimitOk(
    key: string,
    max: number,
    windowSeconds: number,
    onError: RateLimitOnError,
    keyKind: RateLimitKeyKind,
  ): Promise<boolean>;
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
    // C-09: one atomic UPDATE (attempts = attempts + 1) via RPC — no
    // read-modify-write window. Missing row = no-op.
    const { error } = await this.db.rpc("increment_trial_code_attempts", { p_email: email });
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

  async verifyGrant(email: string, limit: number, deviceIdHash: string | null): Promise<VerifyGrantResult> {
    const { data, error } = await this.db.rpc("verify_trial_grant", {
      p_email: email,
      p_limit: limit,
      p_device_id_hash: deviceIdHash,
    });
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "verifyGrant", error: error.message }));
      throw error;
    }
    // The function RETURNS TABLE → supabase-js yields an array of one row.
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("verify_trial_grant returned no row");
    // grant_id NULL is the "device already used under a different email" sentinel.
    if (row.grant_id === null || row.grant_id === undefined) {
      return { deviceBlocked: true };
    }
    return {
      deviceBlocked: false,
      grantId: String(row.grant_id),
      creditsRemaining: Number(row.credits_remaining),
    };
  }

  async deviceAlreadyGranted(deviceIdHash: string, email: string): Promise<boolean> {
    const { data, error } = await this.db
      .from("trial_grants")
      .select("id")
      .eq("device_id_hash", deviceIdHash)
      .neq("email_normalized", email)
      .limit(1)
      .maybeSingle();
    if (error) {
      console.error(JSON.stringify({ fn: "trial-start", op: "deviceCheck", error: error.message }));
      throw error;
    }
    return data !== null;
  }

  async rateLimitOk(
    key: string,
    max: number,
    windowSeconds: number,
    onError: RateLimitOnError,
    keyKind: RateLimitKeyKind,
  ): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_rate_limit", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      // C-07: the verdict is the caller's per-key posture, and EVERY error —
      // regardless of posture — emits the rate_limiter_error alert line
      // (see ratelimit.ts).
      return rateLimiterErrorVerdict(keyKind, onError, error.message);
    }
    return data === true;
  }
}
