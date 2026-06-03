// =============================================================================
// session — exchanges a license key for a short-lived signed token (§6.3),
// with the §14.6 missed-webhook staleness re-check (Phase G).
// =============================================================================
// The credential here is the LICENSE KEY, not a Supabase JWT (the function is
// deployed verify_jwt = false). The anti-abuse control on this exchange is the
// per-key + per-IP rate limit; TLS protects the key in transit.
//
// Flow:
//   1. Rate-limit per IP (cheap, pre-hash) and per key-hash.
//   2. Hash the key; look up the subscription mirror by license_key_hash.
//   3. status in (cancelled, expired) or not found → 403, no token.
//   4. §14.6 STALENESS RE-CHECK: if the mirror hasn't been touched by a webhook
//      (or a prior live re-check) within SESSION_STALENESS_SECONDS, do a LIVE
//      LemonSqueezy status lookup before minting:
//        - CONCLUSIVE cancelled/expired → reconcile the mirror + 403 (this is the
//          dropped-webhook catch: a non-paying user can't keep minting forever).
//        - CONCLUSIVE active/past_due    → reconcile the mirror (resets the
//          freshness anchor) and mint with the live status.
//        - INCONCLUSIVE (LS down / no API key / parse fail) → FAIL OPEN, mint
//          with the existing mirror status. An LS outage must never lock out a
//          paying user; spend is still gated server-side at generate time.
//   5. active OR past_due → mint a short-lived JWT (past_due keeps working, §9.1)
//      + return the entitlement snapshot.
//
// The handler depends on injected deps (store, ls client, clock) so the
// staleness re-check is unit-testable with an in-memory store + stub LS client.
// =============================================================================

import { sha256Hex } from "../_shared/crypto.ts";
import { signSessionToken } from "../_shared/jwt.ts";
import { json } from "../_shared/http.ts";
import type { LemonSqueezyClient } from "../_shared/lemonsqueezy.ts";
import type { SessionStore, SessionSubRow } from "./store.ts";
import {
  SESSION_RATE_LIMIT_PER_IP,
  SESSION_RATE_LIMIT_PER_KEY,
  SESSION_RATE_LIMIT_WINDOW_SECONDS,
  SESSION_STALENESS_SECONDS,
  SESSION_TOKEN_TTL_SECONDS,
} from "../_shared/config.ts";
import type { SessionResponse } from "../_shared/types.ts";

export interface SessionDeps {
  store: SessionStore;
  jwtSecret: string;
  /**
   * Live LemonSqueezy status client for the §14.6 re-check, or null to DISABLE
   * the live check (e.g. LEMONSQUEEZY_API_KEY unset). Disabled → fail-open mint
   * (the staleness guard simply doesn't run; logged once at the call site).
   */
  ls: LemonSqueezyClient | null;
  /** Injectable wall clock (epoch ms) for deterministic staleness tests. */
  nowMs?: number;
  /** Injectable token clock (epoch seconds) for deterministic exp tests. */
  nowSeconds?: number;
  /** Override the staleness window (seconds) in tests. */
  staleSeconds?: number;
}

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

/** TRUE if the mirror row hasn't been touched within the staleness window. */
function isStale(updatedAt: string | null, nowMs: number, staleSeconds: number): boolean {
  if (!updatedAt) return true; // never stamped → treat as stale (re-check it)
  const t = new Date(updatedAt).getTime();
  if (!Number.isFinite(t)) return true; // unparseable → re-check
  return nowMs - t > staleSeconds * 1000;
}

export async function handleSession(req: Request, deps: SessionDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Parse input.
  let licenseKey: string;
  try {
    const body = await req.json();
    licenseKey = String(body?.license_key ?? "").trim();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  if (!licenseKey) return json({ error: "missing_license_key" }, 400);

  // 1. Per-IP limit first (cheap, pre-hash).
  const ip = clientIp(req);
  if (!(await deps.store.rateLimitOk(`session:ip:${ip}`, SESSION_RATE_LIMIT_PER_IP, SESSION_RATE_LIMIT_WINDOW_SECONDS))) {
    return json({ error: "rate_limited" }, 429);
  }

  const keyHash = await sha256Hex(licenseKey);

  // Per-key limit (anti brute-force on a single key).
  if (!(await deps.store.rateLimitOk(`session:keyhash:${keyHash}`, SESSION_RATE_LIMIT_PER_KEY, SESSION_RATE_LIMIT_WINDOW_SECONDS))) {
    return json({ error: "rate_limited" }, 429);
  }

  // 2. Look up the subscription mirror by key hash.
  let sub: SessionSubRow | null;
  try {
    sub = await deps.store.findByKeyHash(keyHash);
  } catch {
    return json({ error: "server_error" }, 500);
  }

  // 3. Not found OR already-terminal status → no token (§6.3 step 4).
  if (!sub || sub.status === "cancelled" || sub.status === "expired") {
    return json({ error: "not_entitled" }, 403);
  }

  // 4. §14.6 staleness re-check. Only when the mirror is stale AND a live client
  //    is configured. A dropped cancelled/expired webhook is caught here.
  const nowMs = deps.nowMs ?? Date.now();
  const staleSeconds = deps.staleSeconds ?? SESSION_STALENESS_SECONDS;
  if (isStale(sub.updated_at, nowMs, staleSeconds)) {
    if (deps.ls) {
      const live = await deps.ls.getSubscriptionStatus(sub.ls_subscription_id);
      if (live !== null) {
        // Conclusive answer → reconcile the mirror (also resets the freshness
        // anchor so the next mint skips the call) and act on the LIVE status.
        await deps.store.reconcileStatus(sub.id, live);
        if (live === "cancelled" || live === "expired") {
          console.warn(JSON.stringify({
            fn: "session",
            warn: "stale_recheck_revoked",
            subscriptionId: sub.id,
            live,
          }));
          return json({ error: "not_entitled" }, 403);
        }
        sub = { ...sub, status: live };
      } else {
        // Inconclusive → fail open (mint with the existing mirror status).
        console.warn(JSON.stringify({
          fn: "session",
          warn: "stale_recheck_inconclusive_fail_open",
          subscriptionId: sub.id,
        }));
      }
    } else {
      // Live client disabled (LEMONSQUEEZY_API_KEY unset) → guard off, fail open.
      console.warn(JSON.stringify({
        fn: "session",
        warn: "stale_recheck_disabled_no_api_key",
        subscriptionId: sub.id,
      }));
    }
  }

  // 5. active OR past_due → mint a token (past_due keeps working, §9.1).
  const { token, exp } = await signSessionToken(
    { sub: sub.id, tier: sub.tier, kind: "subscription" },
    deps.jwtSecret,
    SESSION_TOKEN_TTL_SECONDS,
    deps.nowSeconds,
  );

  const entitlement = await deps.store.buildSnapshot(sub);

  const resp: SessionResponse = {
    token,
    expires_at: new Date(exp * 1000).toISOString(),
    entitlement,
  };
  return json(resp, 200);
}
