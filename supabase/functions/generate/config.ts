// =============================================================================
// `generate` proxy tunables (Phase D2). All env-overridable so a model swap or a
// limit tighten is a `supabase secrets set …` + redeploy, never an app update.
// Documented in README-backend.md.
// =============================================================================

import { optionalEnv, optionalEnvInt } from "../_shared/env.ts";
import { composedSystemPrompt } from "./prompt.ts";

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

// ---- Preflight estimator (Phase 2 — estimate + headroom gate) ---------------
// The charge is metered on REAL cost post-chat, but the out-of-credits gate runs
// BEFORE the chat call, so it needs an estimate of the cost from the known
// inputs (frames, transcript, OCR, audio) plus a conservative output allowance.
// All env-overridable so the estimator can be retuned from real
// (frames, tokens_in, tokens_out) data without an app update.
//
// SYSTEM_PROMPT_TOKENS is NOT a magic number: it's derived once at module load
// from the real composed system prompt (~chars/4), so a prompt edit retunes the
// floor automatically. prompt.ts has no imports, so this can't cycle.
export const SYSTEM_PROMPT_TOKENS = Math.ceil(composedSystemPrompt().length / 4);
// Conservative per-generation output-token allowance (real avg out ≈ 1.5–3k in
// generation_log). Deliberately on the high side so the gate errs toward
// over-, not under-, estimating the spend.
export const OUTPUT_TOKENS_ESTIMATE = optionalEnvInt("GENERATE_OUTPUT_TOKENS_ESTIMATE", 3000);
// Per-frame input-token cost by provider (a frame is a fixed-resolution image,
// so its token cost is provider-determined, not size-determined).
export const FRAME_TOKENS_GEMINI = optionalEnvInt("GENERATE_FRAME_TOKENS_GEMINI", 1120); // media_resolution_high
export const FRAME_TOKENS_OPENAI = optionalEnvInt("GENERATE_FRAME_TOKENS_OPENAI", 1100); // ~6×512px tiles, 16:9; tune later
export const FRAME_TOKENS_ANTHROPIC = optionalEnvInt("GENERATE_FRAME_TOKENS_ANTHROPIC", 1200); // tune later
// The gate allows when `balance >= estimate - HEADROOM_CREDITS`: a small
// tolerance so a user who is a few credits short of a slightly-over estimate
// isn't blocked from a recording that will, in reality, cost a little less. The
// residual-overshoot free-result path (handler step 12) covers any remainder.
export const HEADROOM_CREDITS = optionalEnvInt("GENERATE_HEADROOM_CREDITS", 5);

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
