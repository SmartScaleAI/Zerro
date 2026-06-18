// =============================================================================
// refresh-agent-models — Deno.serve entrypoint. Thin wiring + auth; the flow
// lives in refresh.ts (unit-testable with injected deps).
// =============================================================================
// Deployed with verify_jwt = false at the Supabase gateway (see config.toml):
// the caller is the daily pg_cron job (server-side net.http_post), NOT an app
// holding a Supabase JWT. Security is the shared REFRESH_CRON_SECRET checked IN
// CODE (constant-time) against the `x-refresh-secret` header the cron sends —
// the gateway gate is OFF so that header reaches our code.
//
// Reuses the SAME ANTHROPIC_API_KEY the `generate` proxy holds (read here, never
// returned to the caller). OpenAI is retired — Codex sources its own list. The
// service-role DB client is the only writer to agent_models (RLS bypass).
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { timingSafeEqual } from "../_shared/crypto.ts";
import { handlePreflight, json } from "../_shared/http.ts";
import { refreshAgentModels } from "./refresh.ts";
import { SupabaseAgentModelsStore } from "./store.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // --- Auth: shared secret, constant-time. Reject before any provider call. ---
  const expected = requireEnv("REFRESH_CRON_SECRET");
  const provided = req.headers.get("x-refresh-secret") ?? "";
  if (!timingSafeEqual(provided, expected)) {
    return json({ error: "unauthorized" }, 401);
  }

  const anthropicKey = requireEnv("ANTHROPIC_API_KEY");

  const summary = await refreshAgentModels({
    store: new SupabaseAgentModelsStore(serviceClient()),
    anthropicKey,
  });

  // 200 even when a provider failed: the job is best-effort and the per-provider
  // result is in the body. A non-2xx here would just make the cron log noise for
  // a transient provider blip that left the existing rows correctly untouched.
  return json(summary, 200);
});
