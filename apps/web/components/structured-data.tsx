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
          "Zerro is a native macOS menu-bar utility that turns a screen recording and spoken instructions into exactly what you need — an agent prompt, a message, a snippet, a document, or a clear answer to your question.",
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
          "Give your agent eyes and ears. Record your screen, dictate what you want, and get exactly what you need — a prompt, a message, a snippet, a document, or a clear answer.",
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
        applicationCategory: "ProductivityApplication",
        operatingSystem: "macOS",
        url: SITE_URL,
        description:
          "Zerro is a native macOS menu-bar app. Record a region of your screen, dictate what you want, and Zerro returns exactly what you need — an agent prompt, a ready-to-send message, an exact code snippet, a written-up document, or a clear answer to your question. Audio isolation and frame downsampling run locally; let Zerro handle the AI, or bring your own OpenAI, Gemini & Anthropic keys.",
        featureList: [
          "Returns the right output for the task — agent prompt, message, snippet, document, or a plain-language answer",
          "Native Swift & SwiftUI menu-bar app built on ScreenCaptureKit",
          "Local-first processing — audio isolation and frame downsampling run on your machine",
          "Managed plan handles the AI for you, or bring your own OpenAI, Gemini & Anthropic keys stored in macOS Keychain",
          "30 free credits to start — no card, no key, no time limit",
          "3-minute recording cap keeps each request fast and predictable",
          "Signed & notarized .dmg distribution",
          "Sparkle auto-updates",
        ],
        offers: [
          {
            "@type": "Offer",
            name: "Managed",
            price: "15",
            priceCurrency: "USD",
            description:
              "Managed plan — we handle the AI, no keys or setup. $15/mo or $12/mo billed yearly ($144/yr). 300 credits per month across 6 models (Claude, GPT & Gemini); credit cost per generation varies by model, with top-ups available.",
            availability: "https://schema.org/InStock",
          },
          {
            "@type": "Offer",
            name: "BYOK",
            price: "69",
            priceCurrency: "USD",
            description:
              "Pay once. Bring your own OpenAI, Gemini & Anthropic keys; recordings go straight to your provider and never pass through Zerro's servers. Includes 1 year of updates.",
            availability: "https://schema.org/InStock",
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
