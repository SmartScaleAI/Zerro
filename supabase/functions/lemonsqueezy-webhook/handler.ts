// =============================================================================
// lemonsqueezy-webhook — handler logic (Phase G refactor; behavior unchanged).
// =============================================================================
// Extracted from index.ts so the lifecycle + idempotency + stale-drop logic is
// unit-testable with an in-memory store + computed signatures (no Postgres, no
// live LemonSqueezy). The flow, the §9.1 past-due rule, the renewal-only period
// roll, the composite idempotency key, and the strict-older stale-drop are all
// identical to the deployed D1 behavior — see the original header notes inline.
//
// Flow:
//   1. Verify X-Signature over the RAW body (401 on fail) before any work.
//   2. Parse; derive event_name + the COMPOSITE idempotency key.
//   3. recordEvent → "duplicate" → 200 no-op; "fresh" → proceed.
//   4. Dispatch the event; mutate the mirror. Stale/out-of-order events
//      (strictly-older updated_at than what we hold) are 200 no-ops.
//   5. Always 200 on a handled/ignored event; 401 only on signature failure,
//      400 on unparseable, 500 on an unexpected handler/store error (the dedup
//      row is rolled back so a genuine retry re-processes).
// =============================================================================

import { verifyLemonSqueezySignature } from "../_shared/ls-signature.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { normalizeTrialEmail } from "../_shared/email-normalize.ts";
import {
  CREDITS_MANAGED,
  LS_VARIANT_TOPUP_BOOST,
  LS_VARIANT_TOPUP_POWER,
  LS_VARIANT_YEARLY,
  TOPUP_BOOST_CREDITS,
  TOPUP_EXPIRY_MONTHS,
  TOPUP_POWER_CREDITS,
} from "../_shared/config.ts";
import type {
  LsLicenseKeyAttributes,
  LsOrderAttributes,
  LsSubscriptionAttributes,
  LsSubscriptionInvoiceAttributes,
  LsWebhook,
} from "../_shared/types.ts";
import {
  resolveBillingInterval,
  resolveTier,
  resolveTopupPack,
  type TierVariantConfig,
  type TopupVariantConfig,
} from "./tier.ts";
import type { Status, WebhookStore } from "./store.ts";
import { capturePostHog } from "./posthog.ts";

export interface WebhookResult {
  status: number;
  body: string;
}

export interface WebhookDeps {
  store: WebhookStore;
  /** Webhook signing secret (HMAC over the raw body). */
  secret: string;
  /** Injectable clock for the rare period-start fallback (deterministic tests). */
  nowIso?: () => string;
}

const TIER_CONFIG: TierVariantConfig = {
  yearlyVariantIds: LS_VARIANT_YEARLY,
};

const TOPUP_CONFIG: TopupVariantConfig = {
  boostVariantIds: LS_VARIANT_TOPUP_BOOST,
  powerVariantIds: LS_VARIANT_TOPUP_POWER,
  boostCredits: TOPUP_BOOST_CREDITS,
  powerCredits: TOPUP_POWER_CREDITS,
};

function logAction(event: string, subscriptionId: string | null, action: string) {
  console.log(JSON.stringify({ fn: "lemonsqueezy-webhook", event, subscriptionId, action }));
}

/**
 * Tier 3 analytics: the PostHog distinct_id for a subscription event. Prefers
 * the app's anonymous id plumbed through the checkout `custom_data` (so the
 * server-side event stitches onto the SAME person as the app funnel); falls back
 * to a stable `ls:<subscription_id>` when absent (still counted, just unstitched).
 */
function postHogDistinctId(payload: LsWebhook, lsSubId: string): string {
  const custom = payload.meta?.custom_data as { ph_distinct_id?: unknown } | null | undefined;
  const id = custom?.ph_distinct_id;
  return typeof id === "string" && id.length > 0 ? id : `ls:${lsSubId}`;
}

/**
 * True if `incoming` is STRICTLY older than what we already applied. Equal
 * timestamps are NOT stale (two distinct same-instant events must both apply;
 * their effects are commutative). Exact redeliveries are caught by the
 * idempotency key, not here.
 */
