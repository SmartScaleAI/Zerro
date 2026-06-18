// =============================================================================
// refresh-agent-models — orchestration: fetch -> curate -> upsert -> sweep.
// =============================================================================
// ANTHROPIC ONLY (OpenAI retired — Codex sources its own per-account list).
// Idempotent and safe to run repeatedly:
//
//   1. fetch Anthropic's live list   (throws on http/transport error)
//   2. curate -> rank               (pure)
//   3. if curated is EMPTY -> skip writes (a successful-but-empty response, or
//      a regex that suddenly matches nothing, must NOT wipe the table — an
//      empty deactivate-sweep would mark every model inactive). Logged.
//   4. upsertActive(rows, syncedAt)   (active=true, updated_at=syncedAt)
//   5. deactivateStale("anthropic", syncedAt)  (vanished models -> active=false)
//
// A throw anywhere in 1-5 leaves the rows exactly as they were (we only write
// AFTER a successful fetch+curate), satisfying "never wipe on a failed fetch".
// =============================================================================

import { curate } from "./curate.ts";
import { fetchAnthropicModels, type FetchImpl } from "./providers.ts";
import type { AgentModelsStore } from "./store.ts";

export interface RefreshDeps {
  store: AgentModelsStore;
  anthropicKey: string;
  /** Injectable for tests; defaults to the global fetch. */
  fetchImpl?: FetchImpl;
  /** Injectable clock for the per-run sync timestamp; defaults to now(). */
  now?: () => Date;
}

export interface RefreshSummary {
  /** Count of active models written, or null if the fetch failed/was empty. */
  anthropic: number | null;
  /** Failure detail (fetch/curate/store error, or "no_models_matched"). */
  errors: { provider: string; error: string }[];
}

export async function refreshAgentModels(deps: RefreshDeps): Promise<RefreshSummary> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const syncedAt = (deps.now?.() ?? new Date()).toISOString();

  const summary: RefreshSummary = { anthropic: null, errors: [] };

  try {
    const fetched = await fetchAnthropicModels(deps.anthropicKey, fetchImpl);
    const rows = curate(fetched);

    // Log the RAW fetched ids next to the kept ids: the signal for verifying /
    // tuning the curation regex against the live catalog (a coding model the
    // regex missed shows up here as fetched-but-not-kept). Ids are public.
    console.log(
      JSON.stringify({
        fn: "refresh-agent-models",
        provider: "anthropic",
        fetchedIds: fetched.map((m) => m.id),
        keptIds: rows.map((r) => r.model_id),
      }),
    );

    if (rows.length === 0) {
      // Successful fetch but nothing matched — do NOT sweep (that would wipe).
      console.error(
        JSON.stringify({
          fn: "refresh-agent-models",
          provider: "anthropic",
          warn: "no_models_matched",
          fetched: fetched.length,
        }),
      );
      summary.errors.push({ provider: "anthropic", error: "no_models_matched" });
      return summary;
    }

    await deps.store.upsertActive(rows, syncedAt);
    const deactivated = await deps.store.deactivateStale("anthropic", syncedAt);
    summary.anthropic = rows.length;

    console.log(
      JSON.stringify({
        fn: "refresh-agent-models",
        provider: "anthropic",
        active: rows.length,
        deactivated,
      }),
    );
  } catch (e) {
    // Leave the rows untouched (no write was reached).
    const error = e instanceof Error ? e.message : String(e);
    console.error(JSON.stringify({ fn: "refresh-agent-models", provider: "anthropic", error }));
    summary.errors.push({ provider: "anthropic", error });
  }

  return summary;
}
