// =============================================================================
// Variant → tier resolution (pure, unit-testable).
// =============================================================================
// Extracted from index.ts so it can be tested without importing the function
// entrypoint (which calls Deno.serve at module load). `resolveTier` takes the
// variant-id config explicitly rather than reading env, so a test can drive
// every branch deterministically.
//
// IMPORTANT: `LS_VARIANT_YEARLY` is a COMMA-SEPARATED LIST of variant ids — the
// managed product has a monthly AND a yearly variant. We test MEMBERSHIP of the
// incoming variant in the list, not equality against the whole string.

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
  /** Raw comma-separated YEARLY variant ids (LS_VARIANT_YEARLY). Drives
   *  billing_interval only — both intervals share the managed allowance and
   *  30-day reset cadence. (Tier itself is always 'managed' now, so no
   *  per-tier variant lists are needed.) */
  yearlyVariantIds: string;
}

export type BillingInterval = "monthly" | "yearly";

/**
 * Derive billing_interval from which variant matched. The LS subscription
 * payload carries no interval field (the interval lives on the variant, which
 * webhooks don't expand), so the yearly variant ids are configured explicitly.
 * A subscription variant in the yearly list is yearly; any other present
 * variant is monthly; a MISSING variant id returns null (the column is
 * nullable — never guess).
 */
export function resolveBillingInterval(
  attrs: LsSubscriptionAttributes,
  config: TierVariantConfig,
): BillingInterval | null {
  const variant = attrs.variant_id !== undefined ? String(attrs.variant_id) : "";
  if (!variant) return null;
  if (parseVariantList(config.yearlyVariantIds).includes(variant)) return "yearly";
  return "monthly";
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
 * Resolve a subscription variant to our tier. There is a single managed tier
 * now, so EVERY subscription variant resolves to "managed". Kept as a function
 * (rather than inlining the constant) so the webhook's tier resolution stays a
 * single, unit-testable seam. Args are unused but retained so call sites and
 * tests don't churn if per-variant logic ever returns.
 */
export function resolveTier(
  _attrs: LsSubscriptionAttributes,
  _customData: Record<string, unknown> | null | undefined,
  _config: TierVariantConfig,
): Tier {
  return "managed";
}
