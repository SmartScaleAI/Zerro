// =============================================================================
// Aggressive trial-email normalization (shared).
// =============================================================================
// The canonical form behind the one-grant-per-email trial cap: it lowercases +
// trims, and for Gmail/Googlemail additionally strips dots and any `+tag` suffix
// in the local part (Gmail treats `j.o.e+x@gmail.com` and `joe@gmail.com` as the
// same inbox), defeating the classic dot/plus farming trick (§14.7). Non-Gmail
// providers keep their dots but still lose a `+tag`.
//
// Lives in _shared (not trial-start) because TWO functions must produce the
// IDENTICAL form or they'll disagree about which trial grant an email maps to:
//   • trial-start — the dedupe key for grant creation (re-exported as
//     `normalizeEmail`, so its callers/tests are unchanged).
//   • lemonsqueezy-webhook — at conversion, to find the trial grant a paying
//     subscriber came from (subscriptions.email_normalized is only lowercased +
//     trimmed, so we re-normalize it AGGRESSIVELY here to match the grant).
//
// Pure, deterministic, side-effect free. Returns null for input with no `@` or
// an empty local/domain.
// =============================================================================

const GMAIL_DOMAINS = new Set(["gmail.com", "googlemail.com"]);

export function normalizeTrialEmail(raw: string): string | null {
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
