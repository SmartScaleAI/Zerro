import type { NextConfig } from "next"
import withBundleAnalyzer from "@next/bundle-analyzer"

const nextConfig: NextConfig = {
  async redirects() {
    return [
      {
        // Keep the stable public download link working across releases by
        // redirecting it to GitHub's "latest release" asset. Temporary (307)
        // so the target is re-resolved on every request, never cached.
        //
        // NOTE: a real file at `public/Zerro.dmg` takes precedence over this
        // redirect on Vercel — remove it once the GitHub release is live.
        source: "/Zerro.dmg",
        destination:
          "https://github.com/SmartScaleAI/smartscale-zerro/releases/latest/download/Zerro.dmg",
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
