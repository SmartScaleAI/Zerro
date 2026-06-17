// =============================================================================
// session/handler_test.ts — the §14.6 missed-webhook staleness re-check + the
// session credential-exchange behaviors (Phase G).
// =============================================================================
// Stubbed store + stub LemonSqueezy client; no Postgres, no network, no mint of
// a real token against a real secret beyond the HS256 round-trip. Proves:
//   - a fresh mirror mints WITHOUT a live LS call (cost bound)
//   - a stale + still-active mirror mints AND reconciles freshness
//   - a stale + LIVE-cancelled mirror is REVOKED (403) even though the local
//     mirror still says active — the dropped-webhook catch
//   - a stale + inconclusive (LS down) mirror FAILS OPEN (mints)
//   - a stale mirror with the guard DISABLED (no LS client) fails open
//   - terminal mirror status (cancelled/expired) → 403 before any LS call
//   - past_due still gets a token (§9.1); rate limit → 429
// =============================================================================

import { assert, assertEquals } from "jsr:@std/assert@1";
import { verifySessionToken } from "../_shared/jwt.ts";
import { handleSession, type SessionDeps } from "./handler.ts";
import type { SessionStore, SessionSubRow } from "./store.ts";
import type { EntitlementSnapshot } from "../_shared/types.ts";
import type { LemonSqueezyClient, LsLiveStatus } from "../_shared/lemonsqueezy.ts";
import { sha256Hex } from "../_shared/crypto.ts";

const SECRET = "test_session_jwt_secret";
const NOW_MS = 1_000_000_000_000; // fixed wall clock (ms)
const NOW_S = Math.floor(NOW_MS / 1000);
const KEY = "TESTKEY-1234-ABCD-EFGH";

// ---- In-memory SessionStore -------------------------------------------------
class InMemoryStore implements SessionStore {
  sub: SessionSubRow | null = null;
  reconciled: { id: string; status: SessionSubRow["status"] }[] = [];
  rateOk = true;
  creditsRemaining = 73;

  rateLimitOk() {
    return Promise.resolve(this.rateOk);
  }
  findByKeyHash(_keyHash: string) {
    return Promise.resolve(this.sub);
  }
  reconcileStatus(id: string, status: SessionSubRow["status"]) {
    this.reconciled.push({ id, status });
    if (this.sub && this.sub.id === id) this.sub = { ...this.sub, status };
    return Promise.resolve();
  }
  buildSnapshot(sub: SessionSubRow): Promise<EntitlementSnapshot> {
    return Promise.resolve({
      tier: sub.tier,
      status: sub.status,
      credits_remaining: this.creditsRemaining, // combined plan+topup (Phase 4)
      credits_limit: sub.credits_limit,
      reset_date: sub.current_period_end,
      plan_credits_used: sub.credits_limit - this.creditsRemaining,
      plan_credits_limit: sub.credits_limit,
      topup_credits_remaining: 0,
    });
  }
}

// ---- Stub LemonSqueezy client ----------------------------------------------
class StubLs implements LemonSqueezyClient {
  calls = 0;
  reply: LsLiveStatus | null = "active";
  getSubscriptionStatus(_id: string): Promise<LsLiveStatus | null> {
    this.calls++;
    return Promise.resolve(this.reply);
  }
}

// ---- helpers ----------------------------------------------------------------
function seed(store: InMemoryStore, over: Partial<SessionSubRow> = {}) {
  store.sub = {
    id: "sub-1",
    ls_subscription_id: "ls_999",
    tier: "managed",
    status: "active",
    credits_limit: 100,
    current_period_end: "2026-07-01T00:00:00.000Z",
    updated_at: new Date(NOW_MS).toISOString(), // FRESH by default
    ...over,
  };
}

function req(body: unknown = { license_key: KEY }) {
  return new Request("http://local/session", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-forwarded-for": "203.0.113.5" },
    body: JSON.stringify(body),
  });
}

function deps(store: InMemoryStore, ls: LemonSqueezyClient | null, over: Partial<SessionDeps> = {}): SessionDeps {
  return { store, jwtSecret: SECRET, ls, nowMs: NOW_MS, nowSeconds: NOW_S, staleSeconds: 1800, ...over };
}

const STALE = new Date(NOW_MS - 3600_000).toISOString(); // 1h old > 30m window

// ---- fresh mirror: no live call ---------------------------------------------
Deno.test("fresh mirror → mints a token WITHOUT any live LemonSqueezy call", async () => {
  const store = new InMemoryStore();
  seed(store); // updated_at = now → fresh
  const ls = new StubLs();
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 200);
  assertEquals(ls.calls, 0); // freshness anchor skips the call (cost bound)
  assertEquals(store.reconciled.length, 0);
  const json = await res.json();
  const claims = await verifySessionToken(json.token, SECRET, NOW_S + 1);
  assert(claims);
  assertEquals(claims!.sub, "sub-1");
  assertEquals(claims!.kind, "subscription");
});

