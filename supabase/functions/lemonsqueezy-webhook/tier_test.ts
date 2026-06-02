import { assertEquals } from "jsr:@std/assert@1";
import { parseVariantList, resolveTier } from "./tier.ts";

// Realistic config: each product has a monthly + a yearly variant, supplied as
// one comma-separated secret (the shape that previously failed === matching).
const CONFIG = {
  starterVariantIds: "1735300,1735301",
  proVariantIds: "1735329,1735330",
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
