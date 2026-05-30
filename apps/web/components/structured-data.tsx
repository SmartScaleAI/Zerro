/**
 * JSON-LD structured data, emitted as Server Components.
 *
 * Each component renders a <script type="application/ld+json"> block so the
 * schema is present in the initial server-rendered HTML (no client hydration).
 * Facts here must stay in sync with the on-page copy — only verifiable claims.
 */

const SITE_URL = "https://getzerro.app";

function JsonLd({ data }: { data: Record<string, unknown> }) {
  return (
    <script
      type="application/ld+json"
      // JSON.stringify output is safe to inline; no user input flows in here.
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }}
    />
  );
}

/** Site-wide publisher identity. Rendered once in the root layout. */
export function OrganizationJsonLd() {
  return (
    <JsonLd
      data={{
        "@context": "https://schema.org",
        "@type": "Organization",
        name: "Zerro",
        url: SITE_URL,
        logo: `${SITE_URL}/logo/zerro-mark.svg`,
        email: "support@getzerro.app",
        description:
          "Zerro is a native macOS menu-bar utility that turns a screen recording and spoken instructions into a structured prompt for AI coding agents.",
      }}
    />
  );
}

/** Site identity for search engines. Rendered once in the root layout. */
export function WebSiteJsonLd() {
  return (
    <JsonLd
      data={{
        "@context": "https://schema.org",
        "@type": "WebSite",
        name: "Zerro",
        url: SITE_URL,
        description:
          "Give your agent eyes and ears. Record your screen, dictate what you want, and get a structured prompt for your AI coding agent.",
        publisher: { "@type": "Organization", name: "Zerro", url: SITE_URL },
      }}
    />
  );
}

/** The product itself. Rendered once on the homepage. */
export function SoftwareApplicationJsonLd() {
  return (
    <JsonLd
      data={{
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        name: "Zerro",
        applicationCategory: "DeveloperApplication",
        operatingSystem: "macOS",
        url: SITE_URL,
        description:
          "Zerro is a native macOS menu-bar app. Record a region of your screen, dictate what you want, and Zerro returns a structured Markdown prompt ready to paste into Cursor, Windsurf, v0, or any AI coding agent. Audio isolation and frame downsampling run locally; bring your own OpenAI and Gemini keys.",
        featureList: [
          "Native Swift & SwiftUI menu-bar app built on ScreenCaptureKit",
          "Local-first processing — audio isolation and frame downsampling run on your machine",
          "Bring your own OpenAI and Gemini keys, stored in macOS Keychain",
          "3-minute recording cap keeps each request fast and predictable",
          "Signed & notarized .dmg distribution",
          "Sparkle auto-updates",
        ],
        offers: [
          {
            "@type": "Offer",
            name: "BYOK",
            price: "39",
            priceCurrency: "USD",
            description:
              "Pay once. Bring your own OpenAI and Gemini keys. Includes all features and future updates.",
            availability: "https://schema.org/InStock",
          },
          {
            "@type": "Offer",
            name: "Managed",
            price: "12",
            priceCurrency: "USD",
            description:
              "Managed token usage — no API keys required. Monthly recording credits included.",
            availability: "https://schema.org/PreOrder",
          },
        ],
      }}
    />
  );
}

export type FaqEntry = { question: string; answer: string };

/** FAQ rich result. Pass the same entries shown in the on-page FAQ. */
export function FaqJsonLd({ entries }: { entries: FaqEntry[] }) {
  return (
    <JsonLd
      data={{
        "@context": "https://schema.org",
        "@type": "FAQPage",
        mainEntity: entries.map((e) => ({
          "@type": "Question",
          name: e.question,
          acceptedAnswer: { "@type": "Answer", text: e.answer },
        })),
      }}
    />
  );
}
