import "./test_setup.ts"; // MUST be first — sets LS_VARIANT_* before config loads.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { hmacSha256, sha256Hex, toHex } from "../_shared/crypto.ts";
import { handleWebhook, type WebhookDeps } from "./handler.ts";
import type {
  MirrorSub,
  Status,
  SubscriptionPatch,
  SubscriptionUpsert,
  WebhookStore,
} from "./store.ts";

const SECRET = "test_webhook_secret";
const NOW_ISO = "2026-06-02T12:00:00.000Z";

// ---- In-memory WebhookStore (faithful model of the mirror) ------------------
interface Sub {
  id: string;
  ls_subscription_id: string;
  ls_customer_id: string | null;
  ls_order_id: string | null;
  tier: string;
  status: string;
  current_period_end: string | null;
  credits_limit: number;
  ls_updated_at: string | null;
  license_key_hash: string | null;
}
interface Period {
  subscription_id: string;
  period_start: string;
  period_end: string | null;
  credits_used: number;
}

class InMemoryWebhookStore implements WebhookStore {
  events = new Set<string>();
  subs: Sub[] = [];
  periods: Period[] = [];
  pending = new Map<string, { license_key_hash: string; ls_customer_id: string | null }>();
  private nextId = 1;

  // Test knobs.
  throwOnOpenPeriod = false;

  recordEvent(eventId: string): Promise<"fresh" | "duplicate"> {
    if (this.events.has(eventId)) return Promise.resolve("duplicate");
    this.events.add(eventId);
    return Promise.resolve("fresh");
  }
  deleteEvent(eventId: string): Promise<void> {
    this.events.delete(eventId);
    return Promise.resolve();
  }
  getSubByLsId(lsId: string): Promise<MirrorSub | null> {
    const s = this.subs.find((x) => x.ls_subscription_id === lsId);
    return Promise.resolve(s ? { id: s.id, ls_updated_at: s.ls_updated_at } : null);
  }
  getSubByLsIdForInvoice(lsId: string): Promise<MirrorSub | null> {
    return this.getSubByLsId(lsId);
  }
  upsertSubscription(row: SubscriptionUpsert): Promise<{ id: string; ls_order_id: string | null }> {
    let s = this.subs.find((x) => x.ls_subscription_id === row.ls_subscription_id);
    if (s) {
      Object.assign(s, row);
    } else {
      s = { id: `sub-${this.nextId++}`, license_key_hash: null, ...row };
      this.subs.push(s);
    }
    return Promise.resolve({ id: s.id, ls_order_id: s.ls_order_id });
  }
  updateSubscription(id: string, patch: SubscriptionPatch): Promise<void> {
    const s = this.subs.find((x) => x.id === id);
    if (s) Object.assign(s, patch);
    return Promise.resolve();
  }
  setStatusByOrderId(orderId: string, status: Status): Promise<string[]> {
    const hit = this.subs.filter((x) => x.ls_order_id === orderId);
    for (const s of hit) s.status = status;
    return Promise.resolve(hit.map((s) => s.id));
  }
  linkLicenseKeyByOrderId(orderId: string, keyHash: string): Promise<string[]> {
    const hit = this.subs.filter((x) => x.ls_order_id === orderId);
    for (const s of hit) s.license_key_hash = keyHash;
    return Promise.resolve(hit.map((s) => s.id));
  }
  openPeriod(subscriptionId: string, periodStart: string, periodEnd: string | null): Promise<void> {
    if (this.throwOnOpenPeriod) return Promise.reject(new Error("boom"));
    // Idempotent on (subscription_id, period_start) — the unique key.
    const exists = this.periods.some(
      (p) => p.subscription_id === subscriptionId && p.period_start === periodStart,
    );
    if (!exists) {
      this.periods.push({ subscription_id: subscriptionId, period_start: periodStart, period_end: periodEnd, credits_used: 0 });
    }
    return Promise.resolve();
  }
  getPendingKey(orderId: string): Promise<{ license_key_hash: string } | null> {
    const p = this.pending.get(orderId);
    return Promise.resolve(p ? { license_key_hash: p.license_key_hash } : null);
  }
  upsertPendingKey(row: { orderId: string; keyHash: string; customerId: string | null }): Promise<void> {
    this.pending.set(row.orderId, { license_key_hash: row.keyHash, ls_customer_id: row.customerId });
    return Promise.resolve();
  }
  deletePendingKey(orderId: string): Promise<void> {
    this.pending.delete(orderId);
    return Promise.resolve();
  }

