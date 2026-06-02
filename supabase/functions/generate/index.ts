// =============================================================================
// generate — Deno.serve entrypoint (Phase D2). Thin wiring only; the full flow
// lives in handler.ts (so it's unit-testable with injected deps).
// =============================================================================
// Deployed with verify_jwt = false at the Supabase gateway — exactly like
// `entitlement`. We verify OUR OWN session JWT (HS256, SESSION_JWT_SECRET) IN
// CODE inside handleGenerate; if the gateway also demanded a Supabase JWT it
// would reject the app's token before our code runs. See config.toml /
// README-backend.md.
//
// The OPENAI_API_KEY secret is read HERE and handed to the HTTP client. It is
// never returned to the client and never logged.
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { handleGenerate } from "./handler.ts";
import { HttpOpenAIClient } from "./openai.ts";
import { SupabaseBillingStore } from "./store.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  const openaiKey = requireEnv("OPENAI_API_KEY");

  return await handleGenerate(req, {
    store: new SupabaseBillingStore(serviceClient()),
    openai: new HttpOpenAIClient(openaiKey),
    jwtSecret,
  });
});
