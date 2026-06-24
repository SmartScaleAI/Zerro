import "./test_setup.ts"; // MUST be first — sets LS_VARIANT_* before config loads.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { hmacSha256, sha256Hex, toHex } from "../_shared/crypto.ts";
import { handleWebhook, type WebhookDeps } from "./handler.ts";
import type {
  MirrorSub,
  Status,
  SubscriptionPatch,
  SubscriptionUpsert,
  TopupInsert,
  WebhookStore,
} from "./store.ts";

const SECRET = "test_webhook_secret";
const NOW_ISO = "2026-06-02T12:00:00.000Z";

// ---- In-memory WebhookStore (faithful model of the mirror) ------------------
interface Sub {
  id: string;
  ls_subscription_id: string;
  ls_customer_id: string | null;
  email_normalized: string | null;
  ls_order_id: string | null;
  tier: string;
  status: string;
  current_period_end: string | null;
  credits_limit: number;
  billing_interval: string | null;
  ls_updated_at: string | null;
  license_key_hash: string | null;
  trial_grant_id?: string | null;
}
interface Topup {
  subscription_id: string;
  credits_total: number;
  credits_used: number;
  expires_at: string;
  ls_order_id: string;
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
  topups: Topup[] = [];
  pending = new Map<string, { license_key_hash: string; ls_customer_id: string | null }>();
  /** Verified trial grants keyed by id, with their aggressive email_normalized. */
  trialGrants: { id: string; email_normalized: string; verified: boolean }[] = [];
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
  getActiveSubByCustomerId(lsCustomerId: string): Promise<{ id: string } | null> {
    // Most recent spendable sub for the customer (mirror the SQL: created order
    // ≈ insertion order here, so take the LAST match).
    const hit = this.subs.filter(
      (s) => s.ls_customer_id === lsCustomerId && (s.status === "active" || s.status === "past_due"),
    ).at(-1);
    return Promise.resolve(hit ? { id: hit.id } : null);
  }
  insertTopup(row: TopupInsert): Promise<"inserted" | "duplicate"> {
    // ls_order_id UNIQUE — the second dedupe layer.
    if (this.topups.some((t) => t.ls_order_id === row.lsOrderId)) {
      return Promise.resolve("duplicate");
    }
    this.topups.push({
      subscription_id: row.subscriptionId,
      credits_total: row.credits,
      credits_used: 0,
      expires_at: row.expiresAt,
      ls_order_id: row.lsOrderId,
    });
    return Promise.resolve("inserted");
  }
  revokeTopupByOrderId(orderId: string, revokedAtIso: string): Promise<number> {
    // Mirror the SQL: expire matching, not-yet-expired packs; counters untouched.
    const hit = this.topups.filter(
      (t) => t.ls_order_id === orderId && t.expires_at > revokedAtIso,
    );
    for (const t of hit) t.expires_at = revokedAtIso;
    return Promise.resolve(hit.length);
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

  getVerifiedTrialGrantIdById(grantId: string): Promise<string | null> {
    const g = this.trialGrants.find((x) => x.id === grantId && x.verified);
    return Promise.resolve(g ? g.id : null);
  }
  getVerifiedTrialGrantIdByEmail(normalizedEmail: string): Promise<string | null> {
    const g = this.trialGrants.find((x) => x.email_normalized === normalizedEmail && x.verified);
    return Promise.resolve(g ? g.id : null);
  }
  linkTrialGrant(subscriptionId: string, grantId: string): Promise<void> {
    const s = this.subs.find((x) => x.id === subscriptionId);
    if (s && s.trial_grant_id == null) s.trial_grant_id = grantId; // only when null
    return Promise.resolve();
  }

  // ---- test inspection helpers ----
  seedTrialGrant(id: string, emailNormalized: string, verified = true) {
    this.trialGrants.push({ id, email_normalized: emailNormalized, verified });
  }
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
  user_email?: string | null;
  trial_grant_id?: string;
} = {}) {
  const customData = over.custom_tier || over.trial_grant_id
    ? {
      ...(over.custom_tier ? { tier: over.custom_tier } : {}),
      ...(over.trial_grant_id ? { trial_grant_id: over.trial_grant_id } : {}),
    }
    : undefined;
  return {
    meta: { event_name: "placeholder", custom_data: customData },
    data: {
      type: "subscriptions",
      id: over.id ?? "ls_1",
      attributes: {
        customer_id: 5,
        user_email: over.user_email !== undefined ? over.user_email : "Buyer@Example.com",
        order_id: over.order_id ?? "order_1",
        variant_id: over.variant_id ?? 101, // a managed variant by default (test_setup mapping)
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
// §2b — buyer email mirrored to email_normalized (human identification)
// ===========================================================================
Deno.test("subscription_created mirrors user_email → email_normalized (lowercased+trimmed)", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ user_email: "  Buyer@Example.COM " }));
  assertEquals(store.sub("ls_1")!.email_normalized, "buyer@example.com");
});

