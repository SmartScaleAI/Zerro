// =============================================================================
// `trial-start` tunables (Phase F). All env-overridable so the trial economics
// (credit grant, code TTL, attempt + rate limits) and the from-address can be
// tuned with a `supabase secrets set …` + redeploy, never an app update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnv, optionalEnvBool, optionalEnvInt } from "../_shared/env.ts";

// ---- The trial credit grant -------------------------------------------------
// How many server-funded CREDITS a verified trial email gets, total (variable
// per-model spend — see multi-model plan §1.2/§1.3; the unit is credits, never
// a flat generation count). Capped here and enforced server-side
// (consume_trial_credit), keyed to the verified email so reinstalling can't
// farm a fresh grant. Default 30 (multi-model plan §1.3).
export const TRIAL_CREDITS = optionalEnvInt("TRIAL_CREDITS", 30);

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

// ---- Trial device binding (trial-abuse hardening) ---------------------------
// The one-grant-per-physical-Mac cap. The app sends a SHA-256 hash of a hardware
// UUID (`device_id_hash`); a second grant from a device that already trialed is
// hard-blocked regardless of email. This flag is a kill switch so the cap can be
// disabled via `supabase secrets set TRIAL_DEVICE_BINDING_ENABLED=false` +
// redeploy (no app release) if it ever misfires at launch. Default ON. When OFF,
// the device hash is ignored end-to-end and the function degrades to the
// email-only cap (status quo).
export const TRIAL_DEVICE_BINDING_ENABLED = optionalEnvBool("TRIAL_DEVICE_BINDING_ENABLED", true);

// ---- Email (Resend) ---------------------------------------------------------
// The verified getzerro.app sender address. RESEND_API_KEY is a REQUIRED secret
// (read in index.ts); this is the from line, env-overridable.
export const TRIAL_EMAIL_FROM = optionalEnv("TRIAL_EMAIL_FROM", "Zerro <noreply@getzerro.app>");