function isStale(existing: string | null | undefined, incoming: string | null | undefined): boolean {
  if (!existing || !incoming) return false;
  return new Date(incoming).getTime() < new Date(existing).getTime();
}

/**
 * Canonicalize a buyer email for the subscription mirror's human-readable
 * `email_normalized` column. Lowercases + trims only — deliberately NOT the
 * trial-cap normalization (which strips Gmail dots/+tags to defeat farming):
 * here the goal is recognizing the ACTUAL address a customer used, so the stored
 * form must stay faithful to it. Returns null for missing/blank/`@`-less input
 * so a bad value lands as NULL rather than a junk string.
 */
function normalizeSubscriberEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim().toLowerCase();
  return trimmed.includes("@") ? trimmed : null;
}

/**
 * Handle a raw webhook delivery. `rawBody` MUST be the exact bytes received (the
 * signature is HMAC'd over them); `signature` is the X-Signature header; the
 * `X-Event-Name` header (if present) wins over meta.event_name.
 */
export async function handleWebhook(
  rawBody: string,
  signature: string | null,
  eventNameHeader: string | null,
  deps: WebhookDeps,
): Promise<WebhookResult> {
  // 1. Signature over the raw body, before any work.
  const ok = await verifyLemonSqueezySignature(rawBody, signature, deps.secret);
  if (!ok) return { status: 401, body: "invalid signature" };

  // 2. Parse.
  let payload: LsWebhook;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return { status: 400, body: "unparseable body" };
  }

  const eventName = eventNameHeader ?? payload.meta?.event_name ?? "";
  if (!eventName) return { status: 400, body: "missing event name" };

  // Composite idempotency key (see header). Fall back to the signature only if
  // the resource id is missing (shouldn't happen — JSON:API requires `id`).
  const resourceId = payload.data?.id ?? "";
  const updatedAt = (payload.data?.attributes as { updated_at?: string } | undefined)?.updated_at ?? "";
  const eventId = resourceId
    ? `${eventName}:${resourceId}:${updatedAt}`
    : (signature ?? "").trim().toLowerCase();

  // 3. Idempotency.
  let recorded: "fresh" | "duplicate";
  try {
    recorded = await deps.store.recordEvent(eventId, eventName);
  } catch (e) {
    console.error(JSON.stringify({ fn: "lemonsqueezy-webhook", error: String(e) }));
    return { status: 500, body: "error recording event" };
  }
  if (recorded === "duplicate") {
    logAction(eventName, null, "duplicate_ignored");
    return { status: 200, body: "ok (duplicate)" };
  }

  // 4 + 5. Handle.
  try {
    await handleEvent(deps, eventName, payload);
  } catch (e) {
    console.error(JSON.stringify({ fn: "lemonsqueezy-webhook", event: eventName, error: String(e) }));
    // Let a genuine retry re-process: drop the dedup row (handlers are
    // idempotent, so re-running is safe).
    await deps.store.deleteEvent(eventId);
    return { status: 500, body: "handler error" };
  }

  return { status: 200, body: "ok" };
}

async function handleEvent(deps: WebhookDeps, eventName: string, payload: LsWebhook) {
  switch (eventName) {
    case "subscription_created":
      return await handleSubscriptionUpsert(deps, payload, { status: "active", openPeriod: true });
    case "subscription_updated":
      return await handleSubscriptionUpdated(deps, payload);
    case "subscription_cancelled":
      return await handleSubscriptionStatusChange(deps, payload, "cancelled");
    case "subscription_expired":
      return await handleSubscriptionStatusChange(deps, payload, "expired");

    case "subscription_payment_success":
      return await handleInvoicePaymentSuccess(deps, payload as LsWebhook<LsSubscriptionInvoiceAttributes>);
    case "subscription_payment_recovered":
      return await handleInvoiceStatusChange(deps, payload as LsWebhook<LsSubscriptionInvoiceAttributes>, "active");
    case "subscription_payment_failed":
      return await handleInvoiceStatusChange(deps, payload as LsWebhook<LsSubscriptionInvoiceAttributes>, "past_due");
    case "subscription_payment_refunded":
      return await handleInvoiceStatusChange(deps, payload as LsWebhook<LsSubscriptionInvoiceAttributes>, "expired");

    case "order_created":
      return await handleOrderCreated(deps, payload as LsWebhook<LsOrderAttributes>);
    case "order_refunded":
      return await handleOrderRefund(deps, payload);

    case "license_key_created":
      return await handleLicenseKeyCreated(deps, payload as LsWebhook<LsLicenseKeyAttributes>);

    default:
      logAction(eventName, null, "ignored_unhandled");
      return;
  }
}

