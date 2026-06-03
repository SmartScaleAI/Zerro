// =============================================================================
// session — thin entrypoint. All logic (incl. the §14.6 staleness re-check) is
// in handler.ts so it is unit-testable with an in-memory store + stub LS client.
// =============================================================================
// Deployed with verify_jwt = false: the LICENSE KEY is the credential here, not
// a Supabase JWT. The anti-abuse control is the per-key + per-IP rate limit on
// this credential exchange (§14.2/§14.3). See config.toml + README-backend.md.

import { serviceClient } from "../_shared/db.ts";
import { requireEnv, optionalEnv } from "../_shared/env.ts";
import { handlePreflight } from "../_shared/http.ts";
import { LEMONSQUEEZY_API_BASE } from "../_shared/config.ts";
import { HttpLemonSqueezyClient, type LemonSqueezyClient } from "../_shared/lemonsqueezy.ts";
import { SupabaseSessionStore } from "./store.ts";
import { handleSession } from "./handler.ts";

// Build the live LemonSqueezy client ONCE at boot. If the API key isn't set the
// §14.6 staleness re-check is disabled (session fails open — see handler.ts);
// the key being unset is an infra condition, not a revocation.
const lsApiKey = optionalEnv("LEMONSQUEEZY_API_KEY", "");
const lsClient: LemonSqueezyClient | null = lsApiKey
  ? new HttpLemonSqueezyClient(lsApiKey, LEMONSQUEEZY_API_BASE)
  : null;
if (!lsClient) {
  console.warn(JSON.stringify({
    fn: "session",
    warn: "lemonsqueezy_api_key_unset_staleness_guard_disabled",
  }));
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  const store = new SupabaseSessionStore(serviceClient());

  return await handleSession(req, { store, jwtSecret, ls: lsClient });
});
