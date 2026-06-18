// =============================================================================
// refresh-agent-models — curation: filter to coding chat models, rank, name.
// =============================================================================
// ANTHROPIC ONLY. OpenAI was retired (2026-06-18): Codex sources its model list
// from its OWN per-account tool (a ChatGPT-account Codex uses its own slugs and
// rejects the OpenAI API codex ids), so the OpenAI side of this manifest was
// unused — the app now reads Codex's list client-side. Claude Code is the only
// manifest-served agent.
//
// This is the ONLY curation surface for the manifest. Keep it PATTERN-based so
// new Claude versions appear automatically on the next refresh with no code
// change: a `claude-opus-4-9` matches the include regex the day Anthropic ships
// it. The exact ids MUST be verified against a live response (the manual invoke)
// and the regex tuned to match — do not assume the precise ids/format here.
// =============================================================================

import type { AgentModelRow } from "./store.ts";

/** A model as normalized from the provider's list endpoint. */
export interface FetchedModel {
  id: string;
  /** Unix seconds for ranking (newest first). Anthropic's ISO `created_at` is
   *  converted to seconds by the provider fetcher. */
  createdAt: number;
  /** Provider-supplied label (Anthropic `display_name`). */
  displayName?: string;
}

// Coding chat families: opus / sonnet / haiku, version-numbered. Anchored at the
// start and requiring a digit after the family keeps research aliases and any
// non-numbered ids out. New families would need a deliberate edit (a sane
// curation gate), but new VERSIONS of these three flow in automatically.
const ANTHROPIC_INCLUDE = /^claude-(opus|sonnet|haiku)-\d/;

/** Newest-first by createdAt; ties broken by model_id for a stable order. */
function byNewest(a: FetchedModel, b: FetchedModel): number {
  if (b.createdAt !== a.createdAt) return b.createdAt - a.createdAt;
  return a.id.localeCompare(b.id);
}

/**
 * Filter `models` to Anthropic's coding chat ids, rank newest-first, and project
 * to manifest rows. rank 0 = newest = the default pick. De-dupes by model_id
 * (the list endpoint shouldn't repeat, but a dupe would corrupt the
 * `(provider, model_id)` upsert).
 */
export function curate(models: FetchedModel[]): AgentModelRow[] {
  const seen = new Set<string>();
  const kept = models
    .filter((m) => ANTHROPIC_INCLUDE.test(m.id))
    .filter((m) => (seen.has(m.id) ? false : (seen.add(m.id), true)))
    .sort(byNewest);

  return kept.map((m, rank) => ({
    provider: "anthropic",
    model_id: m.id,
    display_name: m.displayName?.trim() || m.id,
    rank,
  }));
}
