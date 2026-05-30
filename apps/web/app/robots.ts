import type { MetadataRoute } from "next";

const SITE_URL = "https://getzerro.app";

/**
 * Crawl directives.
 *
 * Zerro's story is BYOK + local-first + privacy-respecting — there's nothing
 * sensitive to hide from crawlers, and being cited in AI chat answers is a
 * wanted distribution channel. So every major AI crawler is explicitly named
 * and allowed; none are blocked. `/auth` is disallowed since it's a sign-in
 * page with no content worth indexing.
 */
export default function robots(): MetadataRoute.Robots {
  const aiCrawlers = [
    "GPTBot", // OpenAI training
    "ChatGPT-User", // ChatGPT browsing
    "OAI-SearchBot", // ChatGPT search
    "ClaudeBot", // Anthropic training
    "Claude-Web", // Anthropic
    "anthropic-ai", // Anthropic
    "PerplexityBot", // Perplexity
    "Google-Extended", // Gemini training
    "cohere-ai", // Cohere
  ];

  return {
    rules: [
      {
        userAgent: "*",
        allow: "/",
        disallow: "/auth",
      },
      // Explicitly allow each AI crawler. Naming them is a clearer signal than
      // relying on the wildcard rule, and documents intent for anyone reading
      // robots.txt.
      ...aiCrawlers.map((userAgent) => ({
        userAgent,
        allow: "/",
      })),
    ],
    sitemap: `${SITE_URL}/sitemap.xml`,
    host: SITE_URL,
  };
}