Deno.test("subscription_created with no/blank email → email_normalized null", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ user_email: null }));
  assertEquals(store.sub("ls_1")!.email_normalized, null);
});

Deno.test("subscription_updated refreshes a changed email; an event without one keeps the known address", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ user_email: "old@example.com" }));

  // A later update carrying a new email refreshes it.
  await deliver(
    store,
    "subscription_updated",
    subPayload({ user_email: "New@Example.com", updated_at: "2026-06-03T00:00:00.000Z" }),
  );
  assertEquals(store.sub("ls_1")!.email_normalized, "new@example.com");

  // A still-later update with NO email must not wipe the stored one.
  await deliver(
    store,
    "subscription_updated",
    subPayload({ user_email: null, updated_at: "2026-06-04T00:00:00.000Z" }),
  );
  assertEquals(store.sub("ls_1")!.email_normalized, "new@example.com");
});

// ===========================================================================
// §2b — trial↔subscription conversion link (consume_combined_credit groundwork)
// ===========================================================================
Deno.test("conversion link: explicit custom_data.trial_grant_id wins (validated, set once)", async () => {
  const store = new InMemoryWebhookStore();
  const GRANT = "11111111-1111-4111-8111-111111111111";
  store.seedTrialGrant(GRANT, "someone-else@example.com"); // email does NOT match the buyer
  await deliver(store, "subscription_created", subPayload({ trial_grant_id: GRANT }));
  // Linked by the explicit id even though the email wouldn't match.
  assertEquals(store.sub("ls_1")!.trial_grant_id, GRANT);
});

Deno.test("conversion link: unknown explicit id is ignored, email fallback links", async () => {
  const store = new InMemoryWebhookStore();
  const GRANT = "22222222-2222-4222-8222-222222222222";
  // Default buyer email is Buyer@Example.com → aggressive form buyer@example.com.
  store.seedTrialGrant(GRANT, "buyer@example.com");
  await deliver(
    store,
    "subscription_created",
    subPayload({ trial_grant_id: "00000000-0000-4000-8000-000000000000" }), // not in the DB
  );
  assertEquals(store.sub("ls_1")!.trial_grant_id, GRANT);
});

Deno.test("conversion link: email fallback collapses Gmail dots/+tags to match the grant", async () => {
  const store = new InMemoryWebhookStore();
  const GRANT = "33333333-3333-4333-8333-333333333333";
  store.seedTrialGrant(GRANT, "buyer@gmail.com"); // the aggressive trial form
  await deliver(
    store,
    "subscription_created",
    subPayload({ user_email: "B.u.Yer+promo@Googlemail.com" }),
  );
  assertEquals(store.sub("ls_1")!.trial_grant_id, GRANT);
});

Deno.test("conversion link: no matching grant → trial_grant_id stays null (no false link)", async () => {
  const store = new InMemoryWebhookStore();
  store.seedTrialGrant("44444444-4444-4444-8444-444444444444", "nobody@example.com");
  await deliver(store, "subscription_created", subPayload({ user_email: "buyer@example.com" }));
  assertEquals(store.sub("ls_1")!.trial_grant_id ?? null, null);
});

Deno.test("conversion link: an unverified grant is never linked", async () => {
  const store = new InMemoryWebhookStore();
  store.seedTrialGrant("55555555-5555-4555-8555-555555555555", "buyer@example.com", false);
  await deliver(store, "subscription_created", subPayload({ user_email: "buyer@example.com" }));
  assertEquals(store.sub("ls_1")!.trial_grant_id ?? null, null);
});

// ===========================================================================
// §3 — full subscription lifecycle
// ===========================================================================
Deno.test("created → active + first period + the single managed tier", async () => {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 101 }));
  const s = store.sub("ls_1")!;
  assertEquals(s.status, "active");
  assertEquals(s.tier, "managed");
  assertEquals(s.credits_limit, 300);
  assertEquals(s.current_period_end, "2026-07-02T00:00:00.000Z");
  const periods = store.periodsFor(s.id);
  assertEquals(periods.length, 1);
  assertEquals(periods[0].credits_used, 0);
  assertEquals(periods[0].period_start, "2026-06-02T00:00:00.000Z");
});

