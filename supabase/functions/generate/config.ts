// =============================================================================
// `generate` proxy tunables (Phase D2). All env-overridable so a model swap or a
// limit tighten is a `supabase secrets set …` + redeploy, never an app update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnv, optionalEnvInt } from "../_shared/env.ts";

// ---- Models — server-configurable from day one (§ models) ------------------
// Defaults match the BYOK path so Managed output is identical until/unless we
// deliberately swap. Override with STT_MODEL / CHAT_MODEL secrets.
export const STT_MODEL = optionalEnv("STT_MODEL", "whisper-1");
export const CHAT_MODEL = optionalEnv("CHAT_MODEL", "gpt-4o");

// ---- Server-side input limits — the "generous fuse" (§ input limits) -------
// Set ABOVE anything a real recording can produce (app hard-caps at 3 min,
// ~90–120 frames). They only reject a BYPASSED / FORGED oversized payload before
// any OpenAI call or credit work. Tune DOWN later in one place:
// TODO: tune down against measured cost (cost testing / Phase 19).
export const MAX_AUDIO_SECONDS = optionalEnvInt("GENERATE_MAX_AUDIO_SECONDS", 300); // 5 min
export const MAX_FRAMES = optionalEnvInt("GENERATE_MAX_FRAMES", 200);
export const MAX_PAYLOAD_BYTES = optionalEnvInt("GENERATE_MAX_PAYLOAD_BYTES", 60 * 1024 * 1024); // 60 MB
// Byte fuse on the audio part specifically: a pre-OpenAI proxy for "seconds"
// (we can't decode m4a duration without a codec). ~256 kbps ceiling over
// MAX_AUDIO_SECONDS, generous. The TRUE seconds gate is re-applied after Whisper
// returns its measured `duration`, before the expensive chat call.
export const MAX_AUDIO_BYTES = optionalEnvInt("GENERATE_MAX_AUDIO_BYTES", 12 * 1024 * 1024); // 12 MB

export const ALLOWED_AUDIO_MIME = ["audio/mp4", "audio/m4a", "audio/x-m4a"];
export const ALLOWED_FRAME_MIME = ["image/jpeg"];

// ---- Concurrency cap (=1 in flight) — backs the credit-ordering guard -------
// Slot stale-reclaim window. MUST exceed the worst-case OpenAI round-trip so a
// slow-but-live request is never reclaimed out from under itself; small enough
// that a crashed request frees the subscriber reasonably soon.
export const GENERATE_SLOT_STALE_SECONDS = optionalEnvInt("GENERATE_SLOT_STALE_SECONDS", 180);

// ---- Per-subscriber rate limit (reuses check_rate_limit) -------------------
// A coarse fixed-window cap on top of the concurrency cap. Phase G tightens.
export const GENERATE_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "GENERATE_RATE_LIMIT_WINDOW_SECONDS",
  60,
);
export const GENERATE_RATE_LIMIT_PER_SUB = optionalEnvInt("GENERATE_RATE_LIMIT_PER_SUB", 20);

// ---- OpenAI request timeout ------------------------------------------------
// Bounds a hung OpenAI call so the slot is released and the user gets a clear
// retryable error rather than waiting on the function wall-clock.
export const OPENAI_TIMEOUT_MS = optionalEnvInt("GENERATE_OPENAI_TIMEOUT_MS", 120_000);
