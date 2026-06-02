// Short-lived session tokens (billing-plan §6.3). The app exchanges its license
// key for one of these via the `session` function and sends IT (not the raw
// key) on every `generate` call, so the long-lived key isn't on every request.
//
// HS256, signed with the server-only SESSION_JWT_SECRET. Claims are kept small:
//   sub   — subscription id (the subscriber identity)
//   tier  — 'starter' | 'pro'
//   kind  — 'subscription' (Phase F adds 'trial'); lets `generate` branch
//   iat   — issued-at (epoch seconds)
//   exp   — expiry (epoch seconds); short lifetime bounds replay (§14.3)
//
// This is our OWN application JWT, verified IN CODE by the `entitlement` (and
// D2 `generate`) functions — NOT a Supabase gateway JWT. That is why those
// functions are deployed with verify_jwt = false: the Supabase gateway must not
// try to validate this token as its own.

import { base64UrlDecode, base64UrlEncode, hmacSha256, timingSafeEqual, toHex } from "./crypto.ts";
import type { Tier } from "./config.ts";

export interface SessionClaims {
  sub: string;
  tier: Tier;
  kind: "subscription" | "trial";
  iat: number;
  exp: number;
}

const HEADER = { alg: "HS256", typ: "JWT" } as const;

/** Sign a session token. `nowSeconds` is injectable for deterministic tests. */
export async function signSessionToken(
  claims: { sub: string; tier: Tier; kind?: "subscription" | "trial" },
  secret: string,
  ttlSeconds: number,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<{ token: string; exp: number }> {
  const exp = nowSeconds + ttlSeconds;
  const payload: SessionClaims = {
    sub: claims.sub,
    tier: claims.tier,
    kind: claims.kind ?? "subscription",
    iat: nowSeconds,
    exp,
  };
  const signingInput = `${base64UrlEncode(JSON.stringify(HEADER))}.${
    base64UrlEncode(JSON.stringify(payload))
  }`;
  const sig = toHex(await hmacSha256(secret, signingInput));
  // We base64url the hex signature string to keep the segment URL-safe.
  const token = `${signingInput}.${base64UrlEncode(sig)}`;
  return { token, exp };
}

/**
 * Verify a session token and return its claims, or null if invalid/expired.
 * Constant-time signature compare; explicit expiry check.
 */
export async function verifySessionToken(
  token: string,
  secret: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<SessionClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [headerB64, payloadB64, sigB64] = parts;

  const signingInput = `${headerB64}.${payloadB64}`;
  const expectedSig = toHex(await hmacSha256(secret, signingInput));
  let providedSig: string;
  try {
    providedSig = new TextDecoder().decode(base64UrlDecode(sigB64));
  } catch {
    return null;
  }
  if (!timingSafeEqual(expectedSig, providedSig)) return null;

  let claims: SessionClaims;
  try {
    claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(payloadB64)));
  } catch {
    return null;
  }

  if (typeof claims.exp !== "number" || claims.exp <= nowSeconds) return null;
  if (typeof claims.sub !== "string" || !claims.sub) return null;
  return claims;
}
