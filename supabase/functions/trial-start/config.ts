// =============================================================================
// `trial-start` tunables (Phase F). All env-overridable so the trial economics
// (credit grant, code TTL, attempt + rate limits) and the from-address can be
// tuned with a `supabase secrets set …` + redeploy, never an app update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnv, optionalEnvInt } from "../_shared/env.ts";

// ---- The trial credit grant -------------------------------------------------
// How many server-funded generations a verified trial email gets, total. Capped
// here and enforced server-side (consume_trial_credit), keyed to the verified
// email so reinstalling can't farm a fresh grant. Default 15 (§6.4).
export const TRIAL_CREDITS = optionalEnvInt("TRIAL_CREDITS", 15);

// ---- Verification code ------------------------------------------------------
// 6-digit numeric code, hashed (never stored raw), short TTL, attempt-limited.
export const CODE_TTL_SECONDS = optionalEnvInt("TRIAL_CODE_TTL_SECONDS", 10 * 60); // 10 min
// Max verify attempts against a single issued code before it's burned. Bounds
// online brute force of the 6-digit space well under the TTL.
export const CODE_MAX_ATTEMPTS = optionalEnvInt("TRIAL_CODE_MAX_ATTEMPTS", 5);

// ---- Trial session token lifetime ------------------------------------------
// The short-lived JWT minted on a successful verify (kind='trial'). Mirrors the
// subscription session token lifetime by default.
export const TRIAL_TOKEN_TTL_SECONDS = optionalEnvInt("TRIAL_TOKEN_TTL_SECONDS", 30 * 60);

// ---- Rate limits on the code endpoints (§14.2) ------------------------------
// Per-email and per-IP fixed-window limits (reuse check_rate_limit). The code
// endpoint must not be hammerable (brute force) or usable to spam-send mail.
export const TRIAL_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "TRIAL_RATE_LIMIT_WINDOW_SECONDS",
  60 * 60, // 1 hour window
);
// Requests per email per window (request-code + verify-code combined). A small
// number: a real user needs 1 send + a few verify tries.
export const TRIAL_RATE_LIMIT_PER_EMAIL = optionalEnvInt("TRIAL_RATE_LIMIT_PER_EMAIL", 8);
// Requests per IP per window — higher (shared NATs) but still bounds bulk abuse.
export const TRIAL_RATE_LIMIT_PER_IP = optionalEnvInt("TRIAL_RATE_LIMIT_PER_IP", 30);

// ---- Email (Resend) ---------------------------------------------------------
// The verified getzerro.app sender address. RESEND_API_KEY is a REQUIRED secret
// (read in index.ts); this is the from line, env-overridable.
export const TRIAL_EMAIL_FROM = optionalEnv("TRIAL_EMAIL_FROM", "Zerro <noreply@getzerro.app>");
