// =============================================================================
// lemonsqueezy-webhook — receives LemonSqueezy events and updates the local
// subscription mirror. (billing-plan §9 / §9.1, §14.3; impl-plan Phase D.)
// =============================================================================
// Deployed with verify_jwt = false: LemonSqueezy webhooks carry no Supabase
// JWT. Security here is the SIGNATURE CHECK (raw-body HMAC, constant-time) — not
// a JWT. See config.toml.
//
// Flow:
//   1. Read RAW body; verify X-Signature (401 on fail) before any work.
//   2. Parse; derive event_name + idempotency key.
//   3. Idempotency: insert the key into webhook_events. Already there → 200
//      no-op (LS redelivers). Only a fresh insert proceeds.
//   4. Ignore stale / out-of-order events (strictly-older updated_at than the
//      row we hold) → 200 no-op.
//   5. Handle the event; mutate the mirror.
//   6. Always 200 on a handled/ignored event so LS doesn't needlessly retry;
//      401 only on signature failure, 400 on unparseable.
//
// IDEMPOTENCY KEY (composite, not the signature):
//   `${event_name}:${data.id}:${data.attributes.updated_at ?? ""}`
//   LemonSqueezy ships no guaranteed-unique event id, and the raw body is NOT
//   guaranteed byte-unique across two DISTINCT events, so signature-keying could
//   in theory drop a legitimate second event. The composite is robust instead:
//     - `data.id` is the JSON:API resource id. For PAYMENT events it is the
//       INVOICE id (globally unique per payment) → distinct payments never
//       collide. For SUBSCRIPTION events it is the subscription id (stable
//       across events) → `updated_at` distinguishes distinct events.
//     - A true redelivery has identical (event_name, id, updated_at) → dedupes.
//     - Two distinct events differ in `id` and/or `updated_at` → never collide.
//   (Falls back to the signature only if `data.id` is somehow absent.)
//
// PAYLOAD SHAPES (verified against LS API docs):
//   - subscription_created/updated/cancelled/expired → `subscriptions` resource;
//     `data.id` = subscription id; attributes carry variant_id, renews_at, etc.
//   - subscription_payment_success/_failed/_recovered/_refunded →
//     `subscription-invoices` resource; `data.id` = INVOICE id; the subscription
//     id is `attributes.subscription_id`; NO renews_at/variant_id.
//   - order_refunded → `orders` resource; `data.id` = order id.
//   - license_key_created → `license-keys` resource; raw key in attributes.key,
//     linked to the subscription by attributes.order_id.

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { verifyLemonSqueezySignature } from "../_shared/ls-signature.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { handlePreflight, text } from "../_shared/http.ts";
import {
  creditsForTier,
  LS_VARIANT_PRO,
  LS_VARIANT_STARTER,
} from "../_shared/config.ts";
import type {
  LsLicenseKeyAttributes,
  LsSubscriptionAttributes,
  LsSubscriptionInvoiceAttributes,
  LsWebhook,
} from "../_shared/types.ts";
import { resolveTier, type TierVariantConfig } from "./tier.ts";

type DB = ReturnType<typeof serviceClient>;
type Status = "active" | "past_due" | "cancelled" | "expired";

// no-content-emitting logger that never includes secrets / raw keys
function logAction(event: string, subscriptionId: string | null, action: string) {
  console.log(JSON.stringify({ fn: "lemonsqueezy-webhook", event, subscriptionId, action }));
}

/**
 * The variant→tier config, sourced from the comma-separated `LS_VARIANT_*`
 * secrets (each product has a monthly AND yearly variant). Passed explicitly to
 * `resolveTier` (in `tier.ts`) so that pure mapping stays unit-testable.
 */
const TIER_CONFIG: TierVariantConfig = {
  starterVariantIds: LS_VARIANT_STARTER,
  proVariantIds: LS_VARIANT_PRO,
};

/**
 * True if `incoming` is STRICTLY older than what we already applied. Equal
 * timestamps are NOT stale (two distinct same-instant events — e.g. a renewal's
 * payment_success and subscription_updated — must both apply; their effects are
 * commutative). Exact redeliveries are caught earlier by the idempotency key,
 * not here.
 */
