import type { MetadataRoute } from "next";

const SITE_URL = "https://getzerro.app";

// Static build date. Avoid Date.now()/new Date() so the value is stable across
// builds and deterministic; bump this when the site content changes materially.
const LAST_MODIFIED = "2026-05-30";

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: SITE_URL,
      lastModified: LAST_MODIFIED,
      changeFrequency: "weekly",
      priority: 1.0,
    },
    {
      url: `${SITE_URL}/privacy`,
      lastModified: "2026-06-10",
      changeFrequency: "yearly",
      priority: 0.3,
    },
    {
      url: `${SITE_URL}/terms`,
      lastModified: "2026-06-10",
      changeFrequency: "yearly",
      priority: 0.3,
    },
  ];
}
