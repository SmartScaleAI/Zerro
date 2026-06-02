// Low-level crypto primitives built on Web Crypto (available in Deno). No
// external dependency — the security-critical paths (HMAC verify, JWT) are
// hand-rolled and auditable rather than pulled from a third-party lib.

const encoder = new TextEncoder();

// Web Crypto wants a BufferSource. A Uint8Array<ArrayBufferLike> trips strict
// type-checking (it could in theory be SharedArrayBuffer-backed), so narrow it
// for the subtle calls. Runtime is unaffected.
function buf(b: Uint8Array): BufferSource {
  return b as unknown as BufferSource;
}

/** Lowercase hex of a byte array. */
export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

/** base64url encode (no padding) — for JWT segments. */
export function base64UrlEncode(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** base64url decode → bytes. */
export function base64UrlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    Math.ceil(input.length / 4) * 4,
    "=",
  );
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** SHA-256 hex digest of a UTF-8 string. Used to hash the license key. */
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", buf(encoder.encode(input)));
  return toHex(new Uint8Array(digest));
}

/** Raw HMAC-SHA256 bytes of `data` under `secret`. */
export async function hmacSha256(
  secret: string,
  data: Uint8Array | string,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    buf(encoder.encode(secret)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = typeof data === "string" ? encoder.encode(data) : data;
  const sig = await crypto.subtle.sign("HMAC", key, buf(bytes));
  return new Uint8Array(sig);
}

/**
 * Constant-time string compare. Always inspects every character of `a` so the
 * time taken does not leak how many leading characters matched. A length
 * mismatch returns false but still runs the loop (no early-out timing channel).
 */
export function timingSafeEqual(a: string, b: string): boolean {
  const len = a.length;
  let diff = a.length ^ b.length;
  for (let i = 0; i < len; i++) {
    // (b.charCodeAt(i) || 0) keeps the loop bound to `a` even if b is shorter.
    diff |= a.charCodeAt(i) ^ (b.charCodeAt(i) || 0);
  }
  return diff === 0;
}
