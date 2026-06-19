// Shared types: the LemonSqueezy webhook payloads we handle and the API
// response shapes the Mac app consumes. Verified against LS docs (event names,
// header-based signing, the separate license_key_created event).

import type { Tier } from "./config.ts";

// ---- LemonSqueezy webhook payloads -----------------------------------------
// LS wraps every webhook as { meta, data } where data is a JSON:API resource.
// The event name is in BOTH the `X-Event-Name` header and `meta.event_name`.
// `meta.custom_data` is present for order/subscription/license-key events.

export interface LsMeta {
  event_name: string;
  custom_data?: Record<string, unknown> | null;
  test_mode?: boolean;
}

export interface LsResource<A> {
  type: string;
  id: string; // the LS resource id (e.g. subscription id, license-key id)
  attributes: A;
}

export interface LsWebhook<A = Record<string, unknown>> {
  meta: LsMeta;
  data: LsResource<A>;
}

// Subscription `data.attributes` (the fields we use; LS sends more).
// status values per LS: active | past_due | unpaid | cancelled | expired |
// on_trial | paused.
export interface LsSubscriptionAttributes {
  store_id?: number;
  customer_id?: number;
  user_email?: string | null; // buyer email — mirrored to subscriptions.email_normalized for human identification
  order_id?: number;
  product_id?: number;
  variant_id?: number;
  status?: string;
  renews_at?: string | null; // current period end / reset anchor
  ends_at?: string | null;
  trial_ends_at?: string | null;
  created_at?: string;
  updated_at?: string; // used for stale/out-of-order detection
  [k: string]: unknown;
}

// Subscription-INVOICE `data.attributes`. The payment events
// (subscription_payment_success / _failed / _recovered / _refunded) carry a
// `subscription-invoices` resource — NOT a `subscriptions` resource. So for
// those events `data.id` is the INVOICE id (unique per payment) and the real
// subscription id is `attributes.subscription_id`. Invoices do NOT carry
// `renews_at`/`variant_id` (those are subscription fields).
export interface LsSubscriptionInvoiceAttributes {
  store_id?: number;
  subscription_id?: number; // the subscription this invoice belongs to
  customer_id?: number;
  billing_reason?: "initial" | "renewal" | "updated" | string;
  status?: string; // paid | pending | void | refunded
  refunded?: boolean;
  created_at?: string;
  updated_at?: string;
  [k: string]: unknown;
}

// Order `data.attributes` (order_created / order_refunded — `data.id` is the
// ORDER id). One-time purchases (the top-up packs, the BYOK license) arrive as
// orders, not subscription events. For a single-item checkout the purchased
// variant is `first_order_item.variant_id`; `customer_id` is how a top-up is
// attached to the buyer's existing subscription.
export interface LsOrderAttributes {
  store_id?: number;
  customer_id?: number;
  identifier?: string;
  order_number?: number;
  status?: string; // pending | failed | paid | refunded
  first_order_item?: {
    product_id?: number;
    variant_id?: number;
    [k: string]: unknown;
  } | null;
  created_at?: string;
  updated_at?: string;
  [k: string]: unknown;
}

// License-key `data.attributes`. LS delivers the raw key HERE, in its OWN
// `license_key_created` event — NOT in the subscription payload. We hash `key`
// and link to the subscription by `order_id`.
export interface LsLicenseKeyAttributes {
  store_id?: number;
  customer_id?: number;
  order_id?: number;
  product_id?: number;
  key?: string; // the raw license key — hashed, never stored raw
  key_short?: string;
  status?: string;
  created_at?: string;
  updated_at?: string;
  [k: string]: unknown;
}

// ---- API responses (consumed by the app in Phase E) ------------------------

export interface EntitlementSnapshot {
  tier: Tier;
  status: "active" | "past_due" | "cancelled" | "expired";
  /** COMBINED spendable balance: plan remaining + non-expired top-up (Phase 4 /
   *  F4). This is the app's headline number and matches what the generate
   *  spend path (2-arg consume_credit) will actually allow. */
  credits_remaining: number;
  /** The PLAN allowance for the period (unchanged meaning — top-ups are not
   *  part of the plan cap). Kept for back-compat with pre-multi-model apps
   *  that read remaining/limit as a pair. */
  credits_limit: number;
  /** ISO; when the plan allowance next refreshes. Monthly: current_period_end.
   *  Yearly (E8): the next MONTHLY refresh anchor the cron job will roll
   *  (latest period_start + 1 month, capped at the annual period end). */
  reset_date: string | null;
  // ---- Plan-vs-top-up breakdown (Phase 6F meter + settings view) ------------
  /** Plan credits consumed this period (the usage bar tracks this against
   *  plan_credits_limit while the headline shows the combined balance). */
  plan_credits_used: number;
  /** = credits_limit; explicit so the meter never guesses which cap to use. */
  plan_credits_limit: number;
  /** Non-expired top-up balance (survives the monthly reset; expires 12 months
   *  from purchase). 0 when the user has never bought a pack. */
  topup_credits_remaining: number;
}

export interface SessionResponse {
  token: string;
  expires_at: string; // ISO
  entitlement: EntitlementSnapshot;
}
