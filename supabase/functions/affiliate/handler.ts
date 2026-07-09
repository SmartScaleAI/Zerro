// =============================================================================
// affiliate — handler logic (pure-ish; deps injected for unit tests).
// =============================================================================
// Two actions on one public endpoint:
//   • POST { aff }  — the website records a referral code seen on a landing
//     page, keyed to a HASH of the caller's public IP.
//   • GET           — the app asks for the most recent code matching the
//     caller's IP hash within the window, to tag checkout as `aff_ref`.
//
// The only "credential" is the caller's own public IP (read from the proxy
// headers), which a caller can't forge on another visitor's behalf — so this is
// safe to expose unauthenticated. The raw IP is never persisted; we hash it
// with a server-side salt so the stored value can match the same egress IP but
// not be reversed back to it.
// =============================================================================

import { sha256Hex } from "../_shared/crypto.ts";
import { handlePreflight, json } from "../_shared/http.ts";
import {
  AFFILIATE_RATE_LIMIT_PER_IP,
  AFFILIATE_RATE_LIMIT_WINDOW_SECONDS,
} from "./config.ts";

/** The persistence surface the handler needs — a fake stands in for unit tests. */
export interface AffiliateStore {
  /** Record the latest (ip_hash → aff_code) mapping. C-08: an UPSERT keyed on
   * the unique ip_hash — one row per visitor IP, latest code + timestamp win.
   * Throws on a real DB failure. */
  record(ipHash: string, affCode: string): Promise<void>;
  /** The most recent aff_code for `ipHash` at/after `sinceISO`, or null. */
  latestCode(ipHash: string, sinceISO: string): Promise<string | null>;
  /** TRUE if within the limit for the current window (check_rate_limit). The
   * impl fails OPEN on limiter error — see store.ts for the C-08 rationale. */
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
}

export interface AffiliateDeps {
  store: AffiliateStore;
  /** Secret salt mixed into the IP hash (Edge secret AFFILIATE_IP_SALT). */
  salt: string;
  /** How far back a GET will match a recorded click. */
  windowHours: number;
}

/**
 * The original client IP: first hop of `x-forwarded-for` (Supabase/Deno set
 * this), falling back to `x-real-ip`. Returns null when neither is present.
 */
export function clientIp(headers: Headers): string | null {
  const xff = headers.get("x-forwarded-for");
  if (xff) {
    const first = xff.split(",")[0]?.trim();
    if (first) return first;
  }
  const real = headers.get("x-real-ip")?.trim();
  return real ? real : null;
}

/**
 * Accept only plausible affiliate codes — short and URL-safe (LemonSqueezy codes
 * look like `ZylBs`). Rejects junk so the table and the eventual `aff_ref` stay
 * clean, and caps length to bound abuse. Returns the trimmed code or null.
 */
export function normalizeAffCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const code = raw.trim();
  if (code.length < 1 || code.length > 64) return null;
  return /^[A-Za-z0-9_-]+$/.test(code) ? code : null;
}

export async function handleAffiliate(req: Request, deps: AffiliateDeps): Promise<Response> {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const ip = clientIp(req.headers);
  // No resolvable IP → can't match. POST is a no-op-success (nothing to key on);
  // GET returns no match. Either way checkout/landing is never broken.
  if (!ip) {
    return req.method === "POST" ? json({ ok: true }) : json({ aff_ref: null });
  }
  const ipHash = await sha256Hex(deps.salt + ip);

  if (req.method === "POST") {
    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return json({ error: "bad_json" }, 400);
    }
    const aff = normalizeAffCode((body as { aff?: unknown })?.aff);
    if (!aff) return json({ error: "bad_aff" }, 400);

    // C-08 defense-in-depth: per-IP POST throttle. The unique(ip_hash) upsert
    // below is the structural amplifier fix; this just bounds write/RPC churn
    // from a hammering client. Over the cap → the SAME { ok: true }: recording
    // is best-effort, and neither the landing page nor checkout should ever
    // see (or be able to probe) the throttle. Limiter errors fail OPEN inside
    // the store impl.
    const allowed = await deps.store.rateLimitOk(
      `affiliate:${ipHash}`,
      AFFILIATE_RATE_LIMIT_PER_IP,
      AFFILIATE_RATE_LIMIT_WINDOW_SECONDS,
    );
    if (!allowed) return json({ ok: true });

    try {
      await deps.store.record(ipHash, aff);
    } catch (e) {
      console.error(JSON.stringify({ fn: "affiliate", op: "record", error: String(e) }));
      return json({ error: "record_failed" }, 500);
    }
    return json({ ok: true });
  }

  if (req.method === "GET") {
    const sinceISO = new Date(Date.now() - deps.windowHours * 3_600_000).toISOString();
    try {
      const code = await deps.store.latestCode(ipHash, sinceISO);
      return json({ aff_ref: code });
    } catch (e) {
      // Fail SOFT: a lookup failure must never block a purchase — the app just
      // opens an unattributed checkout.
      console.error(JSON.stringify({ fn: "affiliate", op: "lookup", error: String(e) }));
      return json({ aff_ref: null });
    }
  }

  return json({ error: "method_not_allowed" }, 405);
}
