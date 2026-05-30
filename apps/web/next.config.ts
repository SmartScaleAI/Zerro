import type { NextConfig } from "next"
import withBundleAnalyzer from "@next/bundle-analyzer"

const nextConfig: NextConfig = {}

// Enable with: ANALYZE=true npm run build
// Opens an interactive treemap of the client bundle (useful for tracking
// motion/react weight and spotting accidental client-side imports).
const bundleAnalyzer = withBundleAnalyzer({
  enabled: process.env.ANALYZE === "true",
})

export default bundleAnalyzer(nextConfig)
