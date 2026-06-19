// =============================================================================
// agent-models — pure shaping of the manifest read into the wire response.
// =============================================================================
// The DB query does the work that needs the DB (active-only filter + ordering
// by (provider, rank)); this module just GROUPS the already-ordered rows by
// provider and projects to the public fields. Kept pure so the grouping /
// ordering / field-projection contract is unit-testable without a database.
//
// Wire shape the app consumes:
//   { providers: { anthropic: [{ model_id, display_name }], openai: [...] } }
// Both keys are ALWAYS present (possibly empty) so the app can map
// agent->provider->list without null-checking the provider key.
// =============================================================================

export interface ManifestRow {
  provider: string;
  model_id: string;
  display_name: string;
}

export interface ManifestEntry {
  model_id: string;
  display_name: string;
}

export interface ManifestResponse {
  providers: {
    anthropic: ManifestEntry[];
    openai: ManifestEntry[];
  };
}

const PROVIDERS = ["anthropic", "openai"] as const;

/**
 * Group `rows` (assumed already ordered by the caller's query: provider, then
 * rank ascending) into the wire response. Rows for an unknown provider are
 * ignored. Per-provider order is preserved from the input.
 */
export function groupByProvider(rows: ManifestRow[]): ManifestResponse {
  const providers: ManifestResponse["providers"] = { anthropic: [], openai: [] };
  for (const row of rows) {
    if ((PROVIDERS as readonly string[]).includes(row.provider)) {
      providers[row.provider as (typeof PROVIDERS)[number]].push({
        model_id: row.model_id,
        display_name: row.display_name,
      });
    }
  }
  return { providers };
}
