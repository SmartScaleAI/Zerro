// Service-role Supabase client. The service role BYPASSES RLS — it is the only
// principal allowed to touch the billing tables (see *_billing_rls.sql). These
// two vars are auto-injected by the Supabase Edge runtime; we never ship a
// service-role key to the app.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { requireEnv } from "./env.ts";

let cached: SupabaseClient | null = null;

/** A memoized service-role client (no session persistence — server context). */
export function serviceClient(): SupabaseClient {
  if (cached) return cached;
  cached = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  return cached;
}