function isStale(existing: string | null | undefined, incoming: string | null | undefined): boolean {
  if (!existing || !incoming) return false;
  return new Date(incoming).getTime() < new Date(existing).getTime();
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") return text("method not allowed", 405);

  const secret = requireEnv("LEMONSQUEEZY_WEBHOOK_SECRET");
  const db = serviceClient();

  // 1. RAW body + signature verification (over the exact bytes, pre-parse).
  const rawBody = await req.text();
  const signature = req.headers.get("X-Signature");
  const ok = await verifyLemonSqueezySignature(rawBody, signature, secret);
  if (!ok) return text("invalid signature", 401);

  // 2. Parse.
  let payload: LsWebhook;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return text("unparseable body", 400);
  }

  const eventName = req.headers.get("X-Event-Name") ?? payload.meta?.event_name ?? "";
  if (!eventName) return text("missing event name", 400);

  // Composite idempotency key (see header). Fall back to the signature only if
  // the resource id is missing (shouldn't happen — JSON:API requires `id`).
  const resourceId = payload.data?.id ?? "";
  const updatedAt = (payload.data?.attributes as { updated_at?: string } | undefined)?.updated_at ?? "";
  const eventId = resourceId
    ? `${eventName}:${resourceId}:${updatedAt}`
    : signature!.trim().toLowerCase();

  // 3. Idempotency: a fresh insert means "not yet processed".
  const { error: insertErr } = await db
    .from("webhook_events")
    .insert({ ls_event_id: eventId, event_name: eventName });
  if (insertErr) {
    if (insertErr.code === "23505") { // unique violation → already processed
      logAction(eventName, null, "duplicate_ignored");
      return text("ok (duplicate)", 200);
    }
    console.error(JSON.stringify({ fn: "lemonsqueezy-webhook", error: insertErr.message }));
    return text("error recording event", 500);
  }

  // 4 + 5. Handle the event.
  try {
    await handleEvent(db, eventName, payload);
  } catch (e) {
    console.error(
      JSON.stringify({ fn: "lemonsqueezy-webhook", event: eventName, error: String(e) }),
    );
    // Let a genuine retry re-process: drop the dedup row (handlers are
    // idempotent, so re-running is safe).
    await db.from("webhook_events").delete().eq("ls_event_id", eventId);
    return text("handler error", 500);
  }

  return text("ok", 200);
});

async function handleEvent(db: DB, eventName: string, payload: LsWebhook) {
  switch (eventName) {
    // ---- subscription-resource events (data.id = subscription id) ----
    case "subscription_created":
      return await handleSubscriptionUpsert(db, payload, { status: "active", openPeriod: true });
    case "subscription_updated":
      return await handleSubscriptionUpdated(db, payload);
    case "subscription_cancelled":
      return await handleSubscriptionStatusChange(db, payload, "cancelled");
    case "subscription_expired":
      return await handleSubscriptionStatusChange(db, payload, "expired");

    // ---- invoice-resource events (data.id = invoice id; sub via attrs) ----
    case "subscription_payment_success":
      return await handleInvoicePaymentSuccess(db, payload as LsWebhook<LsSubscriptionInvoiceAttributes>);
    case "subscription_payment_recovered":
      // Recovery of a past_due payment → active. The accompanying
      // payment_success(renewal) rolls the period; this is status-only.
      return await handleInvoiceStatusChange(db, payload as LsWebhook<LsSubscriptionInvoiceAttributes>, "active");
    case "subscription_payment_failed":
      // §9.1: past_due, do NOT reset credits, do NOT touch the open period.
      return await handleInvoiceStatusChange(db, payload as LsWebhook<LsSubscriptionInvoiceAttributes>, "past_due");
    case "subscription_payment_refunded":
      // Refund/dispute on a subscription invoice → revoke (§14.2).
      return await handleInvoiceStatusChange(db, payload as LsWebhook<LsSubscriptionInvoiceAttributes>, "expired");

    // ---- order-resource events (data.id = order id) ----
    case "order_refunded":
      return await handleOrderRefund(db, payload);

    // ---- license-key-resource events ----
    case "license_key_created":
      return await handleLicenseKeyCreated(db, payload as LsWebhook<LsLicenseKeyAttributes>);

    default:
      // Known-but-unhandled (paused, resumed, on_trial, order_created…) →
      // intentionally ignored, still 200 so LS stops retrying.
      logAction(eventName, null, "ignored_unhandled");
      return;
  }
}

// ---- subscription_created (and the shared upsert spine) --------------------

async function handleSubscriptionUpsert(
  db: DB,
  payload: LsWebhook,
  opts: { status: Status; openPeriod: boolean },
) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;
  const tier = resolveTier(attrs, payload.meta?.custom_data, TIER_CONFIG);
  const creditsLimit = creditsForTier(tier);
  const renewsAt = attrs.renews_at ?? null;

  const { data: existing } = await db
    .from("subscriptions")
    .select("id, ls_updated_at")
    .eq("ls_subscription_id", lsSubId)
    .maybeSingle();

  if (existing && isStale(existing.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_created", existing.id, "stale_ignored");
    return;
  }

  const row = {
    ls_subscription_id: lsSubId,
    ls_customer_id: attrs.customer_id !== undefined ? String(attrs.customer_id) : null,
    ls_order_id: attrs.order_id !== undefined ? String(attrs.order_id) : null,
    tier,
    status: opts.status,
    current_period_end: renewsAt,
    credits_limit: creditsLimit,
    ls_updated_at: attrs.updated_at ?? null,
  };

  const { data: upserted, error } = await db
    .from("subscriptions")
    .upsert(row, { onConflict: "ls_subscription_id" })
    .select("id, ls_order_id")
    .single();
  if (error) throw error;

  const subscriptionId = upserted.id as string;

  if (opts.openPeriod) {
    const periodStart = attrs.created_at ?? new Date().toISOString();
    await openPeriod(db, subscriptionId, periodStart, renewsAt);
  }

  await adoptPendingLicenseKey(db, subscriptionId, row.ls_order_id);
  logAction("subscription_created", subscriptionId, "upserted+period_opened");
}

