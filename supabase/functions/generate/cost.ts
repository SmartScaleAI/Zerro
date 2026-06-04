// =============================================================================
// Server-side cost estimate for a Managed generation (Phase D2).
// =============================================================================
// Mirrors AppState.logCost (Zerro/AppState.swift): STT per-MINUTE of audio +
// chat input/output per-token pricing. This is what lets Colin measure real
// Managed cost the SAME way the BYOK path logs it. The result is written to
// generation_log.est_cost_usd — token counts + dollars only, NEVER content
// (§14.5).
//
// Pricing is a per-`${provider}:${model}` table. An unknown key yields a null
// estimate (logged as a warning) rather than a wrong number — the column is
// informational and must never block a generation. Lookups key on the
// CONFIGURED model (STT_MODEL / CHAT_MODEL), not a response's reported version,
// so a provider that returns a dated `modelVersion` still prices correctly.
//
// OpenAI pricing pinned 2026-05-28 (matches the Swift BYOK constants).
//   KEEP IN SYNC with OpenAITranscriptionService.swift  (pricePerMinute)
//   KEEP IN SYNC with OpenAIPromptGenerationService.swift (input/output PerMillion)
// =============================================================================

import { CHAT_MODEL, CHAT_PROVIDER, STT_MODEL, STT_PROVIDER } from "./config.ts";

interface ChatPrice {
  inPerM: number;
  outPerM: number;
  /** Tiered models only: above `tierThreshold` input tokens, both rates change. */
  tierThreshold?: number;
  inPerMAbove?: number;
  outPerMAbove?: number;
}

// USD per 1M tokens. Keyed `${provider}:${model}`. Gemini output rates already
// include thinking tokens (we fold thoughtsTokenCount into outputTokens upstream).
const CHAT_PRICING: Record<string, ChatPrice> = {
  "openai:gpt-4o": { inPerM: 2.5, outPerM: 10.0 }, // 2026-05-28 list
  "gemini:gemini-3.5-flash": { inPerM: 1.5, outPerM: 9.0 }, // 2026-06-04 list, flat
  "gemini:gemini-3.1-pro-preview": { // 2026-06-04 list, tiered by input tokens
    inPerM: 2.0,
    outPerM: 12.0,
    tierThreshold: 200_000, // >200k prompt tokens raises BOTH rates
    inPerMAbove: 4.0,
    outPerMAbove: 18.0,
  },
};

// USD per minute of audio. Keyed `${provider}:${model}`.
const STT_PRICING: Record<string, { perMinute: number }> = {
  "openai:whisper-1": { perMinute: 0.006 }, // 2026-05-28 list
};

/** STT cost for the configured STT provider/model. Null if unpriced. */
export function sttCostUsd(audioDurationSeconds: number): number | null {
  if (!Number.isFinite(audioDurationSeconds) || audioDurationSeconds <= 0) return 0;
  const price = STT_PRICING[`${STT_PROVIDER}:${STT_MODEL}`];
  if (!price) {
    console.warn(JSON.stringify({ fn: "generate", warn: "unpriced_stt", key: `${STT_PROVIDER}:${STT_MODEL}` }));
    return null;
  }
  return (audioDurationSeconds / 60) * price.perMinute;
}

/** Chat cost for the configured chat provider/model from reported token usage. */
export function chatCostUsd(
  provider: string,
  model: string,
  inputTokens: number,
  outputTokens: number,
): number | null {
  const price = CHAT_PRICING[`${provider}:${model}`];
  if (!price) {
    console.warn(JSON.stringify({ fn: "generate", warn: "unpriced_chat", key: `${provider}:${model}` }));
    return null;
  }
  // Tiered models price BOTH input and output at the higher rate once the input
  // token count crosses the threshold (e.g. Gemini Pro >200k prompt tokens).
  const tiered = price.tierThreshold !== undefined && inputTokens > price.tierThreshold;
  const inRate = tiered ? (price.inPerMAbove ?? price.inPerM) : price.inPerM;
  const outRate = tiered ? (price.outPerMAbove ?? price.outPerM) : price.outPerM;
  return (inputTokens / 1_000_000) * inRate + (outputTokens / 1_000_000) * outRate;
}

/**
 * Total est. USD for one generation: STT + chat. Null if either component is
 * unpriced (the caller logs null rather than a partial/wrong number). The chat
 * provider/model are passed explicitly so the cost keys on the CONFIGURED model.
 */
export function estimatedCostUsd(
  audioDurationSeconds: number,
  chatProvider: string,
  chatModel: string,
  inputTokens: number,
  outputTokens: number,
): number | null {
  const stt = sttCostUsd(audioDurationSeconds);
  const chat = chatCostUsd(chatProvider, chatModel, inputTokens, outputTokens);
  if (stt === null || chat === null) return null;
  return stt + chat;
}

// The chat provider/model the cost table prices against (configured, not the
// provider's reported response version). Re-exported so the handler logs the
// same key the table is built on.
export { CHAT_MODEL, CHAT_PROVIDER };
