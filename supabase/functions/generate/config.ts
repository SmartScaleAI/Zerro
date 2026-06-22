// =============================================================================
// `generate` proxy tunables (Phase D2). All env-overridable so a model swap or a
// limit tighten is a `supabase secrets set …` + redeploy, never an app update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnv, optionalEnvInt } from "../_shared/env.ts";

// ---- Providers + models — server-configurable from day one (§ models) ------
// Defaults match the BYOK path (OpenAI / gpt-4o) so Managed output is identical
// until/unless we deliberately swap. The provider selects which adapter the
// factory wires (providers/factory.ts); the model is passed to that adapter.
// One secret flips the chat provider: `CHAT_PROVIDER=gemini CHAT_MODEL=…`.
// STT stays OpenAI Whisper this phase (the interleaver needs segment timestamps).
export const STT_PROVIDER = optionalEnv("STT_PROVIDER", "openai");
export const STT_MODEL = optionalEnv("STT_MODEL", "whisper-1");
export const CHAT_PROVIDER = optionalEnv("CHAT_PROVIDER", "openai");
export const CHAT_MODEL = optionalEnv("CHAT_MODEL", "gpt-4o");

// Gemini chat thinking depth — "low" | "high". Default "low": the generation
// task is a structured rewrite, not a reasoning problem, so "high" mostly adds
// latency + billed thinking (output) tokens. Tunable server-side, no redeploy.
// Only consulted when CHAT_PROVIDER=gemini.
export const GEMINI_THINKING_LEVEL = optionalEnv("GEMINI_THINKING_LEVEL", "low");

// ---- Credit economics (multi-model plan §1.2) -------------------------------
// 1 credit = $0.01 of real provider cost. This is the UNIT DEFINITION the whole
// credit system is denominated in — deliberately NOT env-tunable, because
// changing it would silently re-price every model at once. Every generation is
// METERED on real cost (`ceil(est_cost_usd / USD_PER_CREDIT)`, floor 1; see
// cost.ts `creditCostForModel`), so a user's credit allowance is a true dollar
// COGS cap.
export const USD_PER_CREDIT = 0.01;

// NOTE: there is no pre-generation credit ESTIMATOR. The charge is metered on
// the REAL post-chat cost (`creditCostForModel`); the out-of-credits decision is
// the handler's `remaining < 1` FLOOR gate, which allows a user with >= 1 credit
// exactly one uncapped generation (charged in full, possibly into the negative)
// and blocks every further one. The former estimate+headroom gate and its token
// constants (SYSTEM_PROMPT_TOKENS / OUTPUT_TOKENS_ESTIMATE / FRAME_TOKENS_* /
// HEADROOM_CREDITS) were removed with that gate.

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

// Per-frame cap on the client-supplied `ocr_text` (Phase 3). The app sends at
// most a screenful of recognized text (a few hundred chars); this generous
// ~8 KB/frame ceiling only stops a FORGED body from bloating the prompt the
// server's key pays for. Capped by characters (a cheap proxy for bytes — OCR
// text is near-ASCII). The text is already redacted client-side; the server
// trusts it and does not re-scan.
export const MAX_OCR_TEXT_CHARS = optionalEnvInt("GENERATE_MAX_OCR_TEXT_CHARS", 8 * 1024);

// Phase 4 — click caps. A real 3-min recording produces at most a few dozen
// clicks with short on-screen labels; these generous fuses only stop a FORGED
// body from bloating the prompt the server's key pays for. Clicks past the count
// cap are DROPPED (not a reject — a real recording can't hit it); each label is
// length-capped. Labels are already redacted client-side; the server trusts and
// length-caps only.
export const MAX_CLICKS = optionalEnvInt("GENERATE_MAX_CLICKS", 200);
export const MAX_CLICK_LABEL_CHARS = optionalEnvInt("GENERATE_MAX_CLICK_LABEL_CHARS", 200);

// Phase 2 (Dev Mode call 2) — caps on the CLIENT-SUPPLIED transcript (the
// `mode:"dev"` 2-call flow, where the client transcribed via the free call 1 and
// resends the transcript so the server skips re-STT). A real recording's
// transcript is already bounded by the MAX_AUDIO_SECONDS audio fuse on call 1;
// these only stop a FORGED call-2 body from bloating the prompt the server's key
// pays for. Excess segments are DROPPED (not a reject — a real recording can't
// hit it); each segment's text is length-capped. These caps (with the call-1
// audio fuse) bound the absolute prompt size; the metered charge then bills the
// REAL cost of whatever is sent, and the handler's `remaining < 1` floor gate
// blocks the NEXT request — so a forged body can at worst inflate the ONE
// already-authorized generation, never run unbounded.
export const MAX_TRANSCRIPT_SEGMENTS = optionalEnvInt("GENERATE_MAX_TRANSCRIPT_SEGMENTS", 2000);
export const MAX_TRANSCRIPT_TEXT_CHARS = optionalEnvInt("GENERATE_MAX_TRANSCRIPT_TEXT_CHARS", 8 * 1024);

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

// ---- Provider request timeout ----------------------------------------------
// Bounds a hung provider call so the slot is released and the user gets a clear
// retryable error rather than waiting on the function wall-clock. Prefer the
// provider-neutral var; fall back to the legacy OpenAI-named one so deployments
// with a tuned GENERATE_OPENAI_TIMEOUT_MS don't silently reset to the default.
export const PROVIDER_TIMEOUT_MS = optionalEnvInt(
  "GENERATE_PROVIDER_TIMEOUT_MS",
  optionalEnvInt("GENERATE_OPENAI_TIMEOUT_MS", 120_000),
);

// ---- Idempotency cache TTL (M1) --------------------------------------------
// How long a charged generation's result stays replayable for a retry carrying
// the same Idempotency-Key. Set to the SHORTEST window that reliably covers the
// retry path — minutes, not days — because this is the one place a generated
// prompt is persisted (the documented §14.5 carve-out; see the idempotency
// migration). The window must outlive: the client's 180s request timeout, the
// user's think-time before tapping Retry, and up to maxFailureRetries (2)
// attempts. 15 min is generous headroom over that while keeping content
// retention minimal. Tunable server-side, no app update.
export const IDEMPOTENCY_TTL_SECONDS = optionalEnvInt("GENERATE_IDEMPOTENCY_TTL_SECONDS", 900);