  // ---- test inspection helpers ----
  sub(lsId: string): Sub | undefined {
    return this.subs.find((x) => x.ls_subscription_id === lsId);
  }
  periodsFor(subId: string): Period[] {
    return this.periods.filter((p) => p.subscription_id === subId);
  }
}

// ---- helpers ----------------------------------------------------------------
function deps(store: InMemoryWebhookStore): WebhookDeps {
  return { store, secret: SECRET, nowIso: () => NOW_ISO };
}

async function sign(body: string): Promise<string> {
  return toHex(await hmacSha256(SECRET, body));
}

/** Deliver a webhook with a VALID signature (unless `badSig` is given). */
async function deliver(
  store: InMemoryWebhookStore,
  eventName: string,
  payload: unknown,
  badSig?: string | null,
) {
  const raw = JSON.stringify(payload);
  const signature = badSig === undefined ? await sign(raw) : badSig;
  return await handleWebhook(raw, signature, eventName, deps(store));
}

function subPayload(over: {
  id?: string;
  variant_id?: number;
  status?: string;
  updated_at?: string;
  renews_at?: string | null;
  order_id?: string;
  created_at?: string;
  custom_tier?: string;
} = {}) {
  return {
    meta: { event_name: "placeholder", custom_data: over.custom_tier ? { tier: over.custom_tier } : undefined },
    data: {
      type: "subscriptions",
      id: over.id ?? "ls_1",
      attributes: {
        customer_id: 5,
        order_id: over.order_id ?? "order_1",
        variant_id: over.variant_id ?? 101, // starter by default (test_setup mapping)
        status: over.status ?? "active",
        renews_at: over.renews_at ?? "2026-07-02T00:00:00.000Z",
        created_at: over.created_at ?? "2026-06-02T00:00:00.000Z",
        updated_at: over.updated_at ?? "2026-06-02T00:00:00.000Z",
      },
    },
  };
}

function invoicePayload(over: {
  invoiceId?: string;
  subId?: string;
  billing_reason?: string;
  updated_at?: string;
  created_at?: string;
} = {}) {
  return {
    meta: { event_name: "placeholder" },
    data: {
      type: "subscription-invoices",
      id: over.invoiceId ?? "inv_1",
      attributes: {
        subscription_id: over.subId ?? "ls_1",
        customer_id: 5,
        billing_reason: over.billing_reason ?? "renewal",
        status: "paid",
        created_at: over.created_at ?? "2026-07-02T00:00:00.000Z",
        updated_at: over.updated_at ?? "2026-07-02T00:00:00.000Z",
      },
    },
  };
}

// ===========================================================================
// §1 — signature forgery + replay
// ===========================================================================
Deno.test("bad signature → 401, nothing written", async () => {
  const store = new InMemoryWebhookStore();
  const res = await deliver(store, "subscription_created", subPayload(), "deadbeef");
  assertEquals(res.status, 401);
  assertEquals(store.subs.length, 0);
  assertEquals(store.events.size, 0); // idempotency ledger untouched
});

Deno.test("missing signature → 401", async () => {
  const store = new InMemoryWebhookStore();
  const res = await deliver(store, "subscription_created", subPayload(), null);
  assertEquals(res.status, 401);
  assertEquals(store.subs.length, 0);
});

Deno.test("replay: identical event delivered twice → processed once (composite idempotency)", async () => {
  const store = new InMemoryWebhookStore();
  const r1 = await deliver(store, "subscription_created", subPayload());
  assertEquals(r1.status, 200);
  const r2 = await deliver(store, "subscription_created", subPayload()); // exact redelivery
  assertEquals(r2.status, 200);
  assertEquals(r2.body, "ok (duplicate)");
  // Exactly one subscription, exactly one period (no double-roll).
  assertEquals(store.subs.length, 1);
  assertEquals(store.periodsFor("sub-1").length, 1);
});

