// =============================================================================
// Server-side cost estimate for a Managed generation (Phase D2).
// =============================================================================
// Mirrors AppState.logCost (Zerro/AppState.swift): Whisper per-MINUTE of audio +
// chat input/output per-token pricing. This is what lets Colin measure real
// Managed cost the SAME way the BYOK path logs it. The result is written to
// generation_log.est_cost_usd — token counts + dollars only, NEVER content
// (§14.5).
//
// Pricing pinned at 2026-05-28 list price, matching the constants in
// OpenAITranscriptionService.swift / OpenAIPromptGenerationService.swift. If
// OpenAI changes pricing (or we date-stamp / swap the models), update HERE.
//   KEEP IN SYNC with OpenAITranscriptionService.swift  (pricePerMinute)
//   KEEP IN SYNC with OpenAIPromptGenerationService.swift (input/output PerMillion)
// =============================================================================

// whisper-1 — USD per minute of audio (2026-05-28).
const WHISPER_PRICE_PER_MINUTE = 0.006;
// gpt-4o — USD per 1M tokens (2026-05-28).
const CHAT_INPUT_PRICE_PER_MILLION = 2.5;
const CHAT_OUTPUT_PRICE_PER_MILLION = 10.0;

/** Whisper cost for `audioDurationSeconds` of audio. Mirrors the Swift helper. */
export function whisperCostUsd(audioDurationSeconds: number): number {
  if (!Number.isFinite(audioDurationSeconds) || audioDurationSeconds <= 0) return 0;
  return (audioDurationSeconds / 60) * WHISPER_PRICE_PER_MINUTE;
}

/** Chat cost from reported token usage (input + output priced separately). */
export function chatCostUsd(inputTokens: number, outputTokens: number): number {
  const inCost = (inputTokens / 1_000_000) * CHAT_INPUT_PRICE_PER_MILLION;
  const outCost = (outputTokens / 1_000_000) * CHAT_OUTPUT_PRICE_PER_MILLION;
  return inCost + outCost;
}

/** Total est. USD for one generation: Whisper + chat. */
export function estimatedCostUsd(
  audioDurationSeconds: number,
  inputTokens: number,
  outputTokens: number,
): number {
  return whisperCostUsd(audioDurationSeconds) + chatCostUsd(inputTokens, outputTokens);
}
