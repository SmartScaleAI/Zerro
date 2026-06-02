// Tunable billing constants. Values that are "still to confirm" in the billing
// plan (§12) live here as named constants / env-overridable, never as scattered
// literals (cross-cutting requirement: "caps, token lifetimes as config").

import { optionalEnvInt, optionalEnv } from "./env.ts";

// ---- Per-tier monthly credit allowance -------------------------------------
// Defaults mirror the Swift preview/UI (EntitlementStore: Starter 100, Pro 300)
// and §3.2. Override per environment without a code change.
export const CREDITS_STARTER = optionalEnvInt("CREDITS_STARTER", 100);
export const CREDITS_PRO = optionalEnvInt("CREDITS_PRO", 300);

export type Tier = "starter" | "pro";

/** Credit allowance for a tier. */
export function creditsForTier(tier: Tier): number {
  return tier === "pro" ? CREDITS_PRO : CREDITS_STARTER;
}

// ---- Tier resolution from LemonSqueezy variant ids -------------------------
// Variant ids are only known once the Starter/Pro products exist (Phase E
// prereq). Set LS_VARIANT_STARTER / LS_VARIANT_PRO as secrets; the webhook maps
// the subscription's variant_id → tier. A `meta.custom_data.tier` value (if the
// checkout passes one) is honored as a fallback. If nothing matches we default
// to 'starter' (the cheaper allowance) and log a warning — never silently
// over-grant Pro credits.
export const LS_VARIANT_STARTER = optionalEnv("LS_VARIANT_STARTER", "");
export const LS_VARIANT_PRO = optionalEnv("LS_VARIANT_PRO", "");

// ---- Session token lifetime ------------------------------------------------
// §12 open value (15–60 min). Default 30 min. Also the staleness window anchor
// for the Phase G live re-check (§14.6).
export const SESSION_TOKEN_TTL_SECONDS = optionalEnvInt(
  "SESSION_TOKEN_TTL_SECONDS",
  30 * 60,
);

// ---- Rate limits on the `session` credential exchange (§14.2) ---------------
// Basic fixed-window limiter (backed by check_rate_limit). Phase G tightens.
export const SESSION_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "SESSION_RATE_LIMIT_WINDOW_SECONDS",
  60,
);
export const SESSION_RATE_LIMIT_PER_KEY = optionalEnvInt(
  "SESSION_RATE_LIMIT_PER_KEY",
  10,
);
export const SESSION_RATE_LIMIT_PER_IP = optionalEnvInt(
  "SESSION_RATE_LIMIT_PER_IP",
  30,
);