// ===========================================================================
// §3 — full subscription lifecycle
// ===========================================================================
Deno.test("created → active + first period + correct tier (Starter)", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 101 }));
  const s = store.sub("ls_1")!;
  assertEquals(s.status, "active");
  assertEquals(s.tier, "starter");
  assertEquals(s.credits_limit, 100);
  assertEquals(s.current_period_end, "2026-07-02T00:00:00.000Z");
  const periods = store.periodsFor(s.id);
  assertEquals(periods.length, 1);
  assertEquals(periods[0].credits_used, 0);
  assertEquals(periods[0].period_start, "2026-06-02T00:00:00.000Z");
});

Deno.test("created → correct tier (Pro) for both Pro variants (variant→tier mapping fix)", async () => {
  for (const variant of [201, 202]) {
    const store = new InMemoryWebhookStore();
    await deliver(store, "subscription_created", subPayload({ id: `ls_${variant}`, variant_id: variant }));
    const s = store.sub(`ls_${variant}`)!;
    assertEquals(s.tier, "pro", `variant ${variant} → pro`);
    assertEquals(s.credits_limit, 300);
  }
});

Deno.test("payment_success (renewal) → new period + credits reset, status active", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload());
  // Spend some credits in the first period.
  store.periodsFor("sub-1")[0].credits_used = 60;

  await deliver(store, "subscription_payment_success", invoicePayload({ billing_reason: "renewal" }));
  const periods = store.periodsFor("sub-1");
  assertEquals(periods.length, 2); // a fresh period was rolled
  const latest = periods.find((p) => p.period_start === "2026-07-02T00:00:00.000Z")!;
  assertEquals(latest.credits_used, 0); // fresh allowance (reset)
  assertEquals(store.sub("ls_1")!.status, "active");
});

Deno.test("payment_success NON-renewal (initial/updated) → active but NO new period", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload());
  await deliver(store, "subscription_payment_success", invoicePayload({ billing_reason: "updated", invoiceId: "inv_upd" }));
  assertEquals(store.periodsFor("sub-1").length, 1); // no roll
});

Deno.test("updated (tier change Starter→Pro) → new limit, current period unchanged", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 101 }));
  store.periodsFor("sub-1")[0].credits_used = 25;

  await deliver(store, "subscription_updated", subPayload({ variant_id: 201, updated_at: "2026-06-03T00:00:00.000Z" }));
  const s = store.sub("ls_1")!;
  assertEquals(s.tier, "pro");
  assertEquals(s.credits_limit, 300); // new limit (applies next period)
  // Current open period is untouched — same row, same credits_used, no new period.
  const periods = store.periodsFor("sub-1");
  assertEquals(periods.length, 1);
  assertEquals(periods[0].credits_used, 25);
});

Deno.test("payment_failed → past_due, credits + period unchanged (§9.1)", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload());
  store.periodsFor("sub-1")[0].credits_used = 30;

  await deliver(store, "subscription_payment_failed", invoicePayload({ billing_reason: "renewal", invoiceId: "inv_fail" }));
  const s = store.sub("ls_1")!;
  assertEquals(s.status, "past_due");
  const periods = store.periodsFor("sub-1");
  assertEquals(periods.length, 1); // no fresh allowance
  assertEquals(periods[0].credits_used, 30); // unchanged
});

Deno.test("payment_recovered (after past_due) → active", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload());
  await deliver(store, "subscription_payment_failed", invoicePayload({ invoiceId: "inv_f", updated_at: "2026-07-02T00:00:00.000Z" }));
  assertEquals(store.sub("ls_1")!.status, "past_due");
  await deliver(store, "subscription_payment_recovered", invoicePayload({ invoiceId: "inv_r", updated_at: "2026-07-02T01:00:00.000Z" }));
  assertEquals(store.sub("ls_1")!.status, "active");
});

