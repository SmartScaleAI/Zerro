import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { test } from "node:test";
import {
  LICENSED_RELEASES,
  LICENSE_MAC_COUNT,
  LICENSE_PRICE,
  LICENSE_PRICE_USD,
  NEXT_MAJOR,
  SOURCE_LICENSE,
  TRIAL_DAYS,
} from "./product-facts.ts";

// Run with: npm test  (Node's built-in runner strips the TS types natively)
//
// A grep-style guard on the public product story, mirroring the model-count
// guard next door. Zerro is an open-source, bring-your-own-key macOS app sold
// as ONE one-time license for the official build, with a local free trial and
// no accounts. These checks catch copy that drifts back to claims the product
// no longer makes (a hosted plan, a credit balance, email verification, an
// account) and pin the current facts on the surfaces that must state them.
// The patterns are deliberately narrow: accurate wording such as "no
// subscription" or "no credit balance" must keep passing.

const WEB_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Every active surface that states product, pricing, or privacy facts. */
const PRODUCT_COPY = [
  "components/marketing/pricing.tsx",
  "components/marketing/faq-data.ts",
  "components/marketing/built-right.tsx",
  "components/marketing/hero.tsx",
  "components/marketing/final-cta.tsx",
  "components/marketing/what-is-zerro.tsx",
  "components/marketing/footer.tsx",
  "components/structured-data.tsx",
  "app/page.tsx",
  "app/layout.tsx",
  "app/privacy/page.tsx",
  "app/terms/page.tsx",
  "app/checkout-complete/page.tsx",
  "lib/site-config.ts",
  "public/llms.txt",
  "public/llms-full.txt",
];

const read = (relative: string) =>
  readFileSync(join(WEB_ROOT, relative), "utf8");

/**
 * Claims the product no longer makes. Each pattern matches only the stale
 * claim itself, never the accurate negation of it.
 */
const STALE_CLAIMS: { pattern: RegExp; why: string }[] = [
  { pattern: /Zerro Cloud/, why: "there is no hosted Zerro Cloud plan or trial" },
  {
    pattern: /\b\d+\s+credits\b|credits (per|a|each) month|top[- ]?up (pack|anytime)|top-ups?\b/i,
    why: "there is no credit balance or top-up pack",
  },
  {
    pattern: /\$\d+\s*(\/|per)\s*(mo|month|year|yr)\b|billed (yearly|monthly|annually)|(monthly|yearly|annual|recurring) (plan|subscription|price)/i,
    why: "the only price is the one-time license",
  },
  {
    pattern: /email verification|verif(y|ied) (your )?email|one-time (6-digit )?code|magic link|sent via Resend|\bResend\b/i,
    why: "nothing is verified by email; there is no transactional email provider",
  },
  {
    pattern: /create an account|paid account|delete your account|your account\b|Zerro Cloud Trial/i,
    why: "Zerro has no user accounts",
  },
  {
    pattern: /server-funded|our generation service|generation log|forwards it to a/i,
    why: "generation never passes through a Zerro server",
  },
  {
    pattern: /\bSupabase\b/i,
    why: "Supabase is gone; GitHub hosts the source code, release downloads, and update feeds",
  },
  {
    pattern: /10 (successful )?(BYOK )?(trial )?generations|30 (Zerro Cloud )?Trial|Managed mode|Limited offer|Most popular|Save ~20%|Cancel anytime/i,
    why: "the old trial allowances and subscription-card furniture are gone",
  },
  {
    pattern: /finish setting up your plan|purchasing a plan|choose the path|Let us handle the AI/i,
    why: "there is one product, not a choice of plans",
  },
];

for (const relative of PRODUCT_COPY) {
  test(`${relative} makes no stale product claim`, () => {
    const source = read(relative);
    for (const { pattern, why } of STALE_CLAIMS) {
      const hit = pattern.exec(source);
      assert.equal(hit, null, `${relative} still says "${hit?.[0]}" — ${why}`);
    }
  });
}

/**
 * The components and pages quote lib/product-facts instead of hand-typing
 * numbers, so the pricing section, FAQ, legal pages, and JSON-LD can't drift.
 */
const DERIVES_FACTS = [
  "components/marketing/pricing.tsx",
  "components/marketing/faq-data.ts",
  "components/structured-data.tsx",
  "app/terms/page.tsx",
  "app/privacy/page.tsx",
];

