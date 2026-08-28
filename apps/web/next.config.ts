import type { NextConfig } from "next"
import withBundleAnalyzer from "@next/bundle-analyzer"
import { RELEASE_REDIRECTS } from "./lib/release-routes.ts"

// K-04: Content-Security-Policy, built from the site's ACTUAL resource usage.
// Shipped REPORT-ONLY first (see headers() below) so violations are logged to
// the console without breaking anything; flip to an enforcing
// `Content-Security-Policy` only once the key pages are confirmed clean.
//
// Each directive, and why its sources are here:
//  - default-src 'self'         fallback for anything not called out below
//                               (manifest-src, media-src, …) — all same-origin.
//  - script-src 'self'          Next.js chunks + posthog-js (bundled, served
//                               from /_next) + PostHog's /ingest/static/* assets
//                               (reverse-proxied, so same-origin).
//    'unsafe-inline'            RESIDUAL: Next.js App Router emits inline
//                               bootstrap/hydration <script> blocks
//                               (self.__next_f.push(...)) with no nonce. A
//                               nonce+'strict-dynamic' upgrade needs middleware
//                               and forces dynamic rendering — deferred. JSON-LD
//                               <script type="application/ld+json"> is a data
//                               block (not executed), so it doesn't need this.
//  - style-src 'self'           Tailwind's compiled stylesheet (/_next/static).
//    'unsafe-inline'            next/font injects an inline <style> for the
//                               @font-face, and we use inline style={{…}}
//                               attributes (governed by style-src-attr, which
//                               falls back to style-src). Style injection can't
//                               carry a nonce, so this is required.
//  - img-src 'self' data:       Local images via next/image (no remotePatterns
//                               configured → no remote hosts), favicons, SVG
//                               logos; data: covers next/image blur placeholders
//                               and inline SVG data URIs.
//  - font-src 'self'            Inter is self-hosted by next/font (no Google
//                               Fonts network fetch).
//  - connect-src 'self'         PostHog ingest is reverse-proxied through
//                               /ingest (same-origin); the browser talks to no
//                               other origin.
//  - worker-src 'self' blob:    posthog-js spins up a blob: web worker to gzip
//                               event payloads.
//  - frame-ancestors 'none'     modern equivalent of X-Frame-Options: DENY —
//                               the marketing site is never meant to be embedded.
//  - frame-src 'none'           the site embeds no iframes.
//  - object-src 'none'          no <object>/<embed>/plugins.
//  - base-uri 'self'            block <base> tag injection from redirecting
//                               relative URLs.
//  - form-action 'self'         no <form> submits cross-origin.
const cspDirectives = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self'",
  "worker-src 'self' blob:",
  "frame-ancestors 'none'",
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
]
const contentSecurityPolicy = cspDirectives.join("; ")

const nextConfig: NextConfig = {
  // Reverse-proxy PostHog through our own domain so ad-blockers don't drop
  // events. The /static rule (assets) must come before the catch-all, which
  // covers /flags, /e/, /i/v0/e/, etc. SDK points api_host at "/ingest".
  async rewrites() {
    return [
      {
        source: "/ingest/static/:path*",
        destination: "https://us-assets.i.posthog.com/static/:path*",
      },
      {
        source: "/ingest/:path*",
        destination: "https://us.i.posthog.com/:path*",
      },
    ]
  },
  // PostHog needs trailing-slash-sensitive routes to pass through untouched.
  skipTrailingSlashRedirect: true,
  // K-01 / K-04: don't leak full URLs (which may carry secret query params like
  // the LemonSqueezy `license_key`) to cross-origin destinations via `Referer`.
  async headers() {
    return [
      {
        // Site-wide default: send only the origin on cross-origin requests,
        // and nothing at all on HTTPS→HTTP downgrades.
        source: "/:path*",
        headers: [
          {
            key: "Referrer-Policy",
            value: "strict-origin-when-cross-origin",
          },
          // K-04: force HTTPS for two years, including subdomains. Vercel serves
          // HTTPS, so this is safe. `preload` is intentionally omitted — adding
          // it commits the domain to the browser HSTS preload list (slow/hard to
          // reverse). Optional follow-up if the owner wants that commitment.
          {
            key: "Strict-Transport-Security",
            value: "max-age=63072000; includeSubDomains",
          },
          // K-04: never let the browser MIME-sniff a response into a different
          // content type (defends against content-type confusion attacks).
          { key: "X-Content-Type-Options", value: "nosniff" },
          // K-04: the marketing site is never meant to be framed. Legacy header
          // for old browsers; `frame-ancestors 'none'` in the CSP is the modern
          // equivalent.
          { key: "X-Frame-Options", value: "DENY" },
          // K-04: CSP shipped REPORT-ONLY first — violations are reported to the
          // console but nothing is blocked. Watch home, pricing, and
          // checkout-complete for violations, then switch this key to
          // `Content-Security-Policy` (enforcing) once clean. See cspDirectives.
          {
            key: "Content-Security-Policy-Report-Only",
            value: contentSecurityPolicy,
          },
        ],
      },
      {
        // The checkout hand-off briefly holds the `license_key` in the URL
        // before the page scrubs it — send NO referrer from here so the key
        // can never ride the `Referer` on any outbound request (analytics
        // beacon, image, font, …). More specific, so it wins for this route.
        source: "/checkout-complete",
        headers: [{ key: "Referrer-Policy", value: "no-referrer" }],
      },
    ]
  },
  // Stable public release URLs. getzerro.app/appcast.xml (the Sparkle feed URL
  // baked into installed apps) and getzerro.app/Zerro.dmg (the latest-download
  // link) redirect to the matching asset on the latest GitHub Release of the
  // app repository, which is the canonical public source for official builds.
  // The contract — sources, destinations, and the temporary-redirect choice —
  // lives in lib/release-routes.ts; keep this list wired to it so the CI
  // routing guard and lib/release-routes.test.ts keep verifying the real
  // configuration. Never commit apps/web/public/appcast.xml or
  // apps/web/public/Zerro.dmg.
  async redirects() {
    return [...RELEASE_REDIRECTS]
  },
}

// Enable with: ANALYZE=true npm run build
// Opens an interactive treemap of the client bundle (useful for tracking
// motion/react weight and spotting accidental client-side imports).
const bundleAnalyzer = withBundleAnalyzer({
  enabled: process.env.ANALYZE === "true",
})

export default bundleAnalyzer(nextConfig)
