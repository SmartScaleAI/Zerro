import { assertEquals } from "jsr:@std/assert@1";
import { parseVariantList, resolveBillingInterval, resolveTier, resolveTopupPack } from "./tier.ts";

// Realistic config: each product has a monthly + a yearly variant, supplied as
// one comma-separated secret (the shape that previously failed === matching).
// LS_VARIANT_YEARLY lists which of those mapped ids are the yearly ones.
const CONFIG = {
  starterVariantIds: "1735300,1735301",
  proVariantIds: "1735329,1735330",
  yearlyVariantIds: "1735301,1735330",
};

// LemonSqueezy sends variant_id as a NUMBER; resolveTier coerces with String()
// before the membership check against the (string) configured list.
const PRO_MONTHLY = 1735329;
const PRO_YEARLY = 1735330;
const STARTER_MONTHLY = 1735300;
const UNKNOWN = 9999999;

function attrs(variantId: number | undefined) {
  return { variant_id: variantId };
}

Deno.test("parseVariantList trims and drops empties", () => {
  assertEquals(parseVariantList("1735329, 1735330 ,"), ["1735329", "1735330"]);
  assertEquals(parseVariantList(""), []);
  assertEquals(parseVariantList("  "), []);
});

Deno.test("Pro monthly variant resolves to pro", () => {
  assertEquals(resolveTier(attrs(PRO_MONTHLY), null, CONFIG), "pro");
});

Deno.test("Pro yearly variant resolves to pro", () => {
  assertEquals(resolveTier(attrs(PRO_YEARLY), null, CONFIG), "pro");
});

Deno.test("Starter variant resolves to starter", () => {
  assertEquals(resolveTier(attrs(STARTER_MONTHLY), null, CONFIG), "starter");
});

Deno.test("unknown variant defaults to starter with a warning", () => {
  const warnings: string[] = [];
  const original = console.warn;
  console.warn = (msg?: unknown) => { warnings.push(String(msg)); };
  try {
    assertEquals(resolveTier(attrs(UNKNOWN), null, CONFIG), "starter");
  } finally {
    console.warn = original;
  }
  assertEquals(warnings.length, 1);
  const logged = JSON.parse(warnings[0]);
  assertEquals(logged.warn, "unmapped_variant_defaulting_to_starter");
  assertEquals(logged.variant_id, UNKNOWN);
});

Deno.test("custom_data.tier is the fallback when the variant is unmapped", () => {
  assertEquals(resolveTier(attrs(UNKNOWN), { tier: "pro" }, CONFIG), "pro");
  assertEquals(resolveTier(attrs(UNKNOWN), { tier: "starter" }, CONFIG), "starter");
});

Deno.test("a mapped variant wins over custom_data.tier", () => {
  // A real Pro variant resolves to pro even if custom_data claims starter.
  assertEquals(resolveTier(attrs(PRO_MONTHLY), { tier: "starter" }, CONFIG), "pro");
});

// ---- billing_interval (Phase 5) ----------------------------------------------

Deno.test("billing interval: yearly-listed variant → yearly, other mapped → monthly", () => {
  assertEquals(resolveBillingInterval(attrs(PRO_YEARLY), CONFIG), "yearly");
  assertEquals(resolveBillingInterval(attrs(PRO_MONTHLY), CONFIG), "monthly");
  assertEquals(resolveBillingInterval(attrs(STARTER_MONTHLY), CONFIG), "monthly");
});

Deno.test("billing interval: unmapped or missing variant → null (never guessed)", () => {
  assertEquals(resolveBillingInterval(attrs(UNKNOWN), CONFIG), null);
  assertEquals(resolveBillingInterval(attrs(undefined), CONFIG), null);
});

// ---- top-up packs (Phase 5, one-time orders) ----------------------------------

const TOPUP_CONFIG = {
  boostVariantIds: "1735340",
  powerVariantIds: "1735341,1735342", // e.g. live + test-mode ids
  boostCredits: 200,
  powerCredits: 500,
};

Deno.test("top-up: Boost and Power variants resolve to their packs", () => {
  assertEquals(resolveTopupPack("1735340", TOPUP_CONFIG), { pack: "boost", credits: 200 });
  assertEquals(resolveTopupPack("1735341", TOPUP_CONFIG), { pack: "power", credits: 500 });
  assertEquals(resolveTopupPack("1735342", TOPUP_CONFIG), { pack: "power", credits: 500 });
});

Deno.test("top-up: unknown or empty variant → null (order falls through unhandled)", () => {
  assertEquals(resolveTopupPack("9999999", TOPUP_CONFIG), null);
  assertEquals(resolveTopupPack("", TOPUP_CONFIG), null);
});