function nowIso(deps: WebhookDeps): string {
  return deps.nowIso ? deps.nowIso() : new Date().toISOString();
}

// ---- subscription_created (and the shared upsert spine) --------------------

async function handleSubscriptionUpsert(
  deps: WebhookDeps,
  payload: LsWebhook,
  opts: { status: Status; openPeriod: boolean },
) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;
  const tier = resolveTier(attrs, payload.meta?.custom_data, TIER_CONFIG);
  const creditsLimit = CREDITS_MANAGED;
  const billingInterval = resolveBillingInterval(attrs, TIER_CONFIG);
  const renewsAt = attrs.renews_at ?? null;

  const existing = await deps.store.getSubByLsId(lsSubId);
  if (existing && isStale(existing.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_created", existing.id, "stale_ignored");
    return;
  }

  const orderId = attrs.order_id !== undefined ? String(attrs.order_id) : null;
  const { id: subscriptionId, ls_order_id } = await deps.store.upsertSubscription({
    ls_subscription_id: lsSubId,
    ls_customer_id: attrs.customer_id !== undefined ? String(attrs.customer_id) : null,
    email_normalized: normalizeSubscriberEmail(attrs.user_email),
    ls_order_id: orderId,
    tier,
    status: opts.status,
    current_period_end: renewsAt,
    credits_limit: creditsLimit,
    billing_interval: billingInterval,
    ls_updated_at: attrs.updated_at ?? null,
  });

  if (opts.openPeriod) {
    const periodStart = attrs.created_at ?? nowIso(deps);
    await deps.store.openPeriod(subscriptionId, periodStart, renewsAt);
  }

  await adoptPendingLicenseKey(deps, subscriptionId, ls_order_id);

  // CONVERSION LINK: bind this subscriber to the trial grant they came from, so
  // /generate can drain the trial remainder before billing the paid plan
  // (consume_combined_credit). Set once (linkTrialGrant only writes when null),
  // so a redelivery is a harmless no-op. Best-effort: a miss just leaves the
  // link null and a later subscription event can fill it in.
  await linkTrialGrantOnConversion(deps, subscriptionId, payload, attrs);

  logAction("subscription_created", subscriptionId, "upserted+period_opened");

  // Tier 3 analytics: a newly-mirrored active subscription. Only on this
  // applied path — the stale-drop branch returned early above, and an exact
  // redelivery was 200'd by the idempotency gate before reaching here, so a
  // webhook redelivery can't double-count. Tier only — never email/customer id.
  await capturePostHog("subscription_activated", postHogDistinctId(payload, lsSubId), { tier });
}

// ---- subscription_updated (tier change; v1: new limit NEXT period) ---------

async function handleSubscriptionUpdated(deps: WebhookDeps, payload: LsWebhook) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;
  const tier = resolveTier(attrs, payload.meta?.custom_data, TIER_CONFIG);
  const creditsLimit = CREDITS_MANAGED;
  const billingInterval = resolveBillingInterval(attrs, TIER_CONFIG);

  const existing = await deps.store.getSubByLsId(lsSubId);
  if (!existing) {
    return handleSubscriptionUpsert(deps, payload, { status: "active", openPeriod: true });
  }
  if (isStale(existing.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_updated", existing.id, "stale_ignored");
    return;
  }

  // v1: update tier + credits_limit (new limit applies NEXT period only — the
  // open usage_period is untouched) and refresh the period-end anchor. Status is
  // NOT changed here; it is driven by the payment/cancel events.
  const email = normalizeSubscriberEmail(attrs.user_email);
  await deps.store.updateSubscription(existing.id, {
    tier,
    credits_limit: creditsLimit,
    current_period_end: attrs.renews_at ?? null,
    billing_interval: billingInterval,
    ls_updated_at: attrs.updated_at ?? null,
    // Only refresh when the event actually carries an email — never overwrite a
    // known address with a null from an event that omits user_email.
    ...(email ? { email_normalized: email } : {}),
  });

  logAction("subscription_updated", existing.id, `tier_changed_to_${tier}_next_period`);
}

