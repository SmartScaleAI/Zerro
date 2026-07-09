// Tests for the affiliate handler. The pure helpers (IP extraction, code
// validation) carry the real risk, so they're covered exhaustively; the
// record/lookup flow is exercised end-to-end against an in-memory fake store.

import { assertEquals } from "jsr:@std/assert@1";
import {
  type AffiliateStore,
  clientIp,
  handleAffiliate,
  normalizeAffCode,
} from "./handler.ts";

Deno.test("clientIp: first XFF hop wins", () => {
  const h = new Headers({ "x-forwarded-for": "203.0.113.7, 70.41.3.18, 150.172.238.178" });
  assertEquals(clientIp(h), "203.0.113.7");
});

Deno.test("clientIp: falls back to x-real-ip", () => {
  assertEquals(clientIp(new Headers({ "x-real-ip": "198.51.100.9" })), "198.51.100.9");
});

Deno.test("clientIp: null when no IP headers", () => {
  assertEquals(clientIp(new Headers()), null);
});

Deno.test("normalizeAffCode: accepts URL-safe codes, trims", () => {
  assertEquals(normalizeAffCode("ZylBs"), "ZylBs");
  assertEquals(normalizeAffCode("  abc_123-XYZ  "), "abc_123-XYZ");
});

Deno.test("normalizeAffCode: rejects junk / unsafe / empty / overlong", () => {
  assertEquals(normalizeAffCode(""), null);
  assertEquals(normalizeAffCode("   "), null);
  assertEquals(normalizeAffCode("has space"), null);
  assertEquals(normalizeAffCode("inject';--"), null);
  assertEquals(normalizeAffCode("a".repeat(65)), null);
  assertEquals(normalizeAffCode(1234), null);
  assertEquals(normalizeAffCode(null), null);
});

// ---- end-to-end flow against a fake store -------------------------------------

class FakeStore implements AffiliateStore {
  /** One row per ip_hash — models the C-08 unique(ip_hash) upsert semantics
   * (latest code + timestamp win), exactly like the production table. */
  rows = new Map<string, { affCode: string; createdAtMs: number }>();
  recordCalls = 0;
  /** Per-key call counts — rateLimitOk models a real fixed-window counter
   * (the window is ignored: every test runs inside a single window). */
  rateCounts = new Map<string, number>();
  // deno-lint-ignore require-await
  async record(ipHash: string, affCode: string): Promise<void> {
    this.recordCalls++;
    this.rows.set(ipHash, { affCode, createdAtMs: Date.now() });
  }
  // deno-lint-ignore require-await
  async latestCode(ipHash: string, sinceISO: string): Promise<string | null> {
    const row = this.rows.get(ipHash);
    if (!row) return null;
    return row.createdAtMs >= Date.parse(sinceISO) ? row.affCode : null;
  }
  // deno-lint-ignore require-await
  async rateLimitOk(key: string, max: number): Promise<boolean> {
    const n = (this.rateCounts.get(key) ?? 0) + 1;
    this.rateCounts.set(key, n);
    return n <= max;
  }
}

const deps = (store: AffiliateStore) => ({ store, salt: "test-salt", windowHours: 720 });
const ipHeaders = { "x-forwarded-for": "203.0.113.7" };

Deno.test("POST records, GET returns the matched code (same IP)", async () => {
  const store = new FakeStore();

  const post = await handleAffiliate(
    new Request("https://x/affiliate", {
      method: "POST",
      headers: ipHeaders,
      body: JSON.stringify({ aff: "ZylBs" }),
    }),
    deps(store),
  );
  assertEquals(post.status, 200);
  assertEquals(await post.json(), { ok: true });
  assertEquals(store.recordCalls, 1);

  const get = await handleAffiliate(
    new Request("https://x/affiliate", { method: "GET", headers: ipHeaders }),
    deps(store),
  );
  assertEquals(await get.json(), { aff_ref: "ZylBs" });
});

