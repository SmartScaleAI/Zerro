// =============================================================================
// Server-side cost estimate for a Managed generation (Phase D2).
// =============================================================================
// Mirrors AppState.logCost (Zerro/AppState.swift): STT per-MINUTE of audio +
// chat input/output per-token pricing. This is what lets Colin measure real
// Managed cost the SAME way the BYOK path logs it. The result is written to
// generation_log.est_cost_usd — token counts + dollars only, NEVER content
// (§14.5).
//
// Note: the BYOK client path can now transcribe ON-DEVICE (whisper.cpp, $0 STT
// — see AppState.sttCostUSD `isLocal`). This managed/server path is UNCHANGED and
// always uses cloud STT (STT_MODEL), so the per-minute STT estimate below stays
// correct here.
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

import {
  CHAT_MODEL,
  CHAT_PROVIDER,
  STT_MODEL,
  STT_PROVIDER,
  USD_PER_CREDIT,
} from "./config.ts";
import { modelById } from "./models.ts";

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
// KEEP IN SYNC (F8): this table is mirrored 1:1 in the eval harness
// (apps/desktop/Scripts/eval-models.mjs CHAT_PRICING) — verified against
// provider price lists in Phase 0. If a rate changes, update BOTH.
const CHAT_PRICING: Record<string, ChatPrice> = {
  "openai:gpt-4o": { inPerM: 2.5, outPerM: 10.0 }, // 2026-05-28 list (legacy default)
  // — the six user-selectable models (models.ts registry; rates 2026-06 lists) —
  "openai:gpt-5.4-mini": { inPerM: 0.75, outPerM: 4.5 },
  "openai:gpt-5.5": { inPerM: 5.0, outPerM: 30.0 },
  "gemini:gemini-3.5-flash": { inPerM: 1.5, outPerM: 9.0 }, // 2026-06-04 list, flat
  "gemini:gemini-3.1-pro-preview": { // 2026-06-04 list, tiered by input tokens
    inPerM: 2.0,
    outPerM: 12.0,
    tierThreshold: 200_000, // >200k prompt tokens raises BOTH rates
    inPerMAbove: 4.0,
    outPerMAbove: 18.0,
  },
  "anthropic:claude-sonnet-4-6": { inPerM: 3.0, outPerM: 15.0 },
  "anthropic:claude-opus-4-7": { inPerM: 5.0, outPerM: 25.0 },
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

/**
 * Credits to charge for one generation on `modelId` (multi-model plan §1.2):
 * ALWAYS METERED on the real measured cost — `ceil(estCostUsd / USD_PER_CREDIT)`
 * with a floor of 1 credit per successful generation. Because USD_PER_CREDIT is
 * $0.01, a user's credit allowance becomes a true dollar COGS cap.
 *
 * Lives HERE (not models.ts) so the $-math stays in one module and the import
 * graph stays one-directional: models.ts is pure data, cost.ts reads it —
 * no cycle.
 *
 * Edge cases:
 *  - estCostUsd null/non-finite (unpriced model, missing usage): fall back to
 *    the model's `fallbackCredits` — a pricing gap must never block or charge 0
 *    (same posture as the null-estimate contract above).
 *  - Unknown modelId: THROW. By the time credits are charged the handler has
 *    already validated the model against ALLOWED_MODELS (Phase 4), so an
 *    unknown id here is a programmer error — fail loud at the bug, matching
 *    the factory's unknown-provider behavior, rather than invent a price.
 */
export function creditCostForModel(modelId: string, estCostUsd: number | null): number {
  const entry = modelById(modelId);
  if (!entry) {
    throw new Error(`creditCostForModel: unknown model '${modelId}' (caller must validate against ALLOWED_MODELS first)`);
  }
  return creditCostForUsd(estCostUsd, entry.fallbackCredits);
}

/**
 * Meter a known USD cost to credits: `ceil(estCostUsd / USD_PER_CREDIT)` with a
 * floor of 1 credit. The model-agnostic core of `creditCostForModel` — used
 * directly where there is NO chat model to carry a per-model fallback (the
 * STT-only dev-transcribe trial charge, X-01 / B-03), with an explicit
 * `fallbackCredits` for the unpriced edge. Keeping the $-math here means the
 * floor-1 ceil rule lives in exactly one place (this module).
 *  - estCostUsd null/non-finite (unpriced): charge `fallbackCredits` — a pricing
 *    gap must never charge 0 (which would re-open the free-endpoint abuse) or block.
 */
export function creditCostForUsd(estCostUsd: number | null, fallbackCredits: number): number {
  if (estCostUsd === null || !Number.isFinite(estCostUsd)) return fallbackCredits;
  return Math.max(1, Math.ceil(estCostUsd / USD_PER_CREDIT)); // floor of 1 credit
}

// The chat provider/model the cost table prices against (configured, not the
// provider's reported response version). Re-exported so the handler logs the
// same key the table is built on.
export { CHAT_MODEL, CHAT_PROVIDER };
