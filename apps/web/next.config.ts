import type { NextConfig } from "next"
import withBundleAnalyzer from "@next/bundle-analyzer"

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
  async redirects() {
    return [
      {
        // Keep the stable public download link working across releases by
        // redirecting it to the public Supabase Storage asset. Temporary (307)
        // so the target is re-resolved on every request, never cached.
        //
        // The repo is private, so GitHub release assets 404 for anyone not
        // signed in. The .dmg is hosted in the public `downloads` bucket
        // instead; CI overwrites Zerro.dmg there on each release.
        //
        // NOTE: a real file at `public/Zerro.dmg` takes precedence over this
        // redirect on Vercel — never commit the dmg into apps/web/public.
        source: "/Zerro.dmg",
        destination:
          "https://wjxqmurgwyxwkezncxke.supabase.co/storage/v1/object/public/downloads/Zerro.dmg",
        permanent: false,
      },
    ]
  },
}

// Enable with: ANALYZE=true npm run build
// Opens an interactive treemap of the client bundle (useful for tracking
// motion/react weight and spotting accidental client-side imports).
const bundleAnalyzer = withBundleAnalyzer({
  enabled: process.env.ANALYZE === "true",
})

export default bundleAnalyzer(nextConfig)