Deno.test("created → every subscription variant resolves to managed + 300 credits", async () => {
  for (const variant of [101, 201, 202, 9999]) {
    const store = new InMemoryWebhookStore();
    await deliver(store, "subscription_created", subPayload({ id: `ls_${variant}`, variant_id: variant }));
    const s = store.sub(`ls_${variant}`)!;
    assertEquals(s.tier, "managed", `variant ${variant} → managed`);
    assertEquals(s.credits_limit, 300);
  }
});

Deno.test("created → billing_interval from the matched variant (monthly vs yearly, same managed tier)", async () => {
  // 201 = Managed monthly, 202 = Managed yearly (test_setup): SAME tier + 300
  // credits, only the interval flag differs (F1 — yearly is NOT 12×300 up front).
  const cases: [number, string][] = [[201, "monthly"], [202, "yearly"]];
  for (const [variant, interval] of cases) {
    const store = new InMemoryWebhookStore();
    await deliver(store, "subscription_created", subPayload({ id: `ls_${variant}`, variant_id: variant }));
    const s = store.sub(`ls_${variant}`)!;
    assertEquals(s.tier, "managed");
    assertEquals(s.credits_limit, 300);
    assertEquals(s.billing_interval, interval, `variant ${variant} → ${interval}`);
    // One period, one 300-credit allowance — identical for both intervals.
    assertEquals(store.periodsFor(s.id).length, 1);
  }
});

Deno.test("created with an unrecognized variant → still managed, billing_interval monthly", async () => {
  // No per-tier variant lists anymore: an unrecognized subscription variant is
  // managed like any other, and (being a present, non-yearly variant) records
  // monthly. The interval-unknown null case is now only a MISSING variant id
  // (covered in tier_test.ts).
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 9999 }));
  const s = store.sub("ls_1")!;
  assertEquals(s.tier, "managed");
  assertEquals(s.billing_interval, "monthly");
});

// ===========================================================================
// §A-01 — fail loud on an unsafe yearly-variant config (launch blocker)
// ===========================================================================
// The check is PURE, so a test drives the verdict by injecting `configCheck`.
// (The production default is the module-level check over the real env, exercised
// implicitly green by every other test via test_setup.ts's valid config.)
const BAD_CONFIG = {
  ok: false,
  code: "config_yearly_variants_empty",
  message: "test: LS_VARIANT_YEARLY unsafe",
} as const;

/** Deliver a validly-signed webhook under an INJECTED (bad) config verdict. */
async function deliverBadConfig(store: InMemoryWebhookStore, eventName: string, payload: unknown) {
  const raw = JSON.stringify(payload);
  const signature = await sign(raw);
  return await handleWebhook(raw, signature, eventName, { ...deps(store), configCheck: BAD_CONFIG });
}

Deno.test("A-01: bad config → subscription_created 500'd, nothing written, idempotency untouched", async () => {
  const store = new InMemoryWebhookStore();
  const res = await deliverBadConfig(store, "subscription_created", subPayload());
  assertEquals(res.status, 500);
  assert(res.body.includes(BAD_CONFIG.code)); // distinct error code surfaced in the body
  assertEquals(store.subs.length, 0); // never persisted with a guessed interval
  assertEquals(store.events.size, 0); // idempotency ledger untouched → an LS retry re-processes
});

Deno.test("A-01: bad config → subscription_updated 500'd (it also writes billing_interval)", async () => {
  const store = new InMemoryWebhookStore();
  const res = await deliverBadConfig(store, "subscription_updated", subPayload());
  assertEquals(res.status, 500);
  assertEquals(store.events.size, 0);
});

Deno.test("A-01: bad config does NOT over-reject config-independent events (cancel processes)", async () => {
  // A status-only event never writes billing_interval, so a yearly misconfig must
  // not block it — rejecting it would be disruption beyond surfacing the error.
  const store = new InMemoryWebhookStore();
  store.subs.push({
    id: "sub-1",
    ls_subscription_id: "ls_1",
    ls_customer_id: "5",
    email_normalized: null,
    ls_order_id: "order_1",
    tier: "managed",
    status: "active",
    current_period_end: null,
    credits_limit: 300,
    billing_interval: "monthly",
    ls_updated_at: "2026-06-02T00:00:00.000Z",
    license_key_hash: null,
  });
  const res = await deliverBadConfig(
    store,
    "subscription_cancelled",
    subPayload({ status: "cancelled", updated_at: "2026-06-04T00:00:00.000Z" }),
  );
  assertEquals(res.status, 200); // processed, not 500'd
  assertEquals(store.sub("ls_1")!.status, "cancelled");
});

