// =============================================================================
// `affiliate` tunables (C-08 hardening). Env-overridable so the throttle can be
// tuned with `supabase secrets set …` + redeploy, never an app/site update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnvInt } from "../_shared/env.ts";

// ---- Per-IP POST throttle ----------------------------------------------------
// Defense-in-depth on the unauthenticated record path (the structural fix is
// the unique(ip_hash) upsert — see the C-08 dedup migration): bounds write/RPC
// churn from a single hammering IP. Generous — a real visitor records once per
// landing — and over-cap POSTs still answer { ok: true } (best-effort record;
// the throttle never surfaces to the landing page).
export const AFFILIATE_RATE_LIMIT_PER_IP = optionalEnvInt("AFFILIATE_RATE_LIMIT_PER_IP", 20);
export const AFFILIATE_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "AFFILIATE_RATE_LIMIT_WINDOW_SECONDS",
  60 * 60, // 1 hour window
);
