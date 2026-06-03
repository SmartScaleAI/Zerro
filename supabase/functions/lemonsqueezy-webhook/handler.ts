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
import { creditsForTier, LS_VARIANT_PRO, LS_VARIANT_STARTER } from "../_shared/config.ts";
import type {
  LsLicenseKeyAttributes,
  LsSubscriptionAttributes,
  LsSubscriptionInvoiceAttributes,
  LsWebhook,
} from "../_shared/types.ts";
import { resolveTier, type TierVariantConfig } from "./tier.ts";
import type { Status, WebhookStore } from "./store.ts";

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
  starterVariantIds: LS_VARIANT_STARTER,
  proVariantIds: LS_VARIANT_PRO,
};

function logAction(event: string, subscriptionId: string | null, action: string) {
  console.log(JSON.stringify({ fn: "lemonsqueezy-webhook", event, subscriptionId, action }));
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
  const creditsLimit = creditsForTier(tier);
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
    ls_order_id: orderId,
    tier,
    status: opts.status,
    current_period_end: renewsAt,
    credits_limit: creditsLimit,
    ls_updated_at: attrs.updated_at ?? null,
  });

  if (opts.openPeriod) {
    const periodStart = attrs.created_at ?? nowIso(deps);
    await deps.store.openPeriod(subscriptionId, periodStart, renewsAt);
  }

  await adoptPendingLicenseKey(deps, subscriptionId, ls_order_id);
  logAction("subscription_created", subscriptionId, "upserted+period_opened");
}

// ---- subscription_updated (tier change; v1: new limit NEXT period) ---------

async function handleSubscriptionUpdated(deps: WebhookDeps, payload: LsWebhook) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;
  const tier = resolveTier(attrs, payload.meta?.custom_data, TIER_CONFIG);
  const creditsLimit = creditsForTier(tier);

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
  await deps.store.updateSubscription(existing.id, {
    tier,
    credits_limit: creditsLimit,
    current_period_end: attrs.renews_at ?? null,
    ls_updated_at: attrs.updated_at ?? null,
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

// ---- order_refunded → expired (match by order id) --------------------------

async function handleOrderRefund(deps: WebhookDeps, payload: LsWebhook) {
  const orderId = payload.data.id;
  if (!orderId) {
    logAction("order_refunded", null, "no_order_id");
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
