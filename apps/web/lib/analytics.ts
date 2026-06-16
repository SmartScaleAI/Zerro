import posthog from "posthog-js";

/**
 * Thin wrapper around `posthog.capture` for the site's manual events.
 *
 * Guards on `window` so it's a no-op during SSR/prerender. PostHog is
 * initialized in `app/providers.tsx`; if the key is missing, capture is a
 * harmless no-op.
 */
export function track(event: string, props?: Record<string, unknown>) {
  if (typeof window !== "undefined") posthog.capture(event, props);
}
