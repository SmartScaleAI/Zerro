// =============================================================================
// trial-start rate-limiter error posture (C-07).
// =============================================================================
// check_rate_limit is infrastructure: it can error independently of the request
// being metered. The old blanket fail-OPEN silently disabled EVERY abuse bound
// whenever the limiter broke; the posture is now the CALLER's choice per key
// (see handler.ts for which keys fail open vs closed and why). This module is
// dependency-free so the handler tests exercise the SAME fallback + alert log
// as the production store.

/** Which limiter key errored — passed by the call site (the impl never parses
 * the key string). */
export type RateLimitKeyKind = "ip" | "email" | "send";

/** What a limiter ERROR means for this call: "allow" = fail open,
 * "deny" = fail closed. */
export type RateLimitOnError = "allow" | "deny";

/**
 * The single place a limiter error becomes a verdict: emit the distinct,
 * stable alert line and apply the caller's posture. An ops log-alert keys on
 * event:"rate_limiter_error" — keep the field names stable (the handler tests
 * pin them).
 */
export function rateLimiterErrorVerdict(
  keyKind: RateLimitKeyKind,
  onError: RateLimitOnError,
  message: string,
): boolean {
  console.error(JSON.stringify({
    fn: "trial-start",
    event: "rate_limiter_error",
    key_kind: keyKind,
    failed_closed: onError === "deny",
    error: message,
  }));
  return onError === "allow";
}
