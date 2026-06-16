// =============================================================================
// posthog.ts — server-side PostHog capture for the subscription lifecycle.
// =============================================================================
// Tier 3 analytics: `subscription_activated` / `subscription_lapsed` are
// captured HERE, from the webhook, so they're recorded even when the app is
// closed. To stitch onto the SAME PostHog person as the app funnel, the app
// plumbs its anonymous distinct_id through the LemonSqueezy checkout
// `custom_data.ph_distinct_id`; the handler reads it back here.
//
// FAIL-SOFT by contract: a missing POSTHOG_API_KEY no-ops (so dev + tests never
// transmit), and any transport error is swallowed and logged. Analytics must
// NEVER break the billing webhook — callers `await` this but it cannot throw.
//
// Privacy: callers pass metadata ONLY (tier, reason). NEVER an email, customer
// name, order id, or any PII.
// =============================================================================

/**
 * Capture one event to PostHog under `distinctId`. No-op when POSTHOG_API_KEY
 * is unset. Never throws.
 */
export async function capturePostHog(
  event: string,
  distinctId: string,
  properties: Record<string, unknown>,
): Promise<void> {
  const apiKey = Deno.env.get("POSTHOG_API_KEY");
  if (!apiKey) return; // dev / tests: no key → no transmission

  const host = (Deno.env.get("POSTHOG_HOST") || "https://us.i.posthog.com").replace(/\/+$/, "");
  try {
    const res = await fetch(`${host}/capture/`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ api_key: apiKey, event, distinct_id: distinctId, properties }),
    });
    if (!res.ok) {
      console.warn(JSON.stringify({
        fn: "lemonsqueezy-webhook",
        warn: "posthog_capture_failed",
        event,
        status: res.status,
      }));
    }
    // Drain the body so the connection is released cleanly.
    await res.body?.cancel();
  } catch (e) {
    console.warn(JSON.stringify({
      fn: "lemonsqueezy-webhook",
      warn: "posthog_capture_error",
      event,
      error: String(e),
    }));
  }
}