// ---- subscription_cancelled / _expired (status-only, by subscription id) ---

async function handleSubscriptionStatusChange(deps: WebhookDeps, payload: LsWebhook, status: Status) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;

  const existing = await deps.store.getSubByLsId(lsSubId);
  if (!existing) {
    logAction("subscription_status", null, `no_subscription_for_${status}`);
    return;
  }
  if (isStale(existing.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_status", existing.id, `stale_ignored_${status}`);
    return;
  }

  await deps.store.updateSubscription(existing.id, { status, ls_updated_at: attrs.updated_at ?? null });
  logAction("subscription_status", existing.id, `status=${status}`);

  // Tier 3 analytics: a lapse (cancelled/expired). Only on this applied path —
  // the no-existing and stale branches returned early, and exact redeliveries
  // were caught by the idempotency gate. `status` here is only ever "cancelled"
  // or "expired" (the two events routed to this handler), so it doubles as the
  // reason. `previous_tier` is resolved from the event's own variant. Tier +
  // reason only — never email/customer id/order id.
  const previousTier = resolveTier(attrs, payload.meta?.custom_data, TIER_CONFIG);
  await capturePostHog("subscription_lapsed", postHogDistinctId(payload, lsSubId), {
    previous_tier: previousTier,
    reason: status,
  });
}

// ---- invoice events: resolve the subscription via attributes.subscription_id

async function subForInvoice(deps: WebhookDeps, attrs: LsSubscriptionInvoiceAttributes) {
  const subId = attrs.subscription_id !== undefined ? String(attrs.subscription_id) : null;
  if (!subId) return { subId: null, row: null };
  const row = await deps.store.getSubByLsIdForInvoice(subId);
  return { subId, row };
}

