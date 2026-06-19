// =============================================================================
// entitlement — read-only status for display (tier / credits / reset / status).
// =============================================================================
// Deployed with verify_jwt = false at the SUPABASE GATEWAY, because this
// function verifies OUR session JWT itself, IN CODE (HS256, SESSION_JWT_SECRET)
// — not a Supabase gateway JWT. Do not deploy this with verify_jwt = true or the
// gateway will reject the app's token before our code runs. See config.toml.
//
// DISPLAY ONLY: this endpoint never authorizes spend. The credit decision lives
// in the D2 `generate` proxy (atomic consume_credit). The app shows these
// numbers (menu-bar credits line, Billing readout) and renders the past_due
// nudge from `status`, but never gates generation on them.

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { buildEntitlementSnapshot, type SubscriptionRow } from "../_shared/entitlement.ts";
import { handlePreflight, json } from "../_shared/http.ts";

function bearer(req: Request): string | null {
  const h = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!h) return null;
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;
  if (req.method !== "GET" && req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  const db = serviceClient();

  const token = bearer(req);
  if (!token) return json({ error: "missing_token" }, 401);

  const claims = await verifySessionToken(token, jwtSecret);
  if (!claims) return json({ error: "invalid_token" }, 401);

  // Subscriptions only. A trial token's credit balance is returned inline by
  // `trial-start` (on verify) and by every `generate` response — the app never
  // needs to call /entitlement with a trial token, so this endpoint stays
  // subscription-only rather than growing an email-keyed read path (Phase F).
  if (claims.kind !== "subscription") {
    return json({ error: "unsupported_token_kind" }, 401);
  }

  const { data: sub, error } = await db
    .from("subscriptions")
    .select("id, tier, status, credits_limit, current_period_end, billing_interval, trial_grant_id")
    .eq("id", claims.sub)
    .maybeSingle();
  if (error) {
    console.error(JSON.stringify({ fn: "entitlement", error: error.message }));
    return json({ error: "server_error" }, 500);
  }
  if (!sub) return json({ error: "not_found" }, 404);

  const entitlement = await buildEntitlementSnapshot(db, sub as SubscriptionRow);
  return json(entitlement, 200);
});

// Phase D2: the `generate` proxy will live in its own function (functions/
// generate/). It will verify this same session token, re-check status server-
// side, enforce input limits, run Whisper + the server-owned system prompt with
// the OpenAI key, and call consume_credit() atomically on success. NOT here.