for (const relative of DERIVES_FACTS) {
  test(`${relative} derives its product facts from lib/product-facts`, () => {
    const source = read(relative);
    assert.ok(
      source.includes("@/lib/product-facts"),
      `${relative} should import from @/lib/product-facts`,
    );
    assert.equal(
      /\$\d+/.exec(source),
      null,
      `${relative} hand-types a dollar amount; use LICENSE_PRICE`,
    );
    assert.equal(
      /\b\d+-day\b/.exec(source),
      null,
      `${relative} hand-types a trial length; use TRIAL_DAYS`,
    );
  });
}

/**
 * Static assets can't import the constants, so the current facts are pinned
 * here: price, trial, Mac count, covered releases, next major, source license.
 */
const STATIC_FACT_SURFACES = ["public/llms.txt", "public/llms-full.txt"];

for (const relative of STATIC_FACT_SURFACES) {
  test(`${relative} states the current product facts`, () => {
    const source = read(relative);
    const required = [
      `${LICENSE_PRICE} one-time`,
      `${TRIAL_DAYS}-day free trial`,
      `up to ${LICENSE_MAC_COUNT} Macs`,
      `${LICENSED_RELEASES} updates`,
      `${NEXT_MAJOR} major release`,
      SOURCE_LICENSE,
      "No card",
      "no account",
      "own key",
    ];
    for (const fact of required) {
      assert.ok(source.includes(fact), `${relative} should state "${fact}"`);
    }
  });
}

test("the JSON-LD advertises exactly one offer, priced like the pricing section", () => {
  const source = read("components/structured-data.tsx");
  const offers = source.match(/"@type": "Offer"/g) ?? [];
  assert.equal(offers.length, 1, "one product, one Offer");
  assert.ok(
    source.includes("price: String(LICENSE_PRICE_USD)"),
    "the Offer price must come from LICENSE_PRICE_USD",
  );
  assert.equal(LICENSE_PRICE, `$${LICENSE_PRICE_USD}`);
});

test("the pricing section sells one license and no billing toggle", () => {
  const source = read("components/marketing/pricing.tsx");
  assert.equal(/useState|Billing\b|isSubscription|yearlyTotal/.exec(source), null, "no subscription toggle state remains");
  assert.ok(source.includes("LICENSE_PRICE"), "the card price comes from LICENSE_PRICE");
  assert.ok(source.includes("LICENSE_MAC_COUNT"), "the card states the Mac count");
  assert.ok(source.includes("LICENSED_RELEASES"), "the card states the covered releases");
});

test("the legal pages carry the required privacy and licensing facts", () => {
  const privacy = read("app/privacy/page.tsx");
  for (const fact of ["Keychain", "directly", "Lemon Squeezy", "PostHog", "OpenAI transcription", "TRIAL_DAYS"]) {
    assert.ok(privacy.includes(fact), `privacy should mention "${fact}"`);
  }
  const terms = read("app/terms/page.tsx");
  for (const fact of ["SOURCE_LICENSE", "TRADEMARKS.md", "LICENSE_MAC_COUNT", "NEXT_MAJOR", "Lemon Squeezy", "community build"]) {
    assert.ok(terms.includes(fact), `terms should mention "${fact}"`);
  }
  assert.equal(
    /Reverse engineer/.exec(terms),
    null,
    "the GPL grants the right to study and modify the source; the terms must not prohibit it",
  );
});

test("the checkout-complete page speaks about license activation, not a plan", () => {
  const source = read("app/checkout-complete/page.tsx");
  assert.ok(source.includes("activate your license"));
  assert.ok(source.includes("API Keys &amp; License"));
});

/**
 * Wording that misstates how the trial starts or where the recording goes.
 * Narrow on purpose: "audio goes directly to OpenAI" (transcription on the
 * user's key) stays legal, and the only "every … request goes straight to
 * your provider" wording allowed is the scoped "every generation request";
 * the unqualified "every request" claim is rejected because license
 * validation, update checks, support, and optional analytics do not go to an
 * AI provider.
 */
const MISSTATEMENTS: { pattern: RegExp; why: string }[] = [
  {
    pattern: /every official download starts/i,
    why: "the trial begins the first time an official build runs on a Mac, and reinstalling does not reset it",
  },
  {
    pattern: /\b(recordings?|narration|spoken audio|audio)( and (your )?(narration|audio))? (then )?(go|goes|is sent|are sent|is uploaded|are uploaded) (straight|directly) (from your Mac )?to (the|your|that) (AI |selected |generation )?provider/i,
    why: "generation sends prepared frames and the transcript, never the full recording or audio, to the provider",
  },
  {
    pattern: /smartaiscaling\.com/i,
    why: "support lives at support@getzerro.app",
  },
  {
    pattern: /(license|licence)( key)?( and [^.]{0,40})? (all )?lives? (only )?on your Mac|license exists only (locally|on your Mac)/i,
    why: "only the license key and local activation credentials are on the Mac; Lemon Squeezy retains the purchase, activation, and device records",
  },
  {
    pattern: /every request (goes|is sent) (straight|directly)/i,
    why: "only generation requests go to the AI provider; license validation, update checks, support, and optional analytics do not",
  },
];

