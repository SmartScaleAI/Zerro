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
// Byte fuse on the audio part specifically (B-03). This is now LOAD-BEARING: with
// Dev-Mode transcription billed as FREE ("eat the sub-cent cost"), this cap — not a
// credit — is the pre-Whisper bound on a single STT call, so it is tightened to a
// realistic ceiling for the app's real recording.
//   Derivation: the desktop app encodes 64 kbps MONO AAC (RecordingSession.swift
//   AVEncoderBitRateKey: 64_000, AVNumberOfChannelsKey: 1) and HARD-CAPS a recording
//   at 180 s (150 s/180 s auto-stop). 64 kbps = 8 000 bytes/s → a real 3-min file is
//   ≈ 180 × 8 000 = 1.44 MB (+ negligible MP4 container overhead). 2 MB gives ≈40%
//   headroom over that worst-case real recording (it is never rejected) while capping
//   a single accepted file to ≈4.4 min at the real bitrate (≈$0.026 of Whisper) —
//   ~6× tighter than the old 12 MB. A forged LOW-bitrate file can still pack more
//   duration per byte, so this is the per-call bound; the per-identity rate limit and
//   the out-of-band global provider-spend cap (B-05) are the aggregate ceilings.
//   We can't decode m4a duration server-side without a codec, so the cap stays on
//   bytes; the declared-duration check below is a secondary honest-client sanity gate.
export const MAX_AUDIO_BYTES = optionalEnvInt("GENERATE_MAX_AUDIO_BYTES", 2 * 1024 * 1024); // 2 MB

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

// ---- Provider request timeout ----------------------------------------------
// Bounds a hung provider call so the slot is released and the user gets a clear
// retryable error rather than waiting on the function wall-clock. Prefer the
// provider-neutral var; fall back to the legacy OpenAI-named one so deployments
// with a tuned GENERATE_OPENAI_TIMEOUT_MS don't silently reset to the default.
// DEFINED BEFORE the concurrency cap on purpose: the slot stale-reclaim window
// is DERIVED from this value (slotStaleSeconds below), so retuning the timeout
// can never leave the stale window shorter than the worst-case hold (A-04).
export const PROVIDER_TIMEOUT_MS = optionalEnvInt(
  "GENERATE_PROVIDER_TIMEOUT_MS",
  optionalEnvInt("GENERATE_OPENAI_TIMEOUT_MS", 120_000),
);

// ---- Concurrency cap (=1 in flight) — backs the credit-ordering guard -------
// Slot stale-reclaim window. THE INVARIANT (A-04): STALE_SECONDS MUST be
// STRICTLY GREATER THAN the worst-case time a single LIVE request can hold the
// slot. Violate it and acquire_generation_slot reclaims a slow-but-live request's
// slot mid-flight, hands a 2nd concurrent request a slot, both pass the credit
// floor gate, and the cap-1 overspend bound (A-05) breaks → concurrent overspend.
//
// WORST-CASE HOLD: a generation holds ONE slot across BOTH provider calls — STT
// then chat — back to back (handler.ts acquireSlot → transcribe → chat → release
// in finally). Each provider client (providers/openai.ts / anthropic.ts /
// gemini.ts) does ONE retry on a transient 429/5xx, and every attempt is bounded
// by PROVIDER_TIMEOUT_MS, so a single call can take up to 2 × PROVIDER_TIMEOUT_MS
// and a whole generation up to (STT + chat) = 2 calls × 2 attempts ×
// PROVIDER_TIMEOUT_MS (= 480s at the 120s default). The old flat 180s default was
// shorter than even ONE such call — the A-04 launch blocker.
//
// We DERIVE the window from PROVIDER_TIMEOUT_MS (never a magic number) so it can
// never fall below the hold when the timeout is retuned via secrets.

/** Worst-case-safe slot stale-reclaim window (seconds) for a slot held across
 *  `providerCalls` back-to-back provider round-trips. Each call is initial + one
 *  transient retry (PROVIDER_CALL_ATTEMPTS), each attempt bounded by
 *  PROVIDER_TIMEOUT_MS; a fixed buffer covers DB round-trips, base64/JSON work,
 *  and scheduler jitter. The result is STRICTLY GREATER than the worst-case hold
 *  — the A-04 invariant. Shared with the chat-only convert path so both windows
 *  track PROVIDER_TIMEOUT_MS from one source of truth.
 *    generate / trial generate → providerCalls = 2 (STT + chat) → 600s @ 120s.
 *    convert                   → providerCalls = 1 (chat only)  → 360s @ 120s. */
export function slotStaleSeconds(providerCalls: number): number {
  const PROVIDER_CALL_ATTEMPTS = 2; // initial request + one transient retry (providers/*.ts send())
  const SLOT_BUFFER_MS = 120_000; // margin for DB round-trips, base64/JSON work, and jitter
  const worstCaseHoldMs = providerCalls * PROVIDER_CALL_ATTEMPTS * PROVIDER_TIMEOUT_MS;
  return Math.ceil((worstCaseHoldMs + SLOT_BUFFER_MS) / 1000);
}

// generate (and the trial generate path, handler.ts resolveTrial) holds the slot
// across STT *and* chat → two provider calls → slotStaleSeconds(2) (600s @ 120s).
export const GENERATE_SLOT_STALE_SECONDS = optionalEnvInt(
  "GENERATE_SLOT_STALE_SECONDS",
  slotStaleSeconds(2),
);

// ---- Per-subscriber rate limit (reuses check_rate_limit) -------------------
// A coarse fixed-window cap on top of the concurrency cap. Phase G tightens.
export const GENERATE_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "GENERATE_RATE_LIMIT_WINDOW_SECONDS",
  60,
);
export const GENERATE_RATE_LIMIT_PER_SUB = optionalEnvInt("GENERATE_RATE_LIMIT_PER_SUB", 20);


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
