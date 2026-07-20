// =============================================================================
// `feedback` tunables (C-04 hardening). Env-overridable so the per-IP limit
// can be tuned with `supabase secrets set …` + redeploy, never an app update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnvInt } from "../_shared/env.ts";

// ---- Per-IP rate limit ------------------------------------------------------
// The endpoint is UNAUTHENTICATED (see index.ts), so a fixed-window per-IP cap
// (reusing check_rate_limit) is the only quantitative bound on Slack spam. A
// real user sends at most a handful of reports, so the default stays tight.
export const FEEDBACK_RATE_LIMIT_PER_IP = optionalEnvInt("FEEDBACK_RATE_LIMIT_PER_IP", 5);
export const FEEDBACK_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "FEEDBACK_RATE_LIMIT_WINDOW_SECONDS",
  60 * 60, // 1 hour window
);
