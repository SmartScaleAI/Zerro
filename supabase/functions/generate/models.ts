// =============================================================================
// Model registry — the single source of truth for the user-selectable models
// (multi-model plan §1.1 / Phase 2).
// =============================================================================
// Every place that needs "which models exist, who serves them, what they cost
// in credits" reads THIS table: request validation (Phase 4) gates on
// ALLOWED_MODELS, the handler resolves provider + fallbackCredits via modelById,
// and the app's picker is fed from the same data. Do not duplicate these
// entries elsewhere.
//
// This module is PURE DATA — no env, no config imports — so anything can
// import it without dragging environment evaluation into tests.
//
// THIRD MIRROR / KEEP IN SYNC: this registry is mirrored by the eval harness
// (apps/desktop/Scripts/eval-models.mjs) and the Swift app
// (apps/desktop/Zerro/Services/ModelRegistry.swift). CHARGE MODEL: the credit
// charge is now METERED — every generation is billed the real measured cost,
// `ceil(est_cost_usd / USD_PER_CREDIT)` with a floor of 1 (see cost.ts
// `creditCostForModel`). `fallbackCredits` below is NO LONGER the charge: it is
// only the per-model fallback estimate used when the real cost is unavailable
// (unpriced model / missing token usage), so a pricing gap never charges 0 or
// blocks.
//
// CALIBRATION CAVEAT (plan §2): the fallbackCredits values are calibration v1 —
// real token shape × published June-2026 API rates, validated against measured
// Gemini Flash spend and the Phase 0 eval runs. They are starting points for the
// fallback only, not permanent truth. POST-LAUNCH TASK: after a few hundred
// multi-model generations, recompute real p75 cost per model from the
// now-model-tagged `generation_log` and retune each fallbackCredits below (a
// one-line edit + redeploy; no migration).
//
// `enabled` is the kill switch: setting it false drops a model from
// ALLOWED_MODELS (new requests 400) without a schema or app change, e.g. if a
// model's output contract regresses in a provider update. Phase 0 verdict:
// all six PASS (apps/desktop/eval-results/PHASE0-GATE-SUMMARY.md).
// =============================================================================

export type ModelProvider = "openai" | "gemini" | "anthropic";

export interface ModelEntry {
  /** The exact provider API model id — also the wire value the app sends. */
  id: string;
  provider: ModelProvider;
  /** User-facing name in the picker. */
  displayName: string;
  /**
   * Per-model FALLBACK credit estimate (1 credit = $0.01). NOT the charge —
   * generations are metered on real cost (cost.ts `creditCostForModel`). This
   * value is used ONLY when the real cost is unavailable (unpriced model /
   * missing token usage), so a pricing gap never charges 0 or blocks.
   */
  fallbackCredits: number;
  /** The picker's "Recommended for Zerro" badge (exactly one model). */
  recommended?: boolean;
  /** false = dark-disabled: stays out of ALLOWED_MODELS, no deploy needed. */
  enabled: boolean;
}

// Ordered by fallbackCredits ascending — the picker renders cheapest-first
// (plan 6A) and this order is the product's "label by cost, not quality".
export const MODEL_REGISTRY: readonly ModelEntry[] = [
  { id: "gpt-5.4-mini", provider: "openai", displayName: "GPT-5.4 mini", fallbackCredits: 2, enabled: true },
  { id: "gemini-3.5-flash", provider: "gemini", displayName: "Gemini 3.5 Flash", fallbackCredits: 4, recommended: true, enabled: true },
  { id: "gemini-3.1-pro-preview", provider: "gemini", displayName: "Gemini 3.1 Pro", fallbackCredits: 5, enabled: true },
  { id: "claude-sonnet-4-6", provider: "anthropic", displayName: "Claude Sonnet 4.6", fallbackCredits: 7, enabled: true },
  { id: "claude-opus-4-7", provider: "anthropic", displayName: "Claude Opus 4.7", fallbackCredits: 10, enabled: true },
  { id: "gpt-5.5", provider: "openai", displayName: "GPT-5.5", fallbackCredits: 11, enabled: true },
];

/**
 * The request-validation gate (Phase 4): a client-supplied `model` not in this
 * set is rejected 400 before any provider work. Derived from ENABLED entries
 * only, so flipping `enabled` is the complete kill switch.
 */
export const ALLOWED_MODELS: ReadonlySet<string> = new Set(
  MODEL_REGISTRY.filter((m) => m.enabled).map((m) => m.id),
);

const BY_ID: ReadonlyMap<string, ModelEntry> = new Map(
  MODEL_REGISTRY.map((m) => [m.id, m]),
);

/**
 * Plain registry lookup — returns the entry whether or not it is enabled
 * (ALLOWED_MODELS is the gate; this is the resolver used AFTER validation,
 * and disabled entries stay resolvable for logging/display of historic rows).
 */
export function modelById(id: string): ModelEntry | undefined {
  return BY_ID.get(id);
}

// The model used when a request omits `model` (Phase 4, pre-multi-model apps):
// the registry's RECOMMENDED entry — NOT env CHAT_MODEL. Documented choice:
// the env default (gpt-4o) is not a registry model and has no fallbackCredits, so
// it can't be charged under variable credits; the recommended model is the
// product default the picker shows, so an un-updated app gets exactly what a
// fresh install would. Falls back to the cheapest enabled entry if the
// recommended one is ever kill-switched; an empty registry is a deploy bug —
// fail loud at import, not 500-per-request.
const defaultEntry = MODEL_REGISTRY.find((m) => m.recommended && m.enabled) ??
  MODEL_REGISTRY.find((m) => m.enabled);
if (!defaultEntry) throw new Error("MODEL_REGISTRY has no enabled entries");
export const DEFAULT_MODEL_ID: string = defaultEntry.id;
