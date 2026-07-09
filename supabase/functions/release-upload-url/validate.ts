// Pure, request-free helpers for release-upload-url, exported for unit tests
// (repo convention: the security-critical logic tests without a request).

/// The ONLY object names the function will mint an upload URL for: the mutable
/// "latest" object (Zerro.dmg) or a versioned release object (Zerro-<build>.dmg,
/// digits only — release-app.yml builds DMG_NAME as "$APP_NAME-$BUILD.dmg").
/// Anchored with no slash/dot classes beyond the literal ".dmg", so traversal
/// ("../…"), nested paths ("Zerro.dmg/x"), and any other object are rejected.
/// This allow-list is what bounds a leaked RELEASE_UPLOAD_SECRET to "upload a
/// Zerro DMG" — nothing else in the bucket, nothing outside it.
export const ALLOWED_DMG_PATTERN = /^Zerro(-[0-9]+)?\.dmg$/;

/** True only for an allow-listed DMG object name (see ALLOWED_DMG_PATTERN). */
export function isAllowedDmgPath(path: unknown): path is string {
  return typeof path === "string" && ALLOWED_DMG_PATTERN.test(path);
}

/**
 * Constant-time string compare so a wrong x-release-secret can't be timed out
 * byte-by-byte. Always XORs every byte of the shorter input; a length mismatch
 * fails after the same per-byte work rather than short-circuiting.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  const ab = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  let diff = ab.length === bb.length ? 0 : 1;
  const n = Math.min(ab.length, bb.length);
  for (let i = 0; i < n; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}
