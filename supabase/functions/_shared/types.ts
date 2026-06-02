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
  credits_remaining: number;
  credits_limit: number;
  reset_date: string | null; // ISO; the current_period_end anchor
}

export interface SessionResponse {
  token: string;
  expires_at: string; // ISO
  entitlement: EntitlementSnapshot;
}