for (const relative of PRODUCT_COPY) {
  test(`${relative} does not misstate the trial, the recording path, or the support address`, () => {
    const source = read(relative);
    for (const { pattern, why } of MISSTATEMENTS) {
      const hit = pattern.exec(source);
      assert.equal(hit, null, `${relative} still says "${hit?.[0]}" — ${why}`);
    }
  });
}

test("the trial surfaces say the trial begins on first run and survives a reinstall", () => {
  for (const relative of ["components/marketing/faq-data.ts", "public/llms.txt", "public/llms-full.txt", "app/terms/page.tsx", "app/privacy/page.tsx"]) {
    const source = read(relative);
    assert.ok(/first time an official build runs/i.test(source), `${relative} should say the trial begins the first time an official build runs`);
    assert.ok(/reinstall/i.test(source), `${relative} should say reinstalling does not reset the trial`);
  }
});

test("the hero and final CTA state the trial length, no card or account, and the key requirement", () => {
  for (const relative of ["components/marketing/hero.tsx", "components/marketing/final-cta.tsx"]) {
    const source = read(relative);
    assert.ok(source.includes("TRIAL_DAYS"), `${relative} should state the trial length from TRIAL_DAYS`);
    assert.ok(/No card or Zerro account/.test(source), `${relative} should say no card or Zerro account is required`);
    assert.ok(/provider API key/.test(source), `${relative} should say the user's own provider API key is required`);
  }
});

test("the terms do not restrict GPL-covered official builds", () => {
  // JSX wraps prose across lines; compare on collapsed whitespace.
  const terms = read("app/terms/page.tsx").replace(/\s+/g, " ");
  const restriction = /non-transferable|non-exclusive|limited,? (non-|personal )|revocable license to use|may not (copy|modify|redistribute)|reverse engineer/i.exec(terms);
  assert.equal(restriction, null, `terms still restrict GPL-covered software: "${restriction?.[0]}"`);
  for (const fact of ["covered executable code in the official builds", "remove or change the trial and license checks", "does not purchase, and does not limit", "cannot be read as terminating"]) {
    assert.ok(terms.includes(fact), `terms should state: ${fact}`);
  }
  assert.ok(/share, resell, or publish a license key/i.test(terms), "license-key sharing must stay prohibited");
  assert.ok(/represent(ed)? .*as an official Zerro release/i.test(terms), "misrepresenting a build as official must stay prohibited");
});

test("accepting the commercial terms is not a condition of receiving or running the GPL application", () => {
  const terms = read("app/terms/page.tsx").replace(/\s+/g, " ");
  const condition = /By (downloading|installing|running|using) (an official build|the app|the application|Zerro)[^.]*you agree|do not (download|install|run|use) (the app|the application|Zerro)\b/i.exec(terms);
  assert.equal(condition, null, `terms make acceptance a condition of receiving or running the application: "${condition?.[0]}"`);
  assert.ok(/not required to accept these Terms in order to receive or run/i.test(terms), "terms should state acceptance is not required to receive or run the application (GPLv3 section 9)");
  assert.ok(/governed solely by[^.]*not by these Terms/i.test(terms), "terms should state copy/modify/redistribute rights are governed solely by GPL-3.0-or-later");
  assert.ok(/nothing in these Terms adds any restriction/i.test(terms), "terms should promise no added restriction on any GPL right");
  assert.ok(/website, checkout, license activation, our official signed and notarized distribution, the official update service, support, and use of the Zerro trademarks/i.test(terms), "the Service must be scoped to SmartScale's commercial services, not the application");
});

