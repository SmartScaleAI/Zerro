// =============================================================================
// Variant → tier resolution (pure, unit-testable).
// =============================================================================
// Extracted from index.ts so it can be tested without importing the function
// entrypoint (which calls Deno.serve at module load). `resolveTier` takes the
// variant-id config explicitly rather than reading env, so a test can drive
// every branch deterministically.
//
// IMPORTANT: `LS_VARIANT_STARTER` / `LS_VARIANT_PRO` are COMMA-SEPARATED LISTS
// of variant ids — one product has a monthly AND a yearly variant (e.g. Pro =
// "1735329,1735330"). We must test MEMBERSHIP of the incoming variant in the
// list, not equality against the whole string (that never matched a single id
// and silently defaulted everything to starter).

import type { Tier } from "../_shared/config.ts";
import type { LsSubscriptionAttributes } from "../_shared/types.ts";

/** Parse a comma-separated variant-id secret into trimmed, non-empty ids. */
export function parseVariantList(raw: string): string[] {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export interface TierVariantConfig {
  /** Raw comma-separated starter variant ids (monthly + yearly). */
  starterVariantIds: string;
  /** Raw comma-separated pro variant ids (monthly + yearly). */
  proVariantIds: string;
  /** Raw comma-separated YEARLY variant ids across all tiers (LS_VARIANT_YEARLY).
   *  Drives billing_interval only — both intervals share the tier's allowance
   *  and 30-day reset cadence. */
  yearlyVariantIds: string;
}

export type BillingInterval = "monthly" | "yearly";

/**
 * Derive billing_interval from which variant matched. The LS subscription
 * payload carries no interval field (the interval lives on the variant, which
 * webhooks don't expand), so the yearly variant ids are configured explicitly.
 * A tier-mapped variant not in the yearly list is monthly; an UNMAPPED variant
 * returns null (interval unknown — never guess; the column is nullable).
 */
export function resolveBillingInterval(
  attrs: LsSubscriptionAttributes,
  config: TierVariantConfig,
): BillingInterval | null {
  const variant = attrs.variant_id !== undefined ? String(attrs.variant_id) : "";
  if (!variant) return null;
  if (parseVariantList(config.yearlyVariantIds).includes(variant)) return "yearly";
  const mapped = parseVariantList(config.proVariantIds).includes(variant) ||
    parseVariantList(config.starterVariantIds).includes(variant);
  return mapped ? "monthly" : null;
}

// ---- Top-up packs (one-time orders, plan §1.4) -------------------------------

export interface TopupVariantConfig {
  /** Raw comma-separated Boost variant ids (LS_VARIANT_TOPUP_BOOST). */
  boostVariantIds: string;
  /** Raw comma-separated Power variant ids (LS_VARIANT_TOPUP_POWER). */
  powerVariantIds: string;
  boostCredits: number;
  powerCredits: number;
}

/**
 * Match an order's variant id to a top-up pack, or null when the order is not
 * a recognized top-up product (e.g. the BYOK license order — the caller falls
 * through to the existing ignored-unhandled path; never a default grant).
 */
export function resolveTopupPack(
  variantId: string,
  config: TopupVariantConfig,
): { pack: "boost" | "power"; credits: number } | null {
  if (!variantId) return null;
  if (parseVariantList(config.boostVariantIds).includes(variantId)) {
    return { pack: "boost", credits: config.boostCredits };
  }
  if (parseVariantList(config.powerVariantIds).includes(variantId)) {
    return { pack: "power", credits: config.powerCredits };
  }
  return null;
}

/**
 * Resolve a LemonSqueezy variant id (+ optional `custom_data.tier` fallback) to
 * our tier. Pro is checked first, then starter; an unmapped variant FAILS SAFE
 * to starter with a warning (the smaller allowance — never over-grant on a
 * mis-config).
 */
export function resolveTier(
  attrs: LsSubscriptionAttributes,
  customData: Record<string, unknown> | null | undefined,
  config: TierVariantConfig,
): Tier {
  const variant = attrs.variant_id !== undefined ? String(attrs.variant_id) : "";
  const proIds = parseVariantList(config.proVariantIds);
  const starterIds = parseVariantList(config.starterVariantIds);

  if (variant && proIds.includes(variant)) return "pro";
  if (variant && starterIds.includes(variant)) return "starter";

  const custom = customData?.tier;
  if (custom === "pro" || custom === "starter") return custom;

  console.warn(
    JSON.stringify({
      fn: "lemonsqueezy-webhook",
      warn: "unmapped_variant_defaulting_to_starter",
      variant_id: attrs.variant_id ?? null,
    }),
  );
  return "starter";
}
