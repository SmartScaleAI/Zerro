import { assertEquals } from "jsr:@std/assert@1";
import {
  parseVariantList,
  resolveBillingInterval,
  resolveTier,
  resolveTopupPack,
  validateYearlyVariantConfig,
} from "./tier.ts";

// Single managed tier: the only variant distinction that still matters is which
// id is the YEARLY one (for billing_interval). LS_VARIANT_YEARLY lists it.
const CONFIG = {
  yearlyVariantIds: "1735330",
};

// LemonSqueezy sends variant_id as a NUMBER; the helpers coerce with String().
const MANAGED_MONTHLY = 1735329;
const MANAGED_YEARLY = 1735330;
const OTHER = 9999999;

function attrs(variantId: number | undefined) {
  return { variant_id: variantId };
}

Deno.test("parseVariantList trims and drops empties", () => {
  assertEquals(parseVariantList("1735329, 1735330 ,"), ["1735329", "1735330"]);
  assertEquals(parseVariantList(""), []);
  assertEquals(parseVariantList("  "), []);
});

Deno.test("every subscription variant resolves to the single managed tier", () => {
  assertEquals(resolveTier(attrs(MANAGED_MONTHLY), null, CONFIG), "managed");
  assertEquals(resolveTier(attrs(MANAGED_YEARLY), null, CONFIG), "managed");
  assertEquals(resolveTier(attrs(OTHER), null, CONFIG), "managed");
  assertEquals(resolveTier(attrs(undefined), null, CONFIG), "managed");
});

Deno.test("custom_data no longer changes the tier (single managed tier)", () => {
  assertEquals(resolveTier(attrs(OTHER), { tier: "pro" }, CONFIG), "managed");
  assertEquals(resolveTier(attrs(MANAGED_MONTHLY), { tier: "starter" }, CONFIG), "managed");
});

// ---- billing_interval (Phase 5) ----------------------------------------------

Deno.test("billing interval: yearly-listed variant → yearly, any other present → monthly", () => {
  assertEquals(resolveBillingInterval(attrs(MANAGED_YEARLY), CONFIG), "yearly");
  assertEquals(resolveBillingInterval(attrs(MANAGED_MONTHLY), CONFIG), "monthly");
  assertEquals(resolveBillingInterval(attrs(OTHER), CONFIG), "monthly");
});

Deno.test("billing interval: a MISSING variant id → null (never guessed)", () => {
  assertEquals(resolveBillingInterval(attrs(undefined), CONFIG), null);
});

// ---- A-01: yearly-variant config validation ----------------------------------
// The full managed list (monthly + yearly); the yearly ids must be a subset.
const MANAGED_LIST = "1735329,1735330";

Deno.test("config validation: a correct config (yearly ⊆ managed, non-empty) passes", () => {
  const v = validateYearlyVariantConfig("1735330", MANAGED_LIST);
  assertEquals(v, { ok: true, code: null, message: null });
  // Multiple yearly ids (e.g. live + test-mode), all in managed, also pass.
  assertEquals(validateYearlyVariantConfig("1735330", "1735329,1735330,1735331").ok, true);
});

Deno.test("config validation: an EMPTY LS_VARIANT_YEARLY is flagged (A-01 starvation)", () => {
  const empty = validateYearlyVariantConfig("", MANAGED_LIST);
  assertEquals(empty.ok, false);
  assertEquals(empty.code, "config_yearly_variants_empty");
  // Whitespace/comma-only secrets parse to zero ids → same failure.
  assertEquals(validateYearlyVariantConfig("  , ,", MANAGED_LIST).code, "config_yearly_variants_empty");
});

Deno.test("config validation: a yearly id NOT in LS_VARIANT_MANAGED is flagged", () => {
  // 1735999 is not in the managed list → not a subset.
  const orphan = validateYearlyVariantConfig("1735999", MANAGED_LIST);
  assertEquals(orphan.ok, false);
  assertEquals(orphan.code, "config_yearly_variants_not_subset_of_managed");
  // One good + one orphan still fails (subset must hold for EVERY id).
  assertEquals(
    validateYearlyVariantConfig("1735330,1735999", MANAGED_LIST).code,
    "config_yearly_variants_not_subset_of_managed",
  );
  // A non-empty yearly with an EMPTY managed list can't be a subset → flagged.
  assertEquals(
    validateYearlyVariantConfig("1735330", "").code,
    "config_yearly_variants_not_subset_of_managed",
  );
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