// subscription_payment_success — the ONLY event that grants a fresh allowance,
// and only for a RENEWAL invoice (billing_reason).
async function handleInvoicePaymentSuccess(deps: WebhookDeps, payload: LsWebhook<LsSubscriptionInvoiceAttributes>) {
  const attrs = payload.data.attributes;
  const { subId, row } = await subForInvoice(deps, attrs);

  if (!row) {
    logAction("subscription_payment_success", null, `no_subscription_${subId ?? "unknown"}`);
    return;
  }
  if (isStale(row.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_payment_success", row.id, "stale_ignored");
    return;
  }

  // Always flip to active on a successful payment.
  await deps.store.updateSubscription(row.id, { status: "active", ls_updated_at: attrs.updated_at ?? null });

  if (attrs.billing_reason === "renewal") {
    // Roll a fresh period (credits_used = 0). period_start = the invoice's own
    // created_at (unique + monotonic per payment), so the
    // (subscription_id, period_start) unique key dedupes a redelivered renewal.
    const periodStart = attrs.created_at ?? attrs.updated_at ?? nowIso(deps);
    await deps.store.openPeriod(row.id, periodStart, null);
    logAction("subscription_payment_success", row.id, "renewal_period_rolled");
  } else {
    logAction("subscription_payment_success", row.id, `active_no_roll_${attrs.billing_reason ?? "unknown"}`);
  }
}

// payment_failed → past_due (no reset); payment_recovered → active;
// payment_refunded → expired. All status-only, by subscription_id.
async function handleInvoiceStatusChange(
  deps: WebhookDeps,
  payload: LsWebhook<LsSubscriptionInvoiceAttributes>,
  status: Status,
) {
  const attrs = payload.data.attributes;
  const { subId, row } = await subForInvoice(deps, attrs);

  if (!row) {
    logAction("invoice_status", null, `no_subscription_${subId ?? "unknown"}_for_${status}`);
    return;
  }
  if (isStale(row.ls_updated_at, attrs.updated_at)) {
    logAction("invoice_status", row.id, `stale_ignored_${status}`);
    return;
  }

  // CRITICAL (§9.1): past_due must NOT reset credits or touch the open period.
  // This is a status-only update.
  await deps.store.updateSubscription(row.id, { status, ls_updated_at: attrs.updated_at ?? null });
  logAction("invoice_status", row.id, `status=${status}`);
}

// ---- order_created → top-up pack purchase (plan §1.4) -----------------------
// Top-ups are ONE-TIME orders, not subscription events. Only orders whose
// variant matches a configured top-up pack are handled; everything else (e.g.
// the BYOK license order) falls through to the same ignored-unhandled no-op the
// default case always produced — normal order flow is unaffected.
//
// Double-credit protection is TWO independent layers: the composite
// recordEvent key dedupes an exact redelivery before we get here, and
// topup_credits.ls_order_id is UNIQUE so even a same-order event with a
// different composite key (e.g. a later updated_at) inserts at most one row.

async function handleOrderCreated(deps: WebhookDeps, payload: LsWebhook<LsOrderAttributes>) {
  const attrs = payload.data.attributes;
  const orderId = payload.data.id;
  const variantId = attrs.first_order_item?.variant_id !== undefined
    ? String(attrs.first_order_item.variant_id)
    : "";

  const pack = resolveTopupPack(variantId, TOPUP_CONFIG);
  if (!pack) {
    logAction("order_created", null, "ignored_unhandled");
    return;
  }

  // Only a PAID order grants credits. LS normally fires order_created on a
  // successful checkout, but the status field is the contract — a pending or
  // failed order must never credit. (Absent status → treat as paid; some test
  // payloads omit it.)
  if (attrs.status !== undefined && attrs.status !== "paid") {
    logAction("order_created", null, `topup_skipped_status_${attrs.status}`);
    return;
  }

  // Attach to the buyer's existing subscription via the LS customer id — the
  // same linkage subscription_created mirrors into ls_customer_id. A buyer with
  // NO spendable subscription (BYOK-only or trial user buying a Managed top-up)
  // gets NOTHING credited: there is no bucket to attach to, and topup_credits
  // requires a subscription FK. Logged loudly for manual follow-up/refund — the
  // store page should not offer top-ups to non-Managed users in the first place.
  const customerId = attrs.customer_id !== undefined ? String(attrs.customer_id) : null;
  if (!customerId) {
    logAction("order_created", null, "topup_no_customer_id");
    return;
  }
  const sub = await deps.store.getActiveSubByCustomerId(customerId);
  if (!sub) {
    console.warn(JSON.stringify({
      fn: "lemonsqueezy-webhook",
      warn: "topup_order_without_active_subscription",
      order_id: orderId,
      ls_customer_id: customerId,
      pack: pack.pack,
    }));
    logAction("order_created", null, "topup_no_active_subscription");
    return;
  }

  // 12-month shelf life from the purchase moment (the order's own created_at,
  // falling back to the injectable clock only if LS omitted it).
  const purchasedAt = attrs.created_at ?? nowIso(deps);
  const expiresAt = addMonths(purchasedAt, TOPUP_EXPIRY_MONTHS);

  const result = await deps.store.insertTopup({
    subscriptionId: sub.id,
    credits: pack.credits,
    expiresAt,
    lsOrderId: orderId,
  });
  logAction(
    "order_created",
    sub.id,
    result === "duplicate" ? "topup_duplicate_order" : `topup_${pack.pack}_credited_${pack.credits}`,
  );
}

/** ISO timestamp `months` calendar months after `iso` (UTC; clamps the rare
 *  month-end overflow forward, e.g. Feb 30 → Mar 2 — fine for a shelf life). */
function addMonths(iso: string, months: number): string {
  const d = new Date(iso);
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.toISOString();
}

// ---- order_refunded → revoke (top-up pack OR subscription, by order id) -----
// An order id belongs to EITHER a top-up pack (topup_credits.ls_order_id) or a
// subscription purchase (subscriptions.ls_order_id) — never both. Try the pack
// first: a refunded top-up must stop being spendable (money leak otherwise),
// but only its UNSPENT remainder dies — credits already consumed stay consumed
// (no claw-back, no touching other packs). Unknown order ids fall through both
// branches as the same no-op as before.

async function handleOrderRefund(deps: WebhookDeps, payload: LsWebhook) {
  const orderId = payload.data.id;
  if (!orderId) {
    logAction("order_refunded", null, "no_order_id");
    return;
  }

  const revoked = await deps.store.revokeTopupByOrderId(orderId, nowIso(deps));
  if (revoked > 0) {
    logAction("order_refunded", null, `topup_revoked_${revoked}_pack(s)`);
    return;
  }

  const ids = await deps.store.setStatusByOrderId(orderId, "expired");
  logAction("order_refunded", ids[0] ?? null, `expired_${ids.length}_subscription(s)`);
}

// ---- license_key_created → hash + link by order id -------------------------

async function handleLicenseKeyCreated(deps: WebhookDeps, payload: LsWebhook<LsLicenseKeyAttributes>) {
  const attrs = payload.data.attributes;
  const rawKey = attrs.key;
  const orderId = attrs.order_id !== undefined ? String(attrs.order_id) : null;
  if (!rawKey || !orderId) {
    logAction("license_key_created", null, "missing_key_or_order");
    return;
  }

  const keyHash = await sha256Hex(rawKey);
  const ids = await deps.store.linkLicenseKeyByOrderId(orderId, keyHash);
  if (ids.length > 0) {
    logAction("license_key_created", ids[0], "key_hash_linked");
    return;
  }

  // Subscription not here yet (out-of-order). Stash for adoption on
  // subscription_created.
  await deps.store.upsertPendingKey({
    orderId,
    keyHash,
    customerId: attrs.customer_id !== undefined ? String(attrs.customer_id) : null,
  });
  logAction("license_key_created", null, "key_hash_pending");
}

// ---- helpers ---------------------------------------------------------------

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Link a converting subscriber to their trial grant (subscriptions.trial_grant_id).
 * Two resolution paths, in priority order:
 *   1. An explicit `meta.custom_data.trial_grant_id` plumbed through checkout —
 *      normalization-free and exact. Validated against the DB first, because an
 *      unknown id would violate the FK and 500 the webhook (LS would then retry
 *      forever); an invalid/unknown id silently falls through to (2).
 *   2. The buyer email, re-normalized to the AGGRESSIVE trial form (Gmail
 *      dots/+tags collapsed — subscriptions store only the lowercased form), and
 *      matched against a verified trial_grants row.
 * Throws are swallowed by the caller's try/catch as a 500→retry only for genuine
 * store errors; a clean "no grant found" just leaves the link null.
 */
async function linkTrialGrantOnConversion(
  deps: WebhookDeps,
  subscriptionId: string,
  payload: LsWebhook,
  attrs: LsSubscriptionAttributes,
): Promise<void> {
  let grantId: string | null = null;

  const custom = payload.meta?.custom_data as { trial_grant_id?: unknown } | null | undefined;
  const explicit = typeof custom?.trial_grant_id === "string" ? custom.trial_grant_id.trim().toLowerCase() : "";
  if (UUID_RE.test(explicit)) {
    grantId = await deps.store.getVerifiedTrialGrantIdById(explicit);
  }

  if (!grantId) {
    const norm = attrs.user_email ? normalizeTrialEmail(String(attrs.user_email)) : null;
    if (norm) grantId = await deps.store.getVerifiedTrialGrantIdByEmail(norm);
  }

  if (grantId) {
    await deps.store.linkTrialGrant(subscriptionId, grantId);
    logAction("subscription_created", subscriptionId, "trial_grant_linked");
  }
}

async function adoptPendingLicenseKey(deps: WebhookDeps, subscriptionId: string, orderId: string | null) {
  if (!orderId) return;
  const pending = await deps.store.getPendingKey(orderId);
  if (!pending) return;
  // Link by the subscription id we just upserted (exactly one row), matching the
  // original by-id update — not by order id.
  await deps.store.updateSubscription(subscriptionId, { license_key_hash: pending.license_key_hash });
  await deps.store.deletePendingKey(orderId);
  logAction("license_key_adopt", subscriptionId, "pending_key_linked");
}