Deno.test("cancelled → cancelled; expired → expired", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload());
  await deliver(store, "subscription_cancelled", subPayload({ status: "cancelled", updated_at: "2026-06-04T00:00:00.000Z" }));
  assertEquals(store.sub("ls_1")!.status, "cancelled");
  await deliver(store, "subscription_expired", subPayload({ status: "expired", updated_at: "2026-06-05T00:00:00.000Z" }));
  assertEquals(store.sub("ls_1")!.status, "expired");
});

Deno.test("refund (payment_refunded) → expired + revoked", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload());
  await deliver(store, "subscription_payment_refunded", invoicePayload({ invoiceId: "inv_ref", updated_at: "2026-07-03T00:00:00.000Z" }));
  assertEquals(store.sub("ls_1")!.status, "expired");
});

Deno.test("order_refunded → expired (matched by order id)", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ order_id: "order_X" }));
  const refund = {
    meta: { event_name: "order_refunded" },
    data: { type: "orders", id: "order_X", attributes: { updated_at: "2026-07-04T00:00:00.000Z" } },
  };
  await deliver(store, "order_refunded", refund);
  assertEquals(store.sub("ls_1")!.status, "expired");
});

// ===========================================================================
// stale / out-of-order drop
// ===========================================================================
Deno.test("stale event (strictly-older updated_at) → ignored, mirror unchanged", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ updated_at: "2026-06-10T00:00:00.000Z" }));
  // An OLDER cancelled arrives late — must NOT downgrade the newer active state.
  await deliver(store, "subscription_cancelled", subPayload({ status: "cancelled", updated_at: "2026-06-09T00:00:00.000Z" }));
  assertEquals(store.sub("ls_1")!.status, "active"); // unchanged
});

// ===========================================================================
// license_key_created linkage (in-order + out-of-order)
// ===========================================================================
Deno.test("license_key_created after subscription → links the key hash by order id", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ order_id: "order_LK" }));
  const lk = {
    meta: { event_name: "license_key_created" },
    data: { type: "license-keys", id: "lk_1", attributes: { order_id: "order_LK", key: "RAWKEY-123", customer_id: 5 } },
  };
  await deliver(store, "license_key_created", lk);
  assertEquals(store.sub("ls_1")!.license_key_hash, await sha256Hex("RAWKEY-123"));
});

Deno.test("license_key_created BEFORE subscription → pending, adopted on subscription_created", async () => {
  const store = new InMemoryWebhookStore();
  const lk = {
    meta: { event_name: "license_key_created" },
    data: { type: "license-keys", id: "lk_2", attributes: { order_id: "order_OOO", key: "RAWKEY-OOO", customer_id: 5 } },
  };
  await deliver(store, "license_key_created", lk);
  assert(store.pending.has("order_OOO")); // stashed

  await deliver(store, "subscription_created", subPayload({ order_id: "order_OOO" }));
  assertEquals(store.sub("ls_1")!.license_key_hash, await sha256Hex("RAWKEY-OOO"));
  assertEquals(store.pending.has("order_OOO"), false); // drained
});

// ===========================================================================
// handler error → dedup row rolled back so a genuine retry re-processes
// ===========================================================================
Deno.test("handler/store error → 500 AND the dedup row is rolled back", async () => {
  const store = new InMemoryWebhookStore();
  store.throwOnOpenPeriod = true; // make subscription_created throw mid-handle
  const res = await deliver(store, "subscription_created", subPayload());
  assertEquals(res.status, 500);
  // The event id was rolled back, so a retry (after the transient fault clears)
  // is not wrongly deduped.
  assertEquals(store.events.size, 0);
});

// ===========================================================================
// unhandled + unparseable
// ===========================================================================
Deno.test("known-but-unhandled event → 200 no-op", async () => {
  const store = new InMemoryWebhookStore();
  const res = await deliver(store, "subscription_paused", subPayload());
  assertEquals(res.status, 200);
  assertEquals(store.subs.length, 0);
});

Deno.test("unparseable body (valid signature) → 400", async () => {
  const store = new InMemoryWebhookStore();
  const raw = "{not json";
  const res = await handleWebhook(raw, await sign(raw), "subscription_created", deps(store));
  assertEquals(res.status, 400);
});
