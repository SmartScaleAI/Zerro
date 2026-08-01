import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { handleBYOKTrial } from "./handler.ts";
import { SupabaseBYOKTrialStore } from "./store.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  return await handleBYOKTrial(req, {
    store: new SupabaseBYOKTrialStore(serviceClient()),
    jwtSecret: requireEnv("SESSION_JWT_SECRET"),
  });
});
