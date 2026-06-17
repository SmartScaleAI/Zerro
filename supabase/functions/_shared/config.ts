// Tunable billing constants. Values that are "still to confirm" in the billing
// plan (§12) live here as named constants / env-overridable, never as scattered
// literals (cross-cutting requirement: "caps, token lifetimes as config").

import { optionalEnvInt, optionalEnv } from "./env.ts";

// ---- Managed-plan monthly credit allowance ---------------------------------
// One managed tier (metered-credits Phase 6): 300 credits / $15. Override per
// environment without a code change.
export const CREDITS_MANAGED = optionalEnvInt("CREDITS_MANAGED", 300);

// The single billing tier. Kept as a (one-member) union + type so every
// passthrough site (jwt claims, store rows, entitlement snapshot) stays typed.
export type Tier = "managed";

// ---- Tier resolution from LemonSqueezy variant ids -------------------------
// There is one managed product (with a monthly AND a yearly variant), so every
// subscription variant resolves to the single 'managed' tier — see
// lemonsqueezy-webhook/tier.ts `resolveTier`. The variant ids are still needed
// to distinguish the YEARLY variant for billing_interval (display/analytics
// only — both intervals share the managed allowance and 30-day reset cadence).
//
// SECRET FORMAT: a COMMA-SEPARATED LIST of variant ids, because the managed
// product carries a monthly AND a yearly variant (the $15/mo + $144/yr
// checkouts). BOTH go in LS_VARIANT_MANAGED.
//   LS_VARIANT_MANAGED="1735329,1735330"   # Managed monthly, Managed yearly
export const LS_VARIANT_MANAGED = optionalEnv("LS_VARIANT_MANAGED", "");

// Which managed variant id is the YEARLY one. Drives
// subscriptions.billing_interval ONLY — display/analytics metadata, never a
// credit gate: yearly subs still roll the same 300-credit period every 30 days
// via subscription_payment_success. A subscription variant NOT in this list is
// recorded as 'monthly'; a missing variant id records NULL (never guess).
//   LS_VARIANT_YEARLY="1735330"        # Managed yearly
export const LS_VARIANT_YEARLY = optionalEnv("LS_VARIANT_YEARLY", "");

// ---- Top-up packs (multi-model plan §1.4) -----------------------------------
// One-time products (LS `order_created`, NOT subscription events). The webhook
// matches the order's variant id against these comma-separated lists and
// inserts a topup_credits row for the buyer's active subscription. Credits and
// expiry are env-tunable without a code change; ls_order_id uniqueness makes a
// redelivered order a no-op.
//   LS_VARIANT_TOPUP_BOOST="1735340"   # Boost $10 → 200 credits
//   LS_VARIANT_TOPUP_POWER="1735341"   # Power $22 → 500 credits
export const LS_VARIANT_TOPUP_BOOST = optionalEnv("LS_VARIANT_TOPUP_BOOST", "");
export const LS_VARIANT_TOPUP_POWER = optionalEnv("LS_VARIANT_TOPUP_POWER", "");
export const TOPUP_BOOST_CREDITS = optionalEnvInt("TOPUP_BOOST_CREDITS", 200);
export const TOPUP_POWER_CREDITS = optionalEnvInt("TOPUP_POWER_CREDITS", 500);
// Top-up packs expire this many months after purchase (§1.4: 12).
export const TOPUP_EXPIRY_MONTHS = optionalEnvInt("TOPUP_EXPIRY_MONTHS", 12);

// ---- Session token lifetime ------------------------------------------------
// §12 open value (15–60 min). Default 30 min. Also the staleness window anchor
// for the Phase G live re-check (§14.6).
export const SESSION_TOKEN_TTL_SECONDS = optionalEnvInt(
  "SESSION_TOKEN_TTL_SECONDS",
  30 * 60,
);

// ---- Rate limits on the `session` credential exchange (§14.2) ---------------
// Basic fixed-window limiter (backed by check_rate_limit). Phase G tightens.
export const SESSION_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "SESSION_RATE_LIMIT_WINDOW_SECONDS",
  60,
);
export const SESSION_RATE_LIMIT_PER_KEY = optionalEnvInt(
  "SESSION_RATE_LIMIT_PER_KEY",
  10,
);
export const SESSION_RATE_LIMIT_PER_IP = optionalEnvInt(
  "SESSION_RATE_LIMIT_PER_IP",
  30,
);

// ---- §14.6 missed-webhook staleness re-check -------------------------------
// When the local subscription mirror has not been touched by a webhook (or a
// prior live re-check) within this window, `session` does a LIVE LemonSqueezy
// status lookup before minting, so a DROPPED `cancelled`/`expired` webhook can't
// keep minting tokens for a non-paying user forever. Anchored to the token
// lifetime by default: a missed revocation is caught within ~one token TTL of
// the mirror going stale (an already-issued token still can't outlive its short
// expiry). The freshness anchor is the mirror row's `updated_at` (the
// set_updated_at trigger stamps it on every webhook write AND on a live
// re-check's reconcile), so a recently-heard-from subscription skips the call.
export const SESSION_STALENESS_SECONDS = optionalEnvInt(
  "SESSION_STALENESS_SECONDS",
  SESSION_TOKEN_TTL_SECONDS,
);

// LemonSqueezy REST API base for the live re-check (GET /subscriptions/{id}).
// The LEMONSQUEEZY_API_KEY secret is read in session/index.ts; absent → the
// guard is disabled (logged) and session fails OPEN rather than locking users
// out, since the key being unset is an infra condition, not a revocation.
export const LEMONSQUEEZY_API_BASE = optionalEnv(
  "LEMONSQUEEZY_API_BASE",
  "https://api.lemonsqueezy.com/v1",
);
