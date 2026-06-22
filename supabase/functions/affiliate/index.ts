// =============================================================================
// affiliate — Deno.serve entrypoint. Thin wiring; logic lives in handler.ts.
// =============================================================================
// Deployed with verify_jwt = false: PUBLIC. The website POSTs `?aff` codes here
// on landing; the app GETs the code matched to its public IP just before
// opening checkout. Security model: the only thing keyed on is the CALLER's own
// public IP (read from the proxy headers), which can't be forged for someone
// else, plus the hashed-IP storage (raw IP never persisted). See the migration
// 20260622120000_affiliate_referrals.sql and README-backend.md.
//
// Secrets read here: AFFILIATE_IP_SALT (mixed into the IP hash; never logged or
// returned). AFFILIATE_MATCH_WINDOW_HOURS is an optional tuning knob (default
// 720 = 30 days) for how long after a click a purchase can still be attributed.
// =============================================================================

import { serviceClient } from "../_shared/db.ts";
import { optionalEnvInt, requireEnv } from "../_shared/env.ts";
import { handleAffiliate } from "./handler.ts";
import { SupabaseAffiliateStore } from "./store.ts";

Deno.serve((req: Request) =>
  handleAffiliate(req, {
    store: new SupabaseAffiliateStore(serviceClient()),
    salt: requireEnv("AFFILIATE_IP_SALT"),
    windowHours: optionalEnvInt("AFFILIATE_MATCH_WINDOW_HOURS", 720),
  })
);
