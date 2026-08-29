/**
 * JSON-LD structured data, emitted as Server Components.
 *
 * Each component renders a <script type="application/ld+json"> block so the
 * schema is present in the initial server-rendered HTML (no client hydration).
 * Facts here must stay in sync with the on-page copy — only verifiable claims,
 * and every number comes from lib/product-facts so it can't drift from the
 * pricing section or FAQ.
 */

import {
  MODEL_VENDORS,
  SELECTABLE_MODEL_COUNT,
} from "@/lib/model-registry";
import {
  LICENSED_RELEASES,
  LICENSE_MAC_COUNT,
  LICENSE_PRICE,
  LICENSE_PRICE_USD,
  NEXT_MAJOR,
  SOURCE_LICENSE,
  TRIAL_DAYS,
} from "@/lib/product-facts";

const SITE_URL = "https://getzerro.app";

function JsonLd({ data }: { data: Record<string, unknown> }) {
  return (
    <script
      type="application/ld+json"
      // No user input flows in here; the `<` escape is the defensive
      // sanitization the Next.js JSON-LD guide recommends regardless.
      dangerouslySetInnerHTML={{
        __html: JSON.stringify(data).replace(/</g, "\\u003c"),
      }}
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
          "Zerro is a native macOS menu-bar utility that turns a screen recording and spoken instructions into exactly what you need: an agent prompt, a message, a snippet, a document, or a clear answer to your question.",
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
          "Talk to your screen. Zerro does the work. A lightweight macOS menu bar app. Record your screen, explain what you want, and get it done faster: a prompt, a message, a snippet, a document, or a clear answer.",
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
          "Zerro is an open-source, bring-your-own-key macOS menu-bar app. Record a region of your screen, dictate what you want, and Zerro returns exactly what you need: an agent prompt, a ready-to-send message, an exact code snippet, a written-up document, or a clear answer to your question. Your recording is prepared on your Mac, and the frames and transcript go straight to your OpenAI, Gemini, or Anthropic key.",
        featureList: [
          "Returns the right output for the task: agent prompt, message, snippet, document, or a plain-language answer",
          "Native Swift & SwiftUI menu-bar app built on ScreenCaptureKit",
          "Local-first processing: your recording is prepared, transcribed, and redacted on your Mac; Zerro never receives recordings, audio, transcripts, prompts, or results",
          "Bring your own OpenAI, Gemini & Anthropic keys, stored in macOS Keychain; prepared frames and transcript go straight to your provider, never through Zerro's servers",
          `${SELECTABLE_MODEL_COUNT} models to choose from: ${MODEL_VENDORS}`,
          `${TRIAL_DAYS}-day free trial in official builds: no card, no account`,
          `Open source under ${SOURCE_LICENSE}; build it from the source with no license required`,
          "3-minute recording cap keeps each request fast and predictable",
          "Signed & notarized .dmg distribution",
          "Sparkle auto-updates",
        ],
        offers: [
          {
            "@type": "Offer",
            name: "Zerro License",
            price: String(LICENSE_PRICE_USD),
            priceCurrency: "USD",
            description: `One-time ${LICENSE_PRICE} license for the official signed and notarized Zerro build. Activates on up to ${LICENSE_MAC_COUNT} Macs at once and includes all Zerro ${LICENSED_RELEASES} updates; a future ${NEXT_MAJOR} major release may be sold separately. Bring your own OpenAI, Gemini & Anthropic keys and pay your provider directly for usage. ${TRIAL_DAYS}-day free trial, no card required. No subscription, no account.`,
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
