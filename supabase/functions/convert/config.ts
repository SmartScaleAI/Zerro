// =============================================================================
// `convert` tunables (Phase 6 — the free "Write agent prompt" fallback). All
// env-overridable, same discipline as generate/config.ts.
// =============================================================================

import { optionalEnv, optionalEnvInt } from "../_shared/env.ts";

// ---- Input fuse -------------------------------------------------------------
// The client sends at most ~20k chars of chat text + a ~4k context block as
// JSON; 256 KB is a generous raw-body ceiling that only a forged payload can
// trip. The per-field char caps below are the plan's contract (§ Phase 6:
// source_text ≤ 20k, context ≤ 6k).
export const CONVERT_MAX_PAYLOAD_BYTES = optionalEnvInt("CONVERT_MAX_PAYLOAD_BYTES", 256 * 1024);
export const CONVERT_MAX_SOURCE_CHARS = optionalEnvInt("CONVERT_MAX_SOURCE_CHARS", 20_000);
export const CONVERT_MAX_CONTEXT_CHARS = optionalEnvInt("CONVERT_MAX_CONTEXT_CHARS", 6_000);

// ---- Per-identity rate limit (reuses check_rate_limit) ----------------------
// The ONLY quantitative gate on this endpoint — conversions are free (no
// credit check by design), so the limiter is what stops the free endpoint
// from being farmed. Tighter than generate's 20/min: a real user converts at
// most once per recording.
export const CONVERT_RATE_LIMIT_PER_IDENTITY = optionalEnvInt("CONVERT_RATE_LIMIT_PER_IDENTITY", 10);
export const CONVERT_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "CONVERT_RATE_LIMIT_WINDOW_SECONDS",
  60,
);

// Gemini thinking depth — mirrors generate's default ("low"): the conversion
// is a structured rewrite, not a reasoning problem.
export const GEMINI_THINKING_LEVEL = optionalEnv("GEMINI_THINKING_LEVEL", "low");

// ---- Trial metering (X-01 / B-01) -------------------------------------------
// `convert` is FREE for managed/subscription tokens (already paying) but METERS a
// kind:"trial" token against the SAME per-grant credit pool /generate uses
// (consume_trial_credit). These mirror generate's slot stale window + idempotency
// TTL so the metered trial path is exactly as safe: cap-1 in-flight (slot) makes
// check-then-consume correct, and a retry carrying the same Idempotency-Key
// replays the cached prompt instead of charging twice.
export const CONVERT_SLOT_STALE_SECONDS = optionalEnvInt("CONVERT_SLOT_STALE_SECONDS", 180);
export const CONVERT_IDEMPOTENCY_TTL_SECONDS = optionalEnvInt(
  "CONVERT_IDEMPOTENCY_TTL_SECONDS",
  900,
);