Deno.test("GET from a different IP does not match", async () => {
  const store = new FakeStore();
  await handleAffiliate(
    new Request("https://x/affiliate", {
      method: "POST",
      headers: ipHeaders,
      body: JSON.stringify({ aff: "ZylBs" }),
    }),
    deps(store),
  );
  const get = await handleAffiliate(
    new Request("https://x/affiliate", {
      method: "GET",
      headers: { "x-forwarded-for": "8.8.8.8" },
    }),
    deps(store),
  );
  assertEquals(await get.json(), { aff_ref: null });
});

Deno.test("POST with bad aff code is rejected, nothing recorded", async () => {
  const store = new FakeStore();
  const res = await handleAffiliate(
    new Request("https://x/affiliate", {
      method: "POST",
      headers: ipHeaders,
      body: JSON.stringify({ aff: "no good!" }),
    }),
    deps(store),
  );
  assertEquals(res.status, 400);
  assertEquals(store.recordCalls, 0);
});

Deno.test("GET with no IP returns no match (never errors)", async () => {
  const store = new FakeStore();
  const res = await handleAffiliate(
    new Request("https://x/affiliate", { method: "GET" }),
    deps(store),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { aff_ref: null });
});

// ---- C-08: upsert dedup + per-IP throttle -------------------------------------

const post = (store: AffiliateStore, aff: string) =>
  handleAffiliate(
    new Request("https://x/affiliate", {
      method: "POST",
      headers: ipHeaders,
      body: JSON.stringify({ aff }),
    }),
    deps(store),
  );

Deno.test("POST: repeated same-code posts from one IP dedup to exactly 1 row (C-08)", async () => {
  const store = new FakeStore();
  for (let i = 0; i < 5; i++) {
    const res = await post(store, "ZylBs");
    assertEquals(await res.json(), { ok: true });
  }
  // The old plain-insert amplifier would have 5 rows here.
  assertEquals(store.rows.size, 1);
  assertEquals(store.recordCalls, 5); // every call wrote — into the SAME row
});

Deno.test("POST: different codes from one IP → still 1 row, latest code wins (C-08)", async () => {
  const store = new FakeStore();
  await post(store, "first");
  await post(store, "second");
  await post(store, "third");
  assertEquals(store.rows.size, 1);
  const get = await handleAffiliate(
    new Request("https://x/affiliate", { method: "GET", headers: ipHeaders }),
    deps(store),
  );
  assertEquals(await get.json(), { aff_ref: "third" });
});

Deno.test("GET: matches inside the attribution window, null outside it", async () => {
  const store = new FakeStore();
  await post(store, "ZylBs");
  // Age the stored row to 10h old: a 24h window still matches, a 1h window
  // must not (the row exists but is stale — sinceISO filters it out).
  const key = [...store.rows.keys()][0];
  store.rows.get(key)!.createdAtMs = Date.now() - 10 * 3_600_000;

  const within = await handleAffiliate(
    new Request("https://x/affiliate", { method: "GET", headers: ipHeaders }),
    { store, salt: "test-salt", windowHours: 24 },
  );
  assertEquals(await within.json(), { aff_ref: "ZylBs" });

  const outside = await handleAffiliate(
    new Request("https://x/affiliate", { method: "GET", headers: ipHeaders }),
    { store, salt: "test-salt", windowHours: 1 },
  );
  assertEquals(await outside.json(), { aff_ref: null });
});

Deno.test("POST: per-IP throttle caps writes; over-cap response is still { ok: true } (C-08)", async () => {
  const store = new FakeStore();
  // AFFILIATE_RATE_LIMIT_PER_IP default 20: 25 posts → only 20 reach record(),
  // yet EVERY response is the same best-effort ok (the throttle never
  // surfaces to the landing page and can't be probed).
  for (let i = 0; i < 25; i++) {
    const res = await post(store, `code${i}`);
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true });
  }
  assertEquals(store.recordCalls, 20);
  // The stored row carries the last code that made it through the throttle.
  const key = [...store.rows.keys()][0];
  assertEquals(store.rows.get(key)!.affCode, "code19");
});