// ---- subscription_updated (tier change; v1: new limit NEXT period) ---------

async function handleSubscriptionUpdated(db: DB, payload: LsWebhook) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;
  const tier = resolveTier(attrs, payload.meta?.custom_data, TIER_CONFIG);
  const creditsLimit = creditsForTier(tier);

  const { data: existing } = await db
    .from("subscriptions")
    .select("id, ls_updated_at")
    .eq("ls_subscription_id", lsSubId)
    .maybeSingle();

  if (!existing) {
    return handleSubscriptionUpsert(db, payload, { status: "active", openPeriod: true });
  }
  if (isStale(existing.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_updated", existing.id, "stale_ignored");
    return;
  }

  // v1: update tier + credits_limit (new limit applies NEXT period only — the
  // open usage_period is untouched) and refresh the period-end anchor. Status is
  // NOT changed here; it is driven by the payment/cancel events.
  const { error } = await db
    .from("subscriptions")
    .update({
      tier,
      credits_limit: creditsLimit,
      current_period_end: attrs.renews_at ?? null,
      ls_updated_at: attrs.updated_at ?? null,
    })
    .eq("id", existing.id);
  if (error) throw error;

  logAction("subscription_updated", existing.id, `tier_changed_to_${tier}_next_period`);
}

// ---- subscription_cancelled / _expired (status-only, by subscription id) ---

