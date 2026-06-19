// =============================================================================
// agent-models — public GET of the Dev Mode model manifest. Thin wiring; the
// grouping is in group.ts (unit-tested).
// =============================================================================
// Deployed with verify_jwt = false at the Supabase gateway (see config.toml).
// UNAUTHENTICATED by design: the payload is a list of PUBLIC model ids — no
// credential, no user data — and the app must be able to read it at launch
// without a session. (The WRITE path stays service-role-only via RLS; this
// read is the only public surface, and it can only ever expose model ids.)
//
// Reads active rows ordered by (provider, rank) through the service role and
// returns them grouped by provider with a short Cache-Control (the manifest
// changes at most once a day via the refresh cron).
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { corsHeaders, handlePreflight, json } from "../_shared/http.ts";
import { groupByProvider, type ManifestRow } from "./group.ts";

/** Short cache — the manifest is refreshed at most daily; an hour is plenty. */
const CACHE_CONTROL = "public, max-age=3600";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;
  if (req.method !== "GET" && req.method !== "HEAD") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const db = serviceClient();
  const { data, error } = await db
    .from("agent_models")
    .select("provider, model_id, display_name")
    .eq("active", true)
    .order("provider", { ascending: true })
    .order("rank", { ascending: true });

  if (error) {
    console.error(JSON.stringify({ fn: "agent-models", error: error.message }));
    return json({ error: "server_error" }, 500);
  }

  const body = groupByProvider((data ?? []) as ManifestRow[]);

  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": CACHE_CONTROL,
    },
  });
});
