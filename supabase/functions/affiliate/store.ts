// =============================================================================
// affiliate — Supabase-backed AffiliateStore (the only impl; tests use a fake).
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { AffiliateStore } from "./handler.ts";

export class SupabaseAffiliateStore implements AffiliateStore {
  constructor(private readonly db: SupabaseClient) {}

  async record(ipHash: string, affCode: string): Promise<void> {
    // C-08: one row per ip_hash (unique index affiliate_referrals_ip_hash_unique),
    // latest code wins — a plain insert made this unauthenticated endpoint an
    // unbounded row amplifier. created_at is passed EXPLICITLY: the column
    // default (now()) only fires on INSERT, so a conflict-update would
    // otherwise keep the OLD timestamp and the windowed GET would age out a
    // freshly refreshed click.
    const { error } = await this.db
      .from("affiliate_referrals")
      .upsert(
        { ip_hash: ipHash, aff_code: affCode, created_at: new Date().toISOString() },
        { onConflict: "ip_hash" },
      );
    if (error) throw new Error(error.message);
  }

  async latestCode(ipHash: string, sinceISO: string): Promise<string | null> {
    const { data, error } = await this.db
      .from("affiliate_referrals")
      .select("aff_code")
      .eq("ip_hash", ipHash)
      .gte("created_at", sinceISO)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return (data?.aff_code as string | undefined) ?? null;
  }

  async rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_rate_limit", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      // Fail OPEN (contrast trial-start's C-07 per-IP fail-closed): this
      // endpoint sends no email and spends no credits, and the GET already
      // fails soft — a broken limiter must not break landing-page recording.
      // The unique(ip_hash) upsert keeps even an unthrottled flood bounded.
      // event:"rate_limiter_error" is the shared ops alert hook (A-15).
      console.error(JSON.stringify({
        fn: "affiliate",
        event: "rate_limiter_error",
        failed_closed: false,
        error: error.message,
      }));
      return true;
    }
    return data === true;
  }
}