Deno.test("A-01: unrecognized variant under a VALID config → monthly + an unrecognized_variant warn", async () => {
  // Config is correct (test_setup: yearly ⊆ managed), but variant 9999 is in
  // NEITHER list → resolves to monthly AND emits the per-event warn so a future
  // new variant can't silently mislabel.
  const warnings: string[] = [];
  const origWarn = console.warn;
  console.warn = (...a: unknown[]) => warnings.push(String(a[0]));
  try {
    const store = new InMemoryWebhookStore();
    const res = await deliver(store, "subscription_created", subPayload({ variant_id: 9999 }));
    assertEquals(res.status, 200);
    assertEquals(store.sub("ls_1")!.billing_interval, "monthly");
    assert(warnings.some((w) => w.includes("unrecognized_variant") && w.includes("9999")));
  } finally {
    console.warn = origWarn;
  }
});

Deno.test("A-01: a STALE subscription_created with an unrecognized variant does NOT warn (dropped event)", async () => {
  // The warn must only fire for events we actually persist — an out-of-order
  // redelivery (older updated_at) is dropped as stale, so it should be silent
  // (symmetry with subscription_updated, which warns after the stale guard).
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 101, updated_at: "2026-06-05T00:00:00.000Z" }));
  const warnings: string[] = [];
  const origWarn = console.warn;
  console.warn = (...a: unknown[]) => warnings.push(String(a[0]));
  try {
    // Older updated_at than what we hold → stale → dropped before the warn.
    const res = await deliver(
      store,
      "subscription_created",
      subPayload({ variant_id: 9999, updated_at: "2026-06-01T00:00:00.000Z" }),
    );
    assertEquals(res.status, 200);
    assertEquals(warnings.filter((w) => w.includes("unrecognized_variant")).length, 0);
  } finally {
    console.warn = origWarn;
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

Deno.test("updated → managed tier + limit refreshed, current period unchanged", async () => {
  // Single tier now, so subscription_updated never changes the tier; it still
  // refreshes credits_limit/interval and leaves the open period untouched.
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 101 }));
  store.periodsFor("sub-1")[0].credits_used = 25;

  await deliver(store, "subscription_updated", subPayload({ variant_id: 201, updated_at: "2026-06-03T00:00:00.000Z" }));
  const s = store.sub("ls_1")!;
  assertEquals(s.tier, "managed");
  assertEquals(s.credits_limit, 300); // managed allowance (applies next period)
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
// order_created → top-up packs (Phase 5)
// ===========================================================================
function orderPayload(over: {
  orderId?: string;
  variant_id?: number;
  customer_id?: number;
  status?: string;
  created_at?: string;
  updated_at?: string;
} = {}) {
  return {
    meta: { event_name: "order_created" },
    data: {
      type: "orders",
      id: over.orderId ?? "topup_order_1",
      attributes: {
        customer_id: over.customer_id ?? 5, // subPayload's customer
        status: over.status ?? "paid",
        first_order_item: { product_id: 30, variant_id: over.variant_id ?? 301 },
        created_at: over.created_at ?? "2026-06-15T00:00:00.000Z",
        updated_at: over.updated_at ?? "2026-06-15T00:00:00.000Z",
      },
    },
  };
}

/** A store with one active subscription for customer 5 (the top-up buyer). */
async function storeWithActiveSub(): Promise<InMemoryWebhookStore> {
  const store = new InMemoryWebhookStore();
  await deliver(store, "subscription_created", subPayload({ variant_id: 201 }));
  return store;
}

Deno.test("order_created (Boost) → one topup row: 200 credits, 12-month expiry, buyer's sub", async () => {
  const store = await storeWithActiveSub();
  const res = await deliver(store, "order_created", orderPayload({ variant_id: 301 }));
  assertEquals(res.status, 200);
  assertEquals(store.topups.length, 1);
  const t = store.topups[0];
  assertEquals(t.subscription_id, "sub-1"); // attached via ls_customer_id 5
  assertEquals(t.credits_total, 200);
  assertEquals(t.ls_order_id, "topup_order_1");
  assertEquals(t.expires_at, "2027-06-15T00:00:00.000Z"); // purchase + 12 months
});

Deno.test("order_created (Power) → 500 credits", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload({ variant_id: 302, orderId: "topup_order_2" }));
  assertEquals(store.topups.length, 1);
  assertEquals(store.topups[0].credits_total, 500);
});

