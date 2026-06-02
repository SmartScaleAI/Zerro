// LemonSqueezy webhook signature verification (billing-plan §14.3).
//
// LemonSqueezy signs each webhook by computing HMAC-SHA256 over the RAW request
// body using the webhook signing secret, and sends the lowercase hex digest in
// the `X-Signature` header. We MUST compute the HMAC over the exact raw bytes
// received — before any JSON parse/re-serialize — or the digest won't match.
// Compare in constant time. Reject (401) on mismatch before doing any work.

import { hmacSha256, timingSafeEqual, toHex } from "./crypto.ts";

/**
 * Verify a LemonSqueezy webhook signature.
 * @param rawBody   the exact request body bytes (read via req.text()/arrayBuffer())
 * @param signature the `X-Signature` header value (hex)
 * @param secret    the webhook signing secret (LEMONSQUEEZY_WEBHOOK_SECRET)
 */
export async function verifyLemonSqueezySignature(
  rawBody: string,
  signature: string | null,
  secret: string,
): Promise<boolean> {
  if (!signature) return false;
  const expected = toHex(await hmacSha256(secret, rawBody));
  return timingSafeEqual(expected, signature.trim().toLowerCase());
}
