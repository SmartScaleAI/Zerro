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
  rows: { ipHash: string; affCode: string; at: number }[] = [];
  recordCalls = 0;
  // deno-lint-ignore require-await
  async record(ipHash: string, affCode: string): Promise<void> {
    this.recordCalls++;
    this.rows.push({ ipHash, affCode, at: this.rows.length });
  }
  // deno-lint-ignore require-await
  async latestCode(ipHash: string): Promise<string | null> {
    const matches = this.rows.filter((r) => r.ipHash === ipHash);
    return matches.length ? matches[matches.length - 1].affCode : null;
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