// ---- stale + still active: live confirm + reconcile, mint -------------------
Deno.test("stale mirror, LS says active → live call made, mirror reconciled, mints", async () => {
  const store = new InMemoryStore();
  seed(store, { updated_at: STALE });
  const ls = new StubLs();
  ls.reply = "active";
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 200);
  assertEquals(ls.calls, 1); // stale → one live re-check
  assertEquals(store.reconciled, [{ id: "sub-1", status: "active" }]); // freshness reset
});

// ---- THE MONEY-LEAK CATCH: stale + LIVE-cancelled → revoke ------------------
Deno.test("stale mirror still says active but LS says cancelled → 403, mirror revoked, NO token", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "active", updated_at: STALE }); // dropped cancelled webhook
  const ls = new StubLs();
  ls.reply = "cancelled";
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 403);
  assertEquals((await res.json()).error, "not_entitled");
  assertEquals(ls.calls, 1);
  // The mirror was reconciled to the live terminal status, so future requests
  // 403 immediately (before any further live call).
  assertEquals(store.reconciled, [{ id: "sub-1", status: "cancelled" }]);
});

Deno.test("stale mirror, LS says expired → 403, mirror revoked", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "active", updated_at: STALE });
  const ls = new StubLs();
  ls.reply = "expired";
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 403);
  assertEquals(store.reconciled, [{ id: "sub-1", status: "expired" }]);
});

// ---- reconcile a missed payment_failed: stale active → LS past_due ----------
Deno.test("stale mirror active, LS says past_due → mints (past_due still works), reconciled", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "active", updated_at: STALE });
  const ls = new StubLs();
  ls.reply = "past_due";
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 200); // past_due keeps a token (§9.1)
  assertEquals(store.reconciled, [{ id: "sub-1", status: "past_due" }]);
  const json = await res.json();
  assertEquals(json.entitlement.status, "past_due");
});

// ---- FAIL OPEN on inconclusive (LS down) ------------------------------------
Deno.test("stale mirror, LS inconclusive (null) → FAIL OPEN, mints with existing status, no reconcile", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "active", updated_at: STALE });
  const ls = new StubLs();
  ls.reply = null; // LS outage / bad key / parse fail
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 200); // an LS outage must NOT lock out a paying user
  assertEquals(ls.calls, 1);
  assertEquals(store.reconciled.length, 0); // nothing reconciled on inconclusive
});

// ---- guard disabled (no LS client) → fail open ------------------------------
Deno.test("stale mirror, staleness guard DISABLED (ls=null) → fail open, mints", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "active", updated_at: STALE });
  const res = await handleSession(req(), deps(store, null));
  assertEquals(res.status, 200);
  assertEquals(store.reconciled.length, 0);
});

// ---- terminal mirror status short-circuits BEFORE any live call -------------
Deno.test("mirror already cancelled → 403 with no LS call", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "cancelled", updated_at: STALE });
  const ls = new StubLs();
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 403);
  assertEquals(ls.calls, 0); // terminal status is decided without LS
});

Deno.test("unknown key → 403", async () => {
  const store = new InMemoryStore();
  store.sub = null;
  const ls = new StubLs();
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 403);
  assertEquals(ls.calls, 0);
});

// ---- past_due (already in the mirror) still gets a token --------------------
Deno.test("mirror past_due (fresh) → still mints a token (§9.1)", async () => {
  const store = new InMemoryStore();
  seed(store, { status: "past_due" }); // fresh
  const ls = new StubLs();
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 200);
  assertEquals(ls.calls, 0);
});

// ---- rate limiting ----------------------------------------------------------
Deno.test("rate limited → 429, no key lookup needed", async () => {
  const store = new InMemoryStore();
  seed(store);
  store.rateOk = false;
  const ls = new StubLs();
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 429);
});

// ---- input validation -------------------------------------------------------
Deno.test("missing license_key → 400", async () => {
  const store = new InMemoryStore();
  const ls = new StubLs();
  const res = await handleSession(req({}), deps(store, ls));
  assertEquals(res.status, 400);
});

Deno.test("non-POST → 405", async () => {
  const store = new InMemoryStore();
  const ls = new StubLs();
  const res = await handleSession(
    new Request("http://local/session", { method: "GET" }),
    deps(store, ls),
  );
  assertEquals(res.status, 405);
});

// ---- never-stamped updated_at is treated as stale ---------------------------
Deno.test("null updated_at → treated as stale → live re-check runs", async () => {
  const store = new InMemoryStore();
  seed(store, { updated_at: null });
  const ls = new StubLs();
  ls.reply = "active";
  const res = await handleSession(req(), deps(store, ls));
  assertEquals(res.status, 200);
  assertEquals(ls.calls, 1);
  // sanity: the key hash is what the store would be queried by (not asserted by
  // the in-memory fake, but compute it to document the contract).
  assert((await sha256Hex(KEY)).length === 64);
});
