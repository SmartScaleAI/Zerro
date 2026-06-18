// =============================================================================
// refresh-agent-models — persistence seam for the agent_models manifest.
// =============================================================================
// A tiny interface so the refresh orchestration (refresh.ts) is unit-testable
// with an in-memory fake, and the real implementation is the only place that
// speaks supabase-js. Writes go through the service role (RLS bypass).
//
// The vanished->inactive sweep keys off `updated_at`: the refresh stamps every
// upserted row with the per-run sync timestamp, then `deactivateStale` flips
// any still-active row of that provider whose `updated_at` predates the sync
// (i.e. it was NOT in this fetch). This avoids building a NOT-IN id list and is
// race-safe enough for a daily idempotent job.
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

/** A curated manifest row ready to upsert (active=true is implied). */
export interface AgentModelRow {
  provider: "anthropic" | "openai";
  model_id: string;
  display_name: string;
  rank: number;
}

export interface AgentModelsStore {
  /**
   * Upsert `rows` on (provider, model_id): set display_name/rank, active=true,
   * updated_at=`syncedAt`. Reactivates a previously-inactive id that returned.
   */
  upsertActive(rows: AgentModelRow[], syncedAt: string): Promise<void>;
  /**
   * Mark inactive every still-active row of `provider` whose updated_at is
   * older than `syncedAt` (a model that vanished from this fetch). Returns the
   * number of rows deactivated.
   */
  deactivateStale(
    provider: "anthropic" | "openai",
    syncedAt: string,
  ): Promise<number>;
}

export class SupabaseAgentModelsStore implements AgentModelsStore {
  constructor(private readonly db: SupabaseClient) {}

  async upsertActive(rows: AgentModelRow[], syncedAt: string): Promise<void> {
    if (rows.length === 0) return;
    const payload = rows.map((r) => ({
      provider: r.provider,
      model_id: r.model_id,
      display_name: r.display_name,
      rank: r.rank,
      active: true,
      updated_at: syncedAt,
    }));
    const { error } = await this.db
      .from("agent_models")
      .upsert(payload, { onConflict: "provider,model_id" });
    if (error) throw new Error(`upsert_failed: ${error.message}`);
  }

  async deactivateStale(
    provider: "anthropic" | "openai",
    syncedAt: string,
  ): Promise<number> {
    const { data, error } = await this.db
      .from("agent_models")
      .update({ active: false, updated_at: syncedAt })
      .eq("provider", provider)
      .eq("active", true)
      .lt("updated_at", syncedAt)
      .select("id");
    if (error) throw new Error(`deactivate_failed: ${error.message}`);
    return data?.length ?? 0;
  }
}
