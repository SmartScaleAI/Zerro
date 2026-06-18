// =============================================================================
// refresh-agent-models — orchestration: fetch -> curate -> upsert -> sweep.
// =============================================================================
// Idempotent and safe to run repeatedly. Each provider is processed
// INDEPENDENTLY inside its own try/catch so one provider failing never blocks
// the other and never touches the failing provider's rows:
//
//   1. fetch the live list            (throws on http/transport error)
//   2. curate -> rank                 (pure)
//   3. if curated is EMPTY -> skip writes (a successful-but-empty response, or
//      a regex that suddenly matches nothing, must NOT wipe a provider — an
//      empty deactivate-sweep would mark every model inactive). Logged.
//   4. upsertActive(rows, syncedAt)   (active=true, updated_at=syncedAt)
//   5. deactivateStale(provider, syncedAt)  (vanished models -> active=false)
//
// A throw anywhere in 1–5 leaves that provider's rows exactly as they were
// (we only write AFTER a successful fetch+curate), satisfying "never wipe on a
// failed fetch". The summary reports a per-provider count, or null on failure.
// =============================================================================

import { curate, type FetchedModel } from "./curate.ts";
import { fetchAnthropicModels, type FetchImpl, fetchOpenAIModels } from "./providers.ts";
import type { AgentModelsStore } from "./store.ts";

export interface RefreshDeps {
  store: AgentModelsStore;
  anthropicKey: string;
  openaiKey: string;
  /** Injectable for tests; defaults to the global fetch. */
  fetchImpl?: FetchImpl;
  /** Injectable clock for the per-run sync timestamp; defaults to now(). */
  now?: () => Date;
}

export interface RefreshSummary {
  /** Count of active models written, or null if the provider's fetch failed. */
  anthropic: number | null;
  openai: number | null;
  /** Per-provider failure detail (provider fetch/curate/store error). */
  errors: { provider: string; error: string }[];
}

type Provider = "anthropic" | "openai";

export async function refreshAgentModels(deps: RefreshDeps): Promise<RefreshSummary> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const syncedAt = (deps.now?.() ?? new Date()).toISOString();

  const summary: RefreshSummary = { anthropic: null, openai: null, errors: [] };

  const providers: { name: Provider; fetch: () => Promise<FetchedModel[]> }[] = [
    { name: "anthropic", fetch: () => fetchAnthropicModels(deps.anthropicKey, fetchImpl) },
    { name: "openai", fetch: () => fetchOpenAIModels(deps.openaiKey, fetchImpl) },
  ];

  for (const p of providers) {
    try {
      const fetched = await p.fetch();
      const rows = curate(p.name, fetched);

      // Log the RAW fetched ids next to the kept ids: this is the signal for
      // verifying/tuning the curation regexes against the live provider catalog
      // (a coding model the regex missed shows up here as fetched-but-not-kept).
      // Model ids are public; the lists are small.
      console.log(
        JSON.stringify({
          fn: "refresh-agent-models",
          provider: p.name,
          fetchedIds: fetched.map((m) => m.id),
          keptIds: rows.map((r) => r.model_id),
        }),
      );

      if (rows.length === 0) {
        // Successful fetch but nothing matched — do NOT sweep (that would wipe).
        // Surface it so a broken regex / provider format change is visible.
        console.error(
          JSON.stringify({
            fn: "refresh-agent-models",
            provider: p.name,
            warn: "no_models_matched",
            fetched: fetched.length,
          }),
        );
        summary.errors.push({ provider: p.name, error: "no_models_matched" });
        continue;
      }

      await deps.store.upsertActive(rows, syncedAt);
      const deactivated = await deps.store.deactivateStale(p.name, syncedAt);
      summary[p.name] = rows.length;

      console.log(
        JSON.stringify({
          fn: "refresh-agent-models",
          provider: p.name,
          active: rows.length,
          deactivated,
        }),
      );
    } catch (e) {
      // Leave this provider's rows untouched (no write was reached).
      const error = e instanceof Error ? e.message : String(e);
      console.error(
        JSON.stringify({ fn: "refresh-agent-models", provider: p.name, error }),
      );
      summary.errors.push({ provider: p.name, error });
    }
  }

  return summary;
}
