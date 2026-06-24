import type { CaptureResult } from "posthog-js";

// K-01: keep secret query params out of third-party analytics. The LemonSqueezy
// hand-off lands on /checkout-complete with `license_key`/`order_id` in the
// query string; PostHog autocapture and the manual `$pageview` both copy the
// full URL into `$current_url`, which would ship those secrets to PostHog. This
// module is the chokepoint that scrubs them off every outgoing event.

/**
 * Query-param *names* (matched case-insensitively) that must never reach
 * analytics, browser history, or the `Referer`. `license_key`/`order_id` are
 * the LemonSqueezy values; the rest are common secret-bearing names guarded
 * pre-emptively. Add new sensitive params here — `redactSensitiveUrl` and the
 * PostHog hook both read from this one list.
 */
export const SENSITIVE_QUERY_PARAMS: readonly string[] = [
  "license_key",
  "order_id",
  "license",
  "token",
  "access_token",
  "refresh_token",
  "api_key",
  "apikey",
  "secret",
  "password",
  "signature",
];

const SENSITIVE_SET = new Set(SENSITIVE_QUERY_PARAMS.map((p) => p.toLowerCase()));

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Like `redactSensitiveUrl`, but for free-form strings that *embed* URLs/query
 * fragments rather than being a single URL — most importantly PostHog's
 * `$elements_chain`, the serialized autocapture DOM chain that carries each
 * element's `attr__href`. Replaces only the secret *value* (`?license_key=ABC`
 * → `?license_key=[redacted]`), leaving the surrounding structure intact.
 */
export function redactSensitiveText(value: string): string {
  if (!value) return value;
  const lower = value.toLowerCase();
  if (!SENSITIVE_QUERY_PARAMS.some((p) => lower.includes(p))) return value;
  let result = value;
  for (const param of SENSITIVE_QUERY_PARAMS) {
    // `?param=…` / `&param=…`, value running up to the next delimiter so we stop
    // at the end of the query param (and never spill past a quoted href).
    const re = new RegExp(
      `([?&]${escapeRegExp(param)}=)[^&#"'\\s]*`,
      "gi",
    );
    result = result.replace(re, "$1[redacted]");
  }
  return result;
}

/**
 * Returns `value` with every sensitive query parameter removed. Handles both
 * absolute URLs (`https://host/path?license_key=…`) and relative ones
 * (`/path?license_key=…`), preserving the shape it was handed. Strings that
 * aren't URLs — or that carry nothing sensitive — are returned byte-for-byte
 * unchanged, so normal pages are never altered.
 */
export function redactSensitiveUrl(value: string): string {
  if (!value) return value;

  // Cheap guard: skip the URL parse unless a sensitive param name could even be
  // present. Substring match here is only a fast filter — exact param matching
  // happens against SENSITIVE_SET below, so a coincidental substring is safe.
  const lower = value.toLowerCase();
  if (!SENSITIVE_QUERY_PARAMS.some((p) => lower.includes(p))) return value;

  const isAbsolute = /^[a-z][a-z0-9+.-]*:\/\//i.test(value);
  try {
    // A throwaway base lets us parse relative URLs too; it's stripped back off
    // below so relative inputs stay relative.
    const url = new URL(value, "http://redacted.invalid");
    let changed = false;
    for (const key of [...url.searchParams.keys()]) {
      if (SENSITIVE_SET.has(key.toLowerCase())) {
        url.searchParams.delete(key);
        changed = true;
      }
    }
    if (!changed) return value;
    return isAbsolute ? url.toString() : url.pathname + url.search + url.hash;
  } catch {
    // Not a parseable URL — leave it untouched rather than risk corrupting it.
    return value;
  }
}

/**
 * Event property keys whose values are URLs (or URL-like) and can therefore
 * embed a sensitive query string. PostHog sets these on `$pageview`,
 * autocapture, `$pageleave`, etc.
 */
const URL_BEARING_PROPERTIES: readonly string[] = [
  "$current_url",
  "$pathname",
  "$referrer",
  "$initial_current_url",
  "$initial_pathname",
  "$initial_referrer",
];

function scrubProperties(props: Record<string, unknown> | undefined): void {
  if (!props) return;
  for (const key of URL_BEARING_PROPERTIES) {
    const v = props[key];
    if (typeof v === "string") props[key] = redactSensitiveUrl(v);
  }
}

/**
 * Scrub autocapture DOM data. `$elements_chain` is a serialized string;
 * `$elements` is an array of element descriptors whose string fields (notably
 * `href` / `attr__href`) can carry a secret query string. Both can ride a
 * `$click` / `$autocapture` event if a captured link's href holds the key.
 */
function scrubAutocaptureElements(
  props: Record<string, unknown> | undefined,
): void {
  if (!props) return;
  if (typeof props.$elements_chain === "string") {
    props.$elements_chain = redactSensitiveText(props.$elements_chain);
  }
  const elements = props.$elements;
  if (Array.isArray(elements)) {
    for (const el of elements) {
      if (!el || typeof el !== "object") continue;
      const obj = el as Record<string, unknown>;
      for (const k of Object.keys(obj)) {
        if (typeof obj[k] === "string") {
          obj[k] = redactSensitiveText(obj[k] as string);
        }
      }
    }
  }
}

/**
 * PostHog `before_send` hook. Strips sensitive query params out of every
 * URL-bearing property on EVERY event before it leaves the browser, so a stray
 * autocapture / `$pageview` on /checkout-complete can never carry the
 * LemonSqueezy `license_key` (or `order_id`) to PostHog — even if the URL hasn't
 * been scrubbed from the address bar yet. Mutates and returns the event; never
 * drops it. A `null` event (PostHog's own drop signal) passes straight through.
 */
export function sanitizePostHogEvent(
  event: CaptureResult | null,
): CaptureResult | null {
  if (!event) return event;
  scrubProperties(event.properties);
  scrubProperties(event.$set);
  scrubProperties(event.$set_once);
  scrubAutocaptureElements(event.properties);
  return event;
}
