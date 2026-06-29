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

import type { Tier, TopupPackDef } from "../_shared/config.ts";
import type { LsSubscriptionAttributes } from "../_shared/types.ts";

/** Parse a comma-separated variant-id secret into trimmed, non-empty ids. */
export function parseVariantList(raw: string): string[] {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

// ---- Startup config validation (launch-blocker A-01) -------------------------
// A misconfigured LS_VARIANT_YEARLY silently mislabels yearly subscriptions as
// "monthly": resolveBillingInterval (below) only tags a sub "yearly" when its
// variant is in the yearly list, else "monthly". An empty or wrong list →
// yearly subs recorded as billing_interval='monthly' → excluded from
// refresh_yearly_credit_periods() (which filters billing_interval='yearly') →
// the prepaid yearly customer is starved after one month (LS sends only an
// annual renewal webhook). These checks turn that silent misconfig into a loud,
// impossible-to-miss failure at deploy time. See PRE_RELEASE_REVIEW_LOG.md A-01.

export interface ConfigValidation {
  /** True when LS_VARIANT_YEARLY is safe (non-empty AND ⊆ LS_VARIANT_MANAGED). */
  ok: boolean;
  /** Distinct, greppable error code when !ok (null when ok). */
  code: string | null;
  /** Human-readable explanation when !ok (null when ok). */
  message: string | null;
}

/**
 * Validate the yearly-variant config against the full managed-variant list.
 * PURE — a function of the two raw secret strings only — so the verdict is
 * deterministic and never "transient" (same env → same answer, no I/O that can
 * flake), and it is unit-testable without touching env or the network.
 *
 * Two rules, both A-01:
 *   1. LS_VARIANT_YEARLY must list ≥1 id. Empty → every sub (incl. yearly)
 *      resolves to "monthly" and the yearly refresh cron skips it.
 *   2. Every yearly id must also appear in LS_VARIANT_MANAGED (the full managed
 *      monthly+yearly list). A yearly id absent from managed means the two
 *      secrets have drifted (a typo or a stale/removed variant) — that variant
 *      could never be recognized as managed, so the config is untrustworthy.
 */
export function validateYearlyVariantConfig(
  yearlyRaw: string,
  managedRaw: string,
): ConfigValidation {
  const yearly = parseVariantList(yearlyRaw);
  if (yearly.length === 0) {
    return {
      ok: false,
      code: "config_yearly_variants_empty",
      message:
        "LS_VARIANT_YEARLY is empty: every subscription (including yearly) would be " +
        "recorded as billing_interval='monthly' and excluded from the yearly " +
        "credit-refresh cron, starving prepaid yearly customers after one month.",
    };
  }
  const managed = new Set(parseVariantList(managedRaw));
  const orphans = yearly.filter((id) => !managed.has(id));
  if (orphans.length > 0) {
    return {
      ok: false,
      code: "config_yearly_variants_not_subset_of_managed",
      message:
        `LS_VARIANT_YEARLY has id(s) not present in LS_VARIANT_MANAGED: ` +
        `[${orphans.join(", ")}]. The yearly ids must be a SUBSET of the managed ` +
        `list (monthly + yearly); an orphan means the secrets have drifted (typo ` +
        `or a stale/removed variant).`,
    };
  }
  return { ok: true, code: null, message: null };
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

/**
 * Match an order's variant id to a top-up pack in the ordered registry, or null
 * when the order is not a recognized top-up product (e.g. the BYOK license order
 * — the caller falls through to the existing ignored-unhandled path; never a
 * default grant). Iterates `packs` (config.TOPUP_PACKS) in declared order and
 * returns the first whose variant-id list contains `variantId`. The returned
 * `pack` is the pack's key (a string), used only for logging.
 */
export function resolveTopupPack(
  variantId: string,
  packs: TopupPackDef[],
): { pack: string; credits: number } | null {
  if (!variantId) return null;
  for (const p of packs) {
    if (parseVariantList(p.variantIds).includes(variantId)) {
      return { pack: p.key, credits: p.credits };
    }
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
