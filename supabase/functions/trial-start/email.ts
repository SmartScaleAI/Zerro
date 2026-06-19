// =============================================================================
// Email normalization, disposable-domain rejection, and code generation (F).
// =============================================================================
// Pure helpers (no DB, no network) so they're trivially unit-testable. The
// normalization is the dedupe key behind the one-grant-per-email cap: the SAME
// canonical form must be produced at request-code time and at verify time, or a
// user could land two grants. Keep it deterministic and side-effect free.
// =============================================================================

// The trial-cap email normalizer now lives in _shared so the
// lemonsqueezy-webhook can produce the IDENTICAL canonical form when it links a
// converting subscriber to their trial grant (see _shared/email-normalize.ts).
// Re-exported under the historical name so this module's callers + tests are
// unchanged.
export { normalizeTrialEmail as normalizeEmail } from "../_shared/email-normalize.ts";

/**
 * Disposable / throwaway email domains we refuse to grant trial credits to.
 * A reasonable static starter list (NOT exhaustive — kept as editable data so
 * it's a one-line add, not a logic change). Phase G could swap this for a
 * maintained external list. Matching is on the (already lowercased) domain.
 */
export const DISPOSABLE_DOMAINS = new Set<string>([
  "mailinator.com",
  "guerrillamail.com",
  "guerrillamail.info",
  "sharklasers.com",
  "grr.la",
  "temp-mail.org",
  "tempmail.com",
  "tempmail.dev",
  "10minutemail.com",
  "10minutemail.net",
  "throwawaymail.com",
  "yopmail.com",
  "getnada.com",
  "trashmail.com",
  "dispostable.com",
  "maildrop.cc",
  "fakeinbox.com",
  "mintemail.com",
  "mohmal.com",
  "spamgourmet.com",
  "tutanota-disposable.com",
  "emailondeck.com",
  "tempr.email",
  "moakt.com",
  "mailnesia.com",
]);

/** True if `normalizedEmail`'s domain is a known disposable provider. */
export function isDisposableEmail(normalizedEmail: string): boolean {
  const at = normalizedEmail.lastIndexOf("@");
  if (at < 0) return false;
  return DISPOSABLE_DOMAINS.has(normalizedEmail.slice(at + 1));
}

/**
 * A fresh cryptographically-random 6-digit code (000000–999999, zero-padded).
 * Uses Web Crypto getRandomValues with rejection sampling so every code is
 * equiprobable (no modulo bias). Returned as a string so leading zeros survive.
 */
export function generateCode(): string {
  // Rejection-sample a u32 below the largest multiple of 1_000_000 to avoid the
  // modulo bias a raw `% 1_000_000` would introduce.
  const limit = Math.floor(0xffffffff / 1_000_000) * 1_000_000;
  const buf = new Uint32Array(1);
  let n: number;
  do {
    crypto.getRandomValues(buf);
    n = buf[0];
  } while (n >= limit);
  return String(n % 1_000_000).padStart(6, "0");
}
