// =============================================================================
// Email normalization, disposable-domain rejection, and code generation (F).
// =============================================================================
// Pure helpers (no DB, no network) so they're trivially unit-testable. The
// normalization is the dedupe key behind the one-grant-per-email cap: the SAME
// canonical form must be produced at request-code time and at verify time, or a
// user could land two grants. Keep it deterministic and side-effect free.
// =============================================================================

/**
 * Canonicalize an email for the trial cap. ALWAYS lowercases + trims (the
 * minimum). For Gmail/Googlemail addresses it additionally strips the dots and
 * any `+tag` suffix in the local part — Gmail treats `j.o.e+x@gmail.com` and
 * `joe@gmail.com` as the same inbox, so collapsing them tightens the dedupe and
 * defeats the classic dot/plus farming trick (§14.7). Non-Gmail providers keep
 * their full local part (we don't assume their plus/dot semantics).
 *
 * Returns null for input with no `@` or an empty local/domain (caller → 400).
 */
export function normalizeEmail(raw: string): string | null {
  const trimmed = raw.trim().toLowerCase();
  const at = trimmed.lastIndexOf("@");
  if (at <= 0 || at === trimmed.length - 1) return null;

  let local = trimmed.slice(0, at);
  const domain = trimmed.slice(at + 1);
  if (!local || !domain || !domain.includes(".")) return null;

  if (GMAIL_DOMAINS.has(domain)) {
    // Drop a +tag suffix, then remove dots from the local part.
    const plus = local.indexOf("+");
    if (plus >= 0) local = local.slice(0, plus);
    local = local.replaceAll(".", "");
    if (!local) return null;
    // Canonicalize googlemail.com → gmail.com (same inbox).
    return `${local}@gmail.com`;
  }

  // Non-Gmail: still drop a +tag suffix (widely supported, low false-positive)
  // but preserve dots (provider-specific semantics).
  const plus = local.indexOf("+");
  if (plus >= 0) local = local.slice(0, plus);
  if (!local) return null;
  return `${local}@${domain}`;
}

const GMAIL_DOMAINS = new Set(["gmail.com", "googlemail.com"]);

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
