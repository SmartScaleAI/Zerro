"use client";

import { Suspense, useEffect } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import posthog from "posthog-js";
import { PostHogProvider as PHProvider, usePostHog } from "posthog-js/react";
import { sanitizePostHogEvent } from "@/lib/analytics-sanitize";

// PostHog for the marketing site. Deliberately the opposite posture of the
// macOS app: autocapture ON (a landing page is the right place for it), but
// cookieless (memory persistence, no consent banner), session replay OFF, and
// only identified people get profiles.
export function PostHogProvider({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    const key = process.env.NEXT_PUBLIC_POSTHOG_KEY;
    if (!key) return;

    // Production domain only — never localhost or *.vercel.app previews
    // (preview deploys run production builds, so NODE_ENV isn't enough).
    const allowedHosts = ["getzerro.app", "www.getzerro.app"];
    if (!allowedHosts.includes(window.location.hostname)) return;

    posthog.init(key, {
      // Reverse-proxied through our own domain (see next.config rewrites) so
      // ad-blockers don't drop events. ui_host keeps "open in PostHog" links
      // pointing at the real app.
      api_host: "/ingest",
      ui_host: "https://us.posthog.com",
      person_profiles: "identified_only",
      persistence: "memory", // cookieless — no consent banner needed
      autocapture: true,
      capture_pageview: false, // captured manually on route change below
      capture_pageleave: true,
      disable_session_recording: true,
      enable_heatmaps: true,
      // K-01: scrub secret query params (e.g. the LemonSqueezy `license_key`
      // landing on /checkout-complete) out of `$current_url`/`$referrer` on
      // EVERY event before it leaves the browser — the last line of defense in
      // case the URL hasn't been cleaned from the address bar yet.
      before_send: sanitizePostHogEvent,
    });
  }, []);

  return (
    <PHProvider client={posthog}>
      {children}
      <Suspense fallback={null}>
        <PostHogPageView />
      </Suspense>
    </PHProvider>
  );
}

// Captures `$pageview` on every App Router navigation. `useSearchParams`
// suspends during prerender, which is why the render site wraps this in
// <Suspense>.
function PostHogPageView() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const posthog = usePostHog();

  useEffect(() => {
    if (!pathname || !posthog) return;
    let url = window.origin + pathname;
    const search = searchParams.toString();
    if (search) url += "?" + search;
    posthog.capture("$pageview", { $current_url: url });
  }, [pathname, searchParams, posthog]);

  return null;
}
