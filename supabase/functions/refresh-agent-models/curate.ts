// =============================================================================
// refresh-agent-models — curation: filter to coding chat models, rank, name.
// =============================================================================
// This is the ONLY curation surface for the manifest. Keep it PATTERN-based so
// new model versions appear automatically on the next refresh with no code
// change: a `gpt-5.6` or `claude-opus-4-9` matches the include regex the day the
// provider ships it. The exclude patterns drop the non-chat / non-coding SKUs
// the model-list endpoints also return (embeddings, audio, realtime, image,
// moderation, …) so they never reach the picker.
//
// The exact ids the providers return MUST be verified against a live response
// during the first manual invoke (the review-stop checkpoint) and these regexes
// tuned to match — do not assume the precise ids/format here.
// =============================================================================

import type { AgentModelRow } from "./store.ts";

/** A model as normalized from either provider's list endpoint. */
export interface FetchedModel {
  id: string;
  /** Unix seconds for ranking (newest first). OpenAI `created`; Anthropic's
   *  ISO `created_at` is converted to seconds by the provider fetcher. */
  createdAt: number;
  /** Provider-supplied label (Anthropic `display_name`); absent for OpenAI. */
  displayName?: string;
}

// ---- Anthropic --------------------------------------------------------------
// Coding chat families: opus / sonnet / haiku, version-numbered. Anchored at
// the start and requiring a digit after the family keeps research aliases and
// any non-numbered ids out. New families would need a deliberate edit (a sane
// curation gate), but new VERSIONS of these three flow in automatically.
const ANTHROPIC_INCLUDE = /^claude-(opus|sonnet|haiku)-\d/;

// ---- OpenAI (the Codex coding agent) ----------------------------------------
// The OpenAI agent in Dev Mode is Codex (codex -> openai), whose models are the
// `gpt-*-codex*` family — NOT the base gpt-5 chat models. Verified against the
// live /v1/models response (2026-06-18): the coding models are gpt-5-codex,
// gpt-5.1-codex, gpt-5.1-codex-mini, gpt-5.1-codex-max, gpt-5.2-codex,
// gpt-5.3-codex (so the handoff's guessed `^codex` PREFIX never matches — codex
// is an INFIX). `^gpt-5` was far too broad: it also pulled in 26 base/-pro/
// -mini/-nano chat variants plus dated snapshots. So we match the codex family
// and nothing else.
//   To ALSO offer the base gpt-5 flagships under Codex, add /^gpt-5/ here — but
//   then tighten OPENAI_EXCLUDE for the -pro/-mini/-nano variants you don't want.
const OPENAI_INCLUDE = [/codex/];

// Drop dated snapshots (e.g. gpt-5.1-codex-2026-01-01) — they are duplicates of
// the undated alias and would clutter the picker with ranked dupes / ugly
// names. Also defensively drop any non-chat variant under these names.
const OPENAI_EXCLUDE =
  /(-\d{4}-\d{2}-\d{2}$)|(audio|realtime|transcribe|tts|image|vision|search|embedding|moderation|instruct|chat-latest)/;

/**
 * Title-cases an OpenAI model id into a display name, since the list endpoint
 * gives none. `gpt-5.5` -> "GPT-5.5", `gpt-5.5-mini` -> "GPT-5.5 Mini",
 * `codex-mini` -> "Codex Mini". The GPT family keeps the version glued to the
 * brand with a hyphen (product convention); other segments title-case and join
 * with spaces.
 */
export function deriveOpenAIDisplayName(id: string): string {
  const parts = id.split("-");
  const out: string[] = [];
  for (const part of parts) {
    if (part === "gpt") {
      out.push("GPT");
    } else if (part === "codex") {
      out.push("Codex");
    } else if (/^\d/.test(part)) {
      // A version segment (e.g. "5.5"). Glue it to a preceding "GPT" with a
      // hyphen ("GPT-5.5"); otherwise stand it alone.
      if (out.length > 0 && out[out.length - 1] === "GPT") {
        out[out.length - 1] = `GPT-${part}`;
      } else {
        out.push(part);
      }
    } else {
      out.push(part.charAt(0).toUpperCase() + part.slice(1));
    }
  }
  return out.join(" ");
}

/** Newest-first by createdAt; ties broken by model_id for a stable order. */
function byNewest(a: FetchedModel, b: FetchedModel): number {
  if (b.createdAt !== a.createdAt) return b.createdAt - a.createdAt;
  return a.id.localeCompare(b.id);
}

/**
 * Filter `models` to a provider's coding chat ids, rank newest-first, and
 * project to manifest rows. rank 0 = newest = the default pick. De-dupes by
 * model_id (the list endpoints shouldn't repeat, but a dupe would corrupt the
 * `(provider, model_id)` upsert).
 */
export function curate(
  provider: "anthropic" | "openai",
  models: FetchedModel[],
): AgentModelRow[] {
  const include = (id: string): boolean =>
    provider === "anthropic"
      ? ANTHROPIC_INCLUDE.test(id)
      : OPENAI_INCLUDE.some((re) => re.test(id)) && !OPENAI_EXCLUDE.test(id);

  const seen = new Set<string>();
  const kept = models
    .filter((m) => include(m.id))
    .filter((m) => (seen.has(m.id) ? false : (seen.add(m.id), true)))
    .sort(byNewest);

  return kept.map((m, rank) => ({
    provider,
    model_id: m.id,
    display_name: provider === "anthropic"
      ? (m.displayName?.trim() || m.id)
      : deriveOpenAIDisplayName(m.id),
    rank,
  }));
}