async function handleSubscriptionStatusChange(db: DB, payload: LsWebhook, status: Status) {
  const attrs = payload.data.attributes as LsSubscriptionAttributes;
  const lsSubId = payload.data.id;

  const { data: existing } = await db
    .from("subscriptions")
    .select("id, ls_updated_at")
    .eq("ls_subscription_id", lsSubId)
    .maybeSingle();

  if (!existing) {
    logAction("subscription_status", null, `no_subscription_for_${status}`);
    return;
  }
  if (isStale(existing.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_status", existing.id, `stale_ignored_${status}`);
    return;
  }

  const { error } = await db
    .from("subscriptions")
    .update({ status, ls_updated_at: attrs.updated_at ?? null })
    .eq("id", existing.id);
  if (error) throw error;

  logAction("subscription_status", existing.id, `status=${status}`);
}

// ---- invoice events: resolve the subscription via attributes.subscription_id

/** Look up the mirror row for an invoice event. */
async function subForInvoice(db: DB, attrs: LsSubscriptionInvoiceAttributes) {
  const subId = attrs.subscription_id !== undefined ? String(attrs.subscription_id) : null;
  if (!subId) return { subId: null, row: null as null | { id: string; ls_updated_at: string | null; current_period_end: string | null } };
  const { data } = await db
    .from("subscriptions")
    .select("id, ls_updated_at, current_period_end")
    .eq("ls_subscription_id", subId)
    .maybeSingle();
  return { subId, row: data ?? null };
}

// subscription_payment_success — the ONLY event that grants a fresh allowance,
// and only for a RENEWAL invoice (billing_reason). 'initial' is owned by
// subscription_created (it opened the first period); 'updated' is a mid-cycle
// proration invoice and must not reset credits (v1: tier change next period).
async function handleInvoicePaymentSuccess(db: DB, payload: LsWebhook<LsSubscriptionInvoiceAttributes>) {
  const attrs = payload.data.attributes;
  const { subId, row } = await subForInvoice(db, attrs);

  if (!row) {
    // No mirror row yet (created not processed, or unknown sub). Nothing to
    // reset against; created will open the initial period.
    logAction("subscription_payment_success", null, `no_subscription_${subId ?? "unknown"}`);
    return;
  }
  if (isStale(row.ls_updated_at, attrs.updated_at)) {
    logAction("subscription_payment_success", row.id, "stale_ignored");
    return;
  }

  // Always flip to active on a successful payment.
  const { error: updErr } = await db
    .from("subscriptions")
    .update({ status: "active", ls_updated_at: attrs.updated_at ?? null })
    .eq("id", row.id);
  if (updErr) throw updErr;

  if (attrs.billing_reason === "renewal") {
    // Roll a fresh period (credits_used = 0) = the fresh monthly allowance.
    // period_start = the invoice's own created_at (unique + monotonic per
    // payment), so the (subscription_id, period_start) unique key dedupes a
    // redelivered renewal without ever false-merging two distinct renewals.
    // period_end is informational only (consume_credit uses "latest period",
    // and the user-facing reset_date is subscriptions.current_period_end, which
    // subscription_updated maintains) — so a missing renews_at here is fine.
    const periodStart = attrs.created_at ?? attrs.updated_at ?? new Date().toISOString();
    await openPeriod(db, row.id, periodStart, null);
    logAction("subscription_payment_success", row.id, "renewal_period_rolled");
  } else {
    logAction("subscription_payment_success", row.id, `active_no_roll_${attrs.billing_reason ?? "unknown"}`);
  }
}

// payment_failed → past_due (no reset); payment_recovered → active;
// payment_refunded → expired. All status-only, by subscription_id.
async function handleInvoiceStatusChange(
  db: DB,
  payload: LsWebhook<LsSubscriptionInvoiceAttributes>,
  status: Status,
) {
  const attrs = payload.data.attributes;
  const { subId, row } = await subForInvoice(db, attrs);

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
  const { error } = await db
    .from("subscriptions")
    .update({ status, ls_updated_at: attrs.updated_at ?? null })
    .eq("id", row.id);
  if (error) throw error;

  logAction("invoice_status", row.id, `status=${status}`);
}

// ---- order_refunded → expired (match by order id) --------------------------

async function handleOrderRefund(db: DB, payload: LsWebhook) {
  // order_refunded carries an `orders` resource: data.id is the order id.
  const orderId = payload.data.id;
  if (!orderId) {
    logAction("order_refunded", null, "no_order_id");
    return;
  }

  const { data: rows, error } = await db
    .from("subscriptions")
    .update({ status: "expired" })
    .eq("ls_order_id", orderId)
    .select("id");
  if (error) throw error;

  logAction("order_refunded", rows?.[0]?.id ?? null, `expired_${rows?.length ?? 0}_subscription(s)`);
}

// ---- license_key_created → hash + link by order id -------------------------

async function handleLicenseKeyCreated(db: DB, payload: LsWebhook<LsLicenseKeyAttributes>) {
  const attrs = payload.data.attributes;
  const rawKey = attrs.key;
  const orderId = attrs.order_id !== undefined ? String(attrs.order_id) : null;
  if (!rawKey || !orderId) {
    logAction("license_key_created", null, "missing_key_or_order");
    return;
  }

  const keyHash = await sha256Hex(rawKey);

  const { data: rows, error } = await db
    .from("subscriptions")
    .update({ license_key_hash: keyHash })
    .eq("ls_order_id", orderId)
    .select("id");
  if (error) throw error;

  if (rows && rows.length > 0) {
    logAction("license_key_created", rows[0].id, "key_hash_linked");
    return;
  }

  // Subscription not here yet (out-of-order). Stash for adoption on
  // subscription_created.
  const { error: pendErr } = await db
    .from("pending_license_keys")
    .upsert(
      {
        ls_order_id: orderId,
        license_key_hash: keyHash,
        ls_customer_id: attrs.customer_id !== undefined ? String(attrs.customer_id) : null,
      },
      { onConflict: "ls_order_id" },
    );
  if (pendErr) throw pendErr;

  logAction("license_key_created", null, "key_hash_pending");
}

// ---- helpers ---------------------------------------------------------------

async function openPeriod(
  db: DB,
  subscriptionId: string,
  periodStart: string,
  periodEnd: string | null,
) {
  // period_end is informational only (see handleInvoicePaymentSuccess). A NULL
  // renews_at falls back to far-future so it never zeroes a user out.
  const end = periodEnd ?? new Date("9999-12-31T00:00:00Z").toISOString();
  // ignoreDuplicates: the (subscription_id, period_start) unique key makes a
  // re-roll a no-op (idempotent renewal).
  const { error } = await db
    .from("usage_periods")
    .upsert(
      { subscription_id: subscriptionId, period_start: periodStart, period_end: end, credits_used: 0 },
      { onConflict: "subscription_id,period_start", ignoreDuplicates: true },
    );
  if (error) throw error;
}

async function adoptPendingLicenseKey(db: DB, subscriptionId: string, orderId: string | null) {
  if (!orderId) return;
  const { data: pending } = await db
    .from("pending_license_keys")
    .select("license_key_hash")
    .eq("ls_order_id", orderId)
    .maybeSingle();
  if (!pending) return;

  await db
    .from("subscriptions")
    .update({ license_key_hash: pending.license_key_hash })
    .eq("id", subscriptionId);
  await db.from("pending_license_keys").delete().eq("ls_order_id", orderId);
  logAction("license_key_adopt", subscriptionId, "pending_key_linked");
}
