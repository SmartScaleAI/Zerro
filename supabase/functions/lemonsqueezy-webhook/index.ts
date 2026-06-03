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

// Thin entrypoint. All logic lives in handler.ts so the lifecycle + idempotency
// + stale-drop behavior is unit-testable with an in-memory store + computed
// signatures (see handler_test.ts). This function does I/O only: read the raw
// body + headers, build the production store, delegate, and translate the result
// to an HTTP response.

import { serviceClient } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { handlePreflight, text } from "../_shared/http.ts";
import { SupabaseWebhookStore } from "./store.ts";
import { handleWebhook } from "./handler.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") return text("method not allowed", 405);

  const secret = requireEnv("LEMONSQUEEZY_WEBHOOK_SECRET");
  const store = new SupabaseWebhookStore(serviceClient());

  // Read the RAW body bytes (the signature is HMAC'd over them — never parse +
  // re-serialize before verifying).
  const rawBody = await req.text();
  const signature = req.headers.get("X-Signature");
  const eventNameHeader = req.headers.get("X-Event-Name");

  const result = await handleWebhook(rawBody, signature, eventNameHeader, { store, secret });
  return text(result.body, result.status);
});