Deno.test("redelivered top-up order (exact) → deduped by the composite event key, one row", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload());
  const r2 = await deliver(store, "order_created", orderPayload()); // exact redelivery
  assertEquals(r2.body, "ok (duplicate)");
  assertEquals(store.topups.length, 1);
});

Deno.test("same order with a DIFFERENT updated_at → second dedupe layer (ls_order_id) holds, one row", async () => {
  // A changed updated_at gives a fresh composite event id, so recordEvent lets
  // it through — the topup_credits.ls_order_id unique is what must stop it.
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload());
  const r2 = await deliver(store, "order_created", orderPayload({ updated_at: "2026-06-15T01:00:00.000Z" }));
  assertEquals(r2.status, 200); // handled, but credited nothing
  assertEquals(store.topups.length, 1);
});

Deno.test("order_created for a NON-top-up variant → ignored, nothing written", async () => {
  const store = await storeWithActiveSub();
  const res = await deliver(store, "order_created", orderPayload({ variant_id: 777 }));
  assertEquals(res.status, 200);
  assertEquals(store.topups.length, 0);
});

Deno.test("top-up with NO active subscription for the customer → no row (logged, 200)", async () => {
  // BYOK-only / trial buyer edge case: nothing to attach the pack to.
  const store = new InMemoryWebhookStore(); // no subscription at all
  const res = await deliver(store, "order_created", orderPayload());
  assertEquals(res.status, 200);
  assertEquals(store.topups.length, 0);
});

Deno.test("top-up for a cancelled/expired subscription → no row (status not spendable)", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "subscription_expired", subPayload({ status: "expired", updated_at: "2026-06-10T00:00:00.000Z" }));
  await deliver(store, "order_created", orderPayload());
  assertEquals(store.topups.length, 0);
});

Deno.test("top-up order with a non-paid status → no row", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload({ status: "pending" }));
  assertEquals(store.topups.length, 0);
});

// ===========================================================================
// order_refunded → top-up revocation (Phase 5 follow-up)
// ===========================================================================
function refundPayload(orderId: string, updatedAt = "2026-06-20T00:00:00.000Z") {
  return {
    meta: { event_name: "order_refunded" },
    data: { type: "orders", id: orderId, attributes: { updated_at: updatedAt } },
  };
}

Deno.test("refund after PARTIAL spend → remainder revoked, spent portion intact, sub untouched", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload()); // Boost 200
  store.topups[0].credits_used = 50; // 150 unspent

  await deliver(store, "order_refunded", refundPayload("topup_order_1"));
  const t = store.topups[0];
  // Revocation = expiry at the refund moment (the spend/balance paths filter
  // expires_at > now()): nothing further spendable, counters untouched — the
  // 50 spent stay spent (no claw-back), the 150 remainder is dead.
  assertEquals(t.expires_at, NOW_ISO);
  assertEquals(t.credits_used, 50);
  assertEquals(t.credits_total, 200);
  // A top-up refund must NOT expire the SUBSCRIPTION (either/or by order id).
  assertEquals(store.sub("ls_1")!.status, "active");
});

Deno.test("refund of a fully-unspent pack → revoked (expired), counters untouched", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload());

  await deliver(store, "order_refunded", refundPayload("topup_order_1"));
  const t = store.topups[0];
  assertEquals(t.expires_at, NOW_ISO);
  assertEquals(t.credits_used, 0);
  assertEquals(t.credits_total, 200);
});

Deno.test("refund of an UNKNOWN order id → no-op (no pack touched, no sub expired)", async () => {
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload());

  const res = await deliver(store, "order_refunded", refundPayload("some_other_order"));
  assertEquals(res.status, 200);
  assertEquals(store.topups[0].expires_at, "2027-06-15T00:00:00.000Z"); // untouched
  assertEquals(store.sub("ls_1")!.status, "active"); // order_X path also unmatched
});

Deno.test("redelivered top-up refund (different updated_at) → already-revoked pack is a no-op", async () => {
  // A changed updated_at gives a fresh composite event id (recordEvent lets it
  // through); the expires_at > revokedAt guard returns 0 the second time and the
  // fall-through subscription path matches nothing.
  const store = await storeWithActiveSub();
  await deliver(store, "order_created", orderPayload());
  await deliver(store, "order_refunded", refundPayload("topup_order_1"));
  const r2 = await deliver(store, "order_refunded", refundPayload("topup_order_1", "2026-06-21T00:00:00.000Z"));
  assertEquals(r2.status, 200);
  assertEquals(store.topups[0].expires_at, NOW_ISO); // still the first stamp
  assertEquals(store.sub("ls_1")!.status, "active"); // fall-through expired nothing
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
