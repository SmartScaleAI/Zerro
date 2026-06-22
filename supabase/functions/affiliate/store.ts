// =============================================================================
// affiliate — Supabase-backed AffiliateStore (the only impl; tests use a fake).
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { AffiliateStore } from "./handler.ts";

export class SupabaseAffiliateStore implements AffiliateStore {
  constructor(private readonly db: SupabaseClient) {}

  async record(ipHash: string, affCode: string): Promise<void> {
    const { error } = await this.db
      .from("affiliate_referrals")
      .insert({ ip_hash: ipHash, aff_code: affCode });
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
}