test("the terms regulate only SmartScale's commercial services, never operating the GPL application", () => {
  const terms = read("app/terms/page.tsx").replace(/\s+/g, " ");
  // Metadata must not claim the Terms govern use of the application.
  const meta = /description:\s*"([^"]*)"/.exec(terms)?.[1] ?? "";
  assert.equal(/govern (your )?use of the (Zerro )?app/i.exec(meta), null, `metadata still claims the terms govern the app: "${meta}"`);
  assert.ok(/commercial services/i.test(meta), "metadata should describe the commercial services around Zerro");
  // Acceptable use / indemnification must not attach contractual restrictions
  // to merely recording or processing with the application.
  const acceptable = /title="Acceptable use[^]*?<\/LegalSection>/i.exec(terms)?.[0] ?? "";
  const indemnity = /title="Indemnification"[^]*?<\/LegalSection>/i.exec(terms)?.[0] ?? "";
  for (const [name, section] of [["Acceptable use", acceptable], ["Indemnification", indemnity]] as const) {
    assert.ok(section.length > 0, `${name} section missing`);
    const hit = /<li>(Record|Capture|Use the (Service|app|application) to (capture|record|submit|process))|arising out of: \(a\) content you (record|submit)|regulated-data restriction|Use the Service to violate/i.exec(section);
    assert.equal(hit, null, `${name} still regulates operating the application: "${hit?.[0]}"`);
  }
  assert.ok(/do not govern how you run, study, copy, modify, or redistribute the application/i.test(acceptable), "acceptable use should disclaim any reach over GPL rights");
  assert.ok(/does not apply to your running, studying, copying, modifying, or redistributing the application/i.test(indemnity), "indemnification should exclude GPL activities and recording");
  // AI providers and local coding agents are the user's relationships, not
  // dependencies of the commercial Service.
  const dependency = /Service (depends on|relies on)[^.]*(AI model provider|OpenAI|Anthropic|Gemini|coding[- ]agent|Claude Code|Codex|Cursor)/i.exec(terms);
  assert.equal(dependency, null, `terms define providers or agents as Service dependencies: "${dependency?.[0]}"`);
  assert.ok(/not part of the Service/i.test(terms), "terms should say provider and agent relationships are not part of the Service");
  // Changes to the Terms bind only continued use of the Service, never merely
  // continuing to receive or run the GPL-covered application.
  const unqualified = /Continued use after changes take effect constitutes acceptance/i.exec(terms);
  assert.equal(unqualified, null, `terms still bind continued use of the application to changed terms: "${unqualified?.[0]}"`);
  assert.ok(/Continued use of the Service after changes take effect constitutes acceptance/i.test(terms), "the acceptance sentence must be scoped to continued use of the Service");
  assert.ok(/merely continuing to receive or run the GPL-covered application does not/i.test(terms), "the acceptance sentence must exclude merely receiving or running the application");
  // The GPL section 9 language and the controlling-license statement survive.
  assert.ok(/not required to accept these Terms in order to receive or run/i.test(terms));
  assert.ok(/\{SOURCE_LICENSE\} controls/.test(terms), "GPL-3.0-or-later must remain the controlling license for GPL-covered software");
});

test("the license-locality copy credits Lemon Squeezy with the purchase, activation, and device records", () => {
  for (const relative of ["app/terms/page.tsx", "components/marketing/faq-data.ts", "public/llms-full.txt", "app/privacy/page.tsx"]) {
    const source = read(relative).replace(/\s+/g, " ");
    assert.ok(/activation credentials/i.test(source), `${relative} should say the license key and local activation credentials are stored on the Mac`);
    assert.ok(/Lemon Squeezy[^.]*(retains|keeps)[^.]*(activation|device) records/i.test(source), `${relative} should say Lemon Squeezy retains the activation/device records`);
  }
});

test("built-right scopes the direct-to-provider claim to generation requests", () => {
  const source = read("components/marketing/built-right.tsx");
  assert.ok(source.includes("every generation request goes straight"), "should say every generation request");
});

test("the Dev Mode legal copy names every supported agent", () => {
  for (const relative of ["app/privacy/page.tsx", "app/terms/page.tsx"]) {
    const source = read(relative);
    for (const agent of ["Claude Code", "Codex", "Cursor"]) {
      assert.ok(source.includes(agent), `${relative} should name ${agent}`);
    }
    assert.equal(
      /launches Claude Code \(|Claude Code coding agent used by Dev Mode|powers Dev Mode/.exec(source),
      null,
      `${relative} should refer to the agent the user selects, not Claude Code alone`,
    );
  }
});

test("the footer uses the getzerro.app support address", () => {
  const footer = read("components/marketing/footer.tsx");
  assert.ok(footer.includes("support@getzerro.app"));
});

test("the checkout URL placeholder is gone with its last consumer", () => {
  assert.equal(/CLOUD_CHECKOUT_URL/.exec(read("lib/site-config.ts")), null);
});
