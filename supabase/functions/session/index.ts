// =============================================================================
// session — exchanges a license key for a short-lived signed token (§6.3).
// =============================================================================
// Deployed with verify_jwt = false: the LICENSE KEY is the credential here, not
// a Supabase JWT. The anti-abuse control is the per-key + per-IP rate limit on
// this credential exchange (§14.2/§14.3). TLS protects the key in transit.
//
// Flow:
//   1. POST { license_key }.
//   2. Rate-limit per IP and per key-hash (basic fixed-window limiter).
//   3. Hash the key; look up subscriptions by license_key_hash.
//   4. status in (active, past_due) → mint a JWT (sub, tier, exp) + return the
//      current entitlement snapshot. past_due STILL gets a token (§9.1 — they
//      keep working on remaining credits).
//   5. status in (cancelled, expired) or not found → 403, no token.

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { signSessionToken } from "../_shared/jwt.ts";
import { buildEntitlementSnapshot, type SubscriptionRow } from "../_shared/entitlement.ts";
import { handlePreflight, json } from "../_shared/http.ts";
import {
  SESSION_RATE_LIMIT_PER_IP,
  SESSION_RATE_LIMIT_PER_KEY,
  SESSION_RATE_LIMIT_WINDOW_SECONDS,
  SESSION_TOKEN_TTL_SECONDS,
} from "../_shared/config.ts";
import type { SessionResponse } from "../_shared/types.ts";

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

async function rateLimited(
  db: ReturnType<typeof serviceClient>,
  key: string,
  max: number,
): Promise<boolean> {
  const { data, error } = await db.rpc("check_rate_limit", {
    p_key: key,
    p_max: max,
    p_window_seconds: SESSION_RATE_LIMIT_WINDOW_SECONDS,
  });
  if (error) {
    // Fail OPEN on limiter infra error: a broken limiter must not lock out a
    // paying user. (Spend is still gated server-side at generate time.)
    console.error(JSON.stringify({ fn: "session", warn: "ratelimit_error", error: error.message }));
    return false;
  }
  return data === false;
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const jwtSecret = requireEnv("SESSION_JWT_SECRET");
  const db = serviceClient();

  // Parse input.
  let licenseKey: string;
  try {
    const body = await req.json();
    licenseKey = String(body?.license_key ?? "").trim();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  if (!licenseKey) return json({ error: "missing_license_key" }, 400);

  // Per-IP limit first (cheap, pre-hash).
  const ip = clientIp(req);
  if (await rateLimited(db, `session:ip:${ip}`, SESSION_RATE_LIMIT_PER_IP)) {
    return json({ error: "rate_limited" }, 429);
  }

  const keyHash = await sha256Hex(licenseKey);

  // Per-key limit (anti brute-force on a single key).
  if (await rateLimited(db, `session:keyhash:${keyHash}`, SESSION_RATE_LIMIT_PER_KEY)) {
    return json({ error: "rate_limited" }, 429);
  }

  // Look up the subscription mirror by key hash.
  const { data: sub, error } = await db
    .from("subscriptions")
    .select("id, tier, status, credits_limit, current_period_end, updated_at")
    .eq("license_key_hash", keyHash)
    .maybeSingle();
  if (error) {
    console.error(JSON.stringify({ fn: "session", error: error.message }));
    return json({ error: "server_error" }, 500);
  }

  // Not found OR terminal status → no token (§6.3 step 4).
  if (!sub || sub.status === "cancelled" || sub.status === "expired") {
    return json({ error: "not_entitled" }, 403);
  }

  // DEFERRED Phase G: staleness re-check. If `sub.updated_at` is older than the
  // staleness window (≈ SESSION_TOKEN_TTL_SECONDS), do a LIVE LemonSqueezy
  // status lookup before minting, so a missed `cancelled` webhook can't keep
  // minting tokens forever (§14.6 — the missed-webhook money-leak guard). The
  // seam is here; the live LS call is intentionally not made in D1.
  // ---------------------------------------------------------------------------

  // active OR past_due → mint a token (past_due keeps working, §9.1).
  const { token, exp } = await signSessionToken(
    { sub: sub.id, tier: sub.tier, kind: "subscription" },
    jwtSecret,
    SESSION_TOKEN_TTL_SECONDS,
  );

  const entitlement = await buildEntitlementSnapshot(db, sub as SubscriptionRow);

  const resp: SessionResponse = {
    token,
    expires_at: new Date(exp * 1000).toISOString(),
    entitlement,
  };
  return json(resp, 200);
});
