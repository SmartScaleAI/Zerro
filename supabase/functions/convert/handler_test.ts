import "./test_setup.ts"; // MUST be first — sets test env before config.ts loads.

// =============================================================================
// handler_test.ts — the convert handler's gates and flow (Phase 6). Mirrors
// generate's handler tests for auth / method / size / validation / rate-limit
// / provider-error mapping — minus ALL billing (no credits, no slot, no
// idempotency, no generation_log on this endpoint, by design).
// =============================================================================

import { assert, assertEquals } from "jsr:@std/assert@1";
import { signSessionToken } from "../_shared/jwt.ts";
import { type ConvertDeps, type ConvertStore, handleConvert } from "./handler.ts";
import { conversionSystemPrompt } from "./prompt.ts";
import { CHEAPEST_ENABLED_MODEL_ID, DEFAULT_MODEL_ID } from "../generate/models.ts";
import { PROVIDER_TIMEOUT_MS, slotStaleSeconds } from "../generate/config.ts";
import { CONVERT_SLOT_STALE_SECONDS } from "./config.ts";
import { SlotTable } from "../_shared/slot_table_fake.ts";
import type { IdempotentResult, TrialGrantRow } from "../generate/store.ts";
import {
  type ChatClient,
  type ChatResult,
  ProviderError,
  type TimelineBlock,
} from "../generate/providers/types.ts";

const SECRET = "test_session_jwt_secret";
const NOW = 1_000_000;

// ---- Fakes ------------------------------------------------------------------

class FakeChat implements ChatClient {
  calls: { systemPrompt: string; content: TimelineBlock[] }[] = [];
  result: ChatResult = {
    provider: "gemini",
    content: '<<<ZERRO_ARTIFACT type="agent_prompt" title="T">>>\nbody\n<<<END_ZERRO_ARTIFACT>>>',
    inputTokens: 100,
    outputTokens: 50,
    model: "gemini-3.5-flash",
  };
  fail: ProviderError | Error | null = null;

  chat(systemPrompt: string, content: TimelineBlock[]): Promise<ChatResult> {
    this.calls.push({ systemPrompt, content });
    if (this.fail) return Promise.reject(this.fail);
    return Promise.resolve(this.result);
  }
}

// In-memory ConvertStore — only the trial-metering bits exercise the credit
// path; a subscription request touches just rateLimitOk. Mirrors the shape of
// generate's InMemoryStore (the production SupabaseBillingStore satisfies both).
interface TrialGrantState {
  verified: boolean;
  limit: number;
  used: number;
}

class ConvertInMemoryStore implements ConvertStore {
  rateOk = true;
  rateCalls: { key: string; max: number; windowSeconds: number }[] = [];
  trialGrants = new Map<string, TrialGrantState>();
  trialSlots = new SlotTable(); // honors staleSeconds (B-09), not a bare Set
  acquireTrialSlotCalls = 0;
  consumeCalls = 0;
  idempotent = new Map<string, IdempotentResult>();
  forceLoadThrow = false;
  forceCreditsThrow = false;
  forceConsumeThrow = false;

  seedTrial(id: string, g: Partial<TrialGrantState> = {}) {
    this.trialGrants.set(id, { verified: true, limit: 30, used: 0, ...g });
  }
  used(id: string): number {
    return this.trialGrants.get(id)?.used ?? 0;
  }

  rateLimitOk(key: string, max: number, windowSeconds: number) {
    this.rateCalls.push({ key, max, windowSeconds });
    return Promise.resolve(this.rateOk);
  }
  loadTrialGrant(id: string): Promise<TrialGrantRow | null> {
    if (this.forceLoadThrow) return Promise.reject(new Error("db down"));
    const g = this.trialGrants.get(id);
    if (!g) return Promise.resolve(null);
    return Promise.resolve({
      id,
      verified_at: g.verified ? "2026-06-02T00:00:00.000Z" : null,
      trial_credits_limit: g.limit,
      trial_credits_used: g.used,
    });
  }
  trialCreditsRemaining(id: string) {
    if (this.forceCreditsThrow) return Promise.reject(new Error("db down"));
    const g = this.trialGrants.get(id);
    return Promise.resolve(g ? Math.max(0, g.limit - g.used) : 0);
  }
  // X-02: active dev call-1 holds on the grant (generate places them; convert
  // only observes them in its floor gate). Seed `heldCredits` to simulate a
  // pending dev settle. Every excludeKey the handler passes is recorded so the
  // no-own-key-exclusion contract is pinnable (convert must always pass null —
  // it never settles a hold, so no hold is "its own" to spend).
  heldCredits = 0;
  holdExcludeKeys: (string | null)[] = [];
  forceHoldsThrow = false;
  activeHoldCredits(_subId: string | null, _grantId: string | null, excludeKey: string | null) {
    this.holdExcludeKeys.push(excludeKey);
    if (this.forceHoldsThrow) return Promise.reject(new Error("holds read down"));
    return Promise.resolve(this.heldCredits);
  }
  consumeTrialCredit(id: string, credits: number): Promise<number | null> {
    this.consumeCalls++;
    if (this.forceConsumeThrow) return Promise.reject(new Error("rpc down"));
    const g = this.trialGrants.get(id);
    if (!g || !g.verified) return Promise.resolve(null);
    g.used += credits; // overspend overload: always spends (may go negative)
    return Promise.resolve(g.limit - g.used);
  }
  acquireTrialSlot(id: string, staleSeconds: number) {
    this.acquireTrialSlotCalls++;
    return Promise.resolve(this.trialSlots.acquire(id, staleSeconds));
  }
  releaseTrialSlot(id: string) {
    this.trialSlots.release(id);
    return Promise.resolve();
  }
  getIdempotent(identityKey: string, idemKey: string, _ttl: number) {
    return Promise.resolve(this.idempotent.get(`${identityKey}::${idemKey}`) ?? null);
  }
  putIdempotent(identityKey: string, idemKey: string, value: IdempotentResult, _ttl: number) {
    this.idempotent.set(`${identityKey}::${idemKey}`, value);
    return Promise.resolve();
  }
}

interface Harness {
  deps: ConvertDeps;
  chat: FakeChat;
  store: ConvertInMemoryStore;
  rateCalls: { key: string; max: number; windowSeconds: number }[];
  makeChatCalls: { provider: string; model: string }[];
  setRateOk(ok: boolean): void;
  setMakeChatThrows(): void;
}

function makeHarness(): Harness {
  const chat = new FakeChat();
  let makeChatThrows = false;
  const makeChatCalls: Harness["makeChatCalls"] = [];
  const store = new ConvertInMemoryStore();
  const deps: ConvertDeps = {
    store,
    makeChat: (provider, model) => {
      makeChatCalls.push({ provider, model });
      if (makeChatThrows) throw new Error("PROVIDER_API_KEY unset");
      return chat;
    },
    jwtSecret: SECRET,
    nowSeconds: NOW,
  };
  return {
    deps,
    chat,
    store,
    rateCalls: store.rateCalls,
    makeChatCalls,
    setRateOk: (ok) => {
      store.rateOk = ok;
    },
    setMakeChatThrows: () => {
      makeChatThrows = true;
    },
  };
}

async function subToken(sub = "sub_1"): Promise<string> {
  const { token } = await signSessionToken({ sub, tier: "managed" }, SECRET, 3600, NOW);
  return token;
}

async function trialToken(grant = "grant_1"): Promise<string> {
  const { token } = await signSessionToken({ sub: grant, kind: "trial" }, SECRET, 3600, NOW);
  return token;
}

function makeBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source_text: "The error is a stale lockfile — delete package-lock.json and reinstall.",
    context: '## Attached Context\n**Clicks:** clicked "Install"',
    ...overrides,
  };
}

function request(body: unknown, token: string | null, method = "POST", idemKey?: string): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (idemKey) headers["Idempotency-Key"] = idemKey;
  return new Request("http://localhost/convert", {
    method,
    headers,
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

// ---- Method / size gates ----------------------------------------------------

Deno.test("convert: non-POST → 405", async () => {
  const h = makeHarness();
  const res = await handleConvert(request(null, await subToken(), "GET"), h.deps);
  assertEquals(res.status, 405);
});

Deno.test("convert: oversized raw payload → 413 before parsing", async () => {
  const h = makeHarness();
  // test_setup caps CONVERT_MAX_PAYLOAD_BYTES at 50_000.
  const res = await handleConvert(
    request(makeBody({ source_text: "x".repeat(60_000) }), await subToken()),
    h.deps,
  );
  assertEquals(res.status, 413);
  assertEquals((await res.json()).error, "payload_too_large");
  assertEquals(h.chat.calls.length, 0);
});

// ---- Auth gates -------------------------------------------------------------

Deno.test("convert: missing token → 401", async () => {
  const h = makeHarness();
  const res = await handleConvert(request(makeBody(), null), h.deps);
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error, "missing_token");
});

Deno.test("convert: garbage token → 401", async () => {
  const h = makeHarness();
  const res = await handleConvert(request(makeBody(), "not.a.jwt"), h.deps);
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error, "invalid_token");
});

Deno.test("convert: expired token → 401", async () => {
  const h = makeHarness();
  const { token } = await signSessionToken({ sub: "sub_1" }, SECRET, 10, NOW - 100);
  const res = await handleConvert(request(makeBody(), token), h.deps);
  assertEquals(res.status, 401);
});

// ---- Body validation --------------------------------------------------------

Deno.test("convert: invalid JSON → 400", async () => {
  const h = makeHarness();
  const req = new Request("http://localhost/convert", {
    method: "POST",
    headers: { Authorization: `Bearer ${await subToken()}` },
    body: "{not json",
  });
  const res = await handleConvert(req, h.deps);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "invalid_body");
});

Deno.test("convert: missing / blank source_text → 400", async () => {
  const h = makeHarness();
  for (const body of [makeBody({ source_text: undefined }), makeBody({ source_text: "   " })]) {
    const res = await handleConvert(request(body, await subToken()), h.deps);
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error, "missing_source_text");
  }
});

Deno.test("convert: over-cap source_text → 413", async () => {
  const h = makeHarness();
  const res = await handleConvert(
    request(makeBody({ source_text: "x".repeat(20_001) }), await subToken()),
    h.deps,
  );
  assertEquals(res.status, 413);
  assertEquals((await res.json()).error, "source_text_too_long");
});

Deno.test("convert: over-cap context → 413; non-string context tolerated as absent", async () => {
  const h = makeHarness();
  const over = await handleConvert(
    request(makeBody({ context: "y".repeat(6_001) }), await subToken()),
    h.deps,
  );
  assertEquals(over.status, 413);
  assertEquals((await over.json()).error, "context_too_long");

  const junk = await handleConvert(
    request(makeBody({ context: { nested: true } }), await subToken()),
    h.deps,
  );
  assertEquals(junk.status, 200);
  // The chat saw the source text alone — no context appended.
  const content = h.chat.calls[0].content;
  assertEquals(content.length, 1);
  assert(content[0].type === "text" && !content[0].text.includes("Attached Context"));
});

Deno.test("convert: unknown model → 400; absent model → registry default", async () => {
  const h = makeHarness();
  const bad = await handleConvert(
    request(makeBody({ model: "gpt-1" }), await subToken()),
    h.deps,
  );
  assertEquals(bad.status, 400);
  assertEquals((await bad.json()).error, "invalid_model");

  const ok = await handleConvert(request(makeBody(), await subToken()), h.deps);
  assertEquals(ok.status, 200);
  assertEquals(h.makeChatCalls.length, 1);
  assertEquals(h.makeChatCalls[0].model, DEFAULT_MODEL_ID, "absent model resolves to the registry default");
});

Deno.test("convert: explicit model rides through to the chat factory", async () => {
  const h = makeHarness();
  const res = await handleConvert(
    request(makeBody({ model: "claude-opus-4-7" }), await subToken()),
    h.deps,
  );
  assertEquals(res.status, 200);
  assertEquals(h.makeChatCalls[0], { provider: "anthropic", model: "claude-opus-4-7" });
});

// ---- Rate limit -------------------------------------------------------------

Deno.test("convert: rate-limited identity → 429, keyed under convert: prefix", async () => {
  const h = makeHarness();
  h.setRateOk(false);
  const res = await handleConvert(request(makeBody(), await subToken("sub_9")), h.deps);
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, "rate_limited");
  assertEquals(h.rateCalls.length, 1);
  assertEquals(h.rateCalls[0].key, "convert:sub:sub_9");
  assertEquals(h.chat.calls.length, 0, "no provider call after a rate reject");
});

Deno.test("convert: trial identity rate-limits under its own key", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_7"); // a verified grant with credits so the call proceeds
  const res = await handleConvert(request(makeBody(), await trialToken("grant_7")), h.deps);
  assertEquals(res.status, 200);
  assertEquals(h.rateCalls[0].key, "convert:trial:grant_7");
});

Deno.test("convert: rate reject happens BEFORE any trial credit work", async () => {
  const h = makeHarness();
  h.setRateOk(false);
  h.store.seedTrial("grant_9");
  const res = await handleConvert(request(makeBody(), await trialToken("grant_9")), h.deps);
  assertEquals(res.status, 429);
  // No grant lookup, no slot, no charge — the limiter is the outer gate.
  assertEquals(h.store.acquireTrialSlotCalls, 0);
  assertEquals(h.store.consumeCalls, 0);
  assertEquals(h.chat.calls.length, 0);
});

// ---- Provider error mapping -------------------------------------------------

Deno.test("convert: makeChat throw (unset key) → 503 non-retryable", async () => {
  const h = makeHarness();
  h.setMakeChatThrows();
  const res = await handleConvert(request(makeBody(), await subToken()), h.deps);
  assertEquals(res.status, 503);
  const body = await res.json();
  assertEquals(body.error, "provider_unavailable");
  assertEquals(body.retryable, false);
});

Deno.test("convert: retryable provider failure → 503 retryable", async () => {
  const h = makeHarness();
  h.chat.fail = new ProviderError("gemini_503", true, 503, "gemini");
  const res = await handleConvert(request(makeBody(), await subToken()), h.deps);
  assertEquals(res.status, 503);
  const body = await res.json();
  assertEquals(body.error, "provider_unavailable");
  assertEquals(body.retryable, true);
});

Deno.test("convert: terminal provider failure → 502", async () => {
  const h = makeHarness();
  h.chat.fail = new ProviderError("gemini_400", false, 400, "gemini");
  const res = await handleConvert(request(makeBody(), await subToken()), h.deps);
  assertEquals(res.status, 502);
  assertEquals((await res.json()).error, "generation_failed");
});

Deno.test("convert: output-cap truncation → 422 (withholds partial; charges nothing for a trial)", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 0 });
  // The B-04 output cap makes this reachable; mirror generate's distinct mapping.
  h.chat.fail = new ProviderError("gemini_truncated: MAX_TOKENS", false, 200, "gemini", true);
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 422);
  assertEquals((await res.json()).error, "response_truncated");
  assertEquals(h.store.used("grant_1"), 0, "a truncated conversion charges nothing");
});

Deno.test("convert: unexpected (non-provider) failure → 500", async () => {
  const h = makeHarness();
  h.chat.fail = new Error("boom");
  const res = await handleConvert(request(makeBody(), await subToken()), h.deps);
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error, "server_error");
});

// ---- Happy path -------------------------------------------------------------

Deno.test("convert: success returns the raw fenced text pass-through", async () => {
  const h = makeHarness();
  const res = await handleConvert(request(makeBody(), await subToken()), h.deps);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.prompt, h.chat.result.content);
  // Pass-through means EXACTLY { prompt } — no usage, no credit fields.
  assertEquals(Object.keys(body), ["prompt"]);
});

Deno.test("convert: chat sees the server-owned conversion prompt and one text block", async () => {
  const h = makeHarness();
  await handleConvert(request(makeBody(), await subToken()), h.deps);
  const call = h.chat.calls[0];
  assertEquals(call.systemPrompt, conversionSystemPrompt());
  assertEquals(call.content.length, 1);
  const block = call.content[0];
  assert(block.type === "text");
  // source text, blank line, then the context block.
  assertEquals(
    block.text,
    'The error is a stale lockfile — delete package-lock.json and reinstall.\n\n## Attached Context\n**Clicks:** clicked "Install"',
  );
});

// ---- Trial metering (X-01) --------------------------------------------------
// convert meters a kind:"trial" token against the SAME per-grant pool /generate
// spends. Managed/subscription stays free (above). The FakeChat returns 100/50
// tokens on the forced cheapest model (gemini-3.5-flash) → metered cost is
// 1 credit per conversion.

Deno.test("convert: trial token is metered — returns { prompt } and decrements the grant once", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 0 });
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.prompt, h.chat.result.content);
  // Same response shape as the subscription path — metering is server-side only.
  assertEquals(Object.keys(body), ["prompt"]);
  // Charged exactly once (1 credit for this token shape); slot taken + released.
  assertEquals(h.store.used("grant_1"), 1);
  assertEquals(h.store.consumeCalls, 1);
  assertEquals(h.store.acquireTrialSlotCalls, 1);
  assertEquals(h.store.trialSlots.size, 0, "slot released on the success path");
});

Deno.test("convert: trial token with 0 credits → 402, NO provider call (X-01 floor gate)", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 30 }); // exhausted
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 402);
  assertEquals((await res.json()).error, "out_of_credits");
  assertEquals(h.chat.calls.length, 0, "no provider spend for an out-of-credits trial");
  assertEquals(h.store.consumeCalls, 0);
  assertEquals(h.store.trialSlots.size, 0, "slot released after the floor reject");
});

Deno.test("convert: trial retry with the same Idempotency-Key does NOT double-charge", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 0 });
  const token = await trialToken("grant_1");

  const first = await handleConvert(request(makeBody(), token, "POST", "rec-abc"), h.deps);
  assertEquals(first.status, 200);
  assertEquals(h.store.used("grant_1"), 1);

  // Same recording, same key — replays the cached prompt, charges nothing more.
  const retry = await handleConvert(request(makeBody(), token, "POST", "rec-abc"), h.deps);
  assertEquals(retry.status, 200);
  assertEquals((await retry.json()).prompt, h.chat.result.content);
  assertEquals(h.store.used("grant_1"), 1, "retry did not double-charge");
  assertEquals(h.store.consumeCalls, 1, "consume ran only for the original");
  assertEquals(h.chat.calls.length, 1, "retry replayed from cache — no second provider call");
});

Deno.test("convert: trial token is pinned to the cheapest model, ignoring the requested one", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1");
  // Request the priciest model — a trial must be downgraded to the cheapest.
  const res = await handleConvert(
    request(makeBody({ model: "claude-opus-4-7" }), await trialToken("grant_1")),
    h.deps,
  );
  assertEquals(res.status, 200);
  assertEquals(h.makeChatCalls.length, 1);
  assertEquals(h.makeChatCalls[0].model, CHEAPEST_ENABLED_MODEL_ID);
  assertEquals(h.makeChatCalls[0].provider, "gemini");
});

Deno.test("convert: subscription token keeps full model choice and is NOT charged", async () => {
  const h = makeHarness();
  const res = await handleConvert(
    request(makeBody({ model: "claude-opus-4-7" }), await subToken("sub_5")),
    h.deps,
  );
  assertEquals(res.status, 200);
  // The requested (pricey) model rides through untouched.
  assertEquals(h.makeChatCalls[0], { provider: "anthropic", model: "claude-opus-4-7" });
  // No trial credit machinery touched for a paying subscriber.
  assertEquals(h.store.acquireTrialSlotCalls, 0);
  assertEquals(h.store.consumeCalls, 0);
});

Deno.test("convert: trial grant lookup error FAILS CLOSED → refuse, no provider call", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1");
  h.store.forceLoadThrow = true;
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error, "credit_check_failed");
  assertEquals(h.chat.calls.length, 0, "fail closed — never serve a free provider call");
  assertEquals(h.store.consumeCalls, 0);
});

Deno.test("convert: trial floor-check error FAILS CLOSED → refuse, no provider call", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1");
  h.store.forceCreditsThrow = true;
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 503);
  assertEquals(h.chat.calls.length, 0);
  assertEquals(h.store.trialSlots.size, 0, "slot released after the fail-closed refuse");
});

Deno.test("convert (X-02): a pending dev call-1 hold reduces the trial floor gate — a reserved credit can't fund a convert", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 29 }); // 1 raw credit left…
  h.store.heldCredits = 1; // …but it's reserved for a pending dev settle
  // The convert request carries the SAME per-recording key an old client would
  // reuse from the recording. The hold must STILL gate it: convert never
  // settles a hold, so it has no "own" hold to exclude.
  const res = await handleConvert(
    request(makeBody(), await trialToken("grant_1"), "POST", "rec-dev-pending"),
    h.deps,
  );
  assertEquals(res.status, 402);
  assertEquals((await res.json()).error, "out_of_credits");
  assertEquals(h.chat.calls.length, 0, "the held credit is not spendable by convert");
  assertEquals(h.store.consumeCalls, 0);
  assertEquals(h.store.holdExcludeKeys, [null], "convert must never exclude a key from the hold sum");
});

Deno.test("convert (X-02): a holds-read error FAILS CLOSED → refuse, no provider call", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 0 });
  h.store.forceHoldsThrow = true;
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error, "credit_check_failed");
  assertEquals(h.chat.calls.length, 0, "an unknowable spendable figure never serves a provider call");
  assertEquals(h.store.trialSlots.size, 0, "slot released after the fail-closed refuse");
});

Deno.test("convert: missing trial grant → 404; unverified → 403 (defensive gate)", async () => {
  const missing = makeHarness();
  const res404 = await handleConvert(request(makeBody(), await trialToken("ghost")), missing.deps);
  assertEquals(res404.status, 404);
  assertEquals(missing.chat.calls.length, 0);

  const unverified = makeHarness();
  unverified.store.seedTrial("grant_1", { verified: false });
  const res403 = await handleConvert(request(makeBody(), await trialToken("grant_1")), unverified.deps);
  assertEquals(res403.status, 403);
  assertEquals(unverified.chat.calls.length, 0);
});

Deno.test("convert: a held trial slot makes a concurrent conversion → 429", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1");
  h.store.trialSlots.add("grant_1"); // simulate an in-flight call holding the slot
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, "conversion_in_progress");
  assertEquals(h.chat.calls.length, 0);
  assertEquals(h.store.consumeCalls, 0);
});

// ---- A-04 (convert facet): chat-only slot stale window ----------------------
// convert holds the trial slot across a SINGLE chat call (no STT), so its safe
// reclaim window is HALF generate's. Same invariant: window > worst-case hold.

Deno.test("INVARIANT (A-04): CONVERT_SLOT_STALE_SECONDS exceeds the chat-only worst-case hold", () => {
  // One provider call (chat), up to 2 × PROVIDER_TIMEOUT_MS (initial + 1 retry).
  const worstCaseHoldSeconds = (1 /* chat only */ * 2 /* attempts */ * PROVIDER_TIMEOUT_MS) / 1000;
  assert(
    CONVERT_SLOT_STALE_SECONDS > worstCaseHoldSeconds,
    `convert stale ${CONVERT_SLOT_STALE_SECONDS}s must exceed chat-only hold ${worstCaseHoldSeconds}s`,
  );
  assertEquals(CONVERT_SLOT_STALE_SECONDS, slotStaleSeconds(1));
  assert(CONVERT_SLOT_STALE_SECONDS > 180, "above the buggy old 180s default");
});

Deno.test("convert A-04: a trial slot held within the window is NOT reclaimed (concurrent conversion → 429)", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1");
  // Held 200s: past the OLD 180s default but within convert's chat-only worst-case
  // hold — a slow-but-live conversion. Must still block, not be reclaimed.
  h.store.trialSlots.seed("grant_1", 200);
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, "conversion_in_progress");
  assertEquals(h.chat.calls.length, 0);
  assertEquals(h.store.consumeCalls, 0);
  assert(h.store.trialSlots.has("grant_1")); // the live slot is intact, not reclaimed
});

Deno.test("convert A-04: a genuinely stale trial slot IS reclaimed and the conversion runs", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1");
  h.store.trialSlots.seed("grant_1", CONVERT_SLOT_STALE_SECONDS + 60); // crashed, past the window
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 200);
  assertEquals(h.chat.calls.length, 1);
  assertEquals(h.store.consumeCalls, 1); // charged exactly once
  assertEquals(h.store.trialSlots.size, 0); // reclaimed, then released in finally
});

Deno.test("convert: a trial provider failure charges NOTHING (consume only on success)", async () => {
  const h = makeHarness();
  h.store.seedTrial("grant_1", { limit: 30, used: 0 });
  h.chat.fail = new ProviderError("gemini_400", false, 400, "gemini");
  const res = await handleConvert(request(makeBody(), await trialToken("grant_1")), h.deps);
  assertEquals(res.status, 502);
  assertEquals(h.store.used("grant_1"), 0, "no charge on a failed conversion");
  assertEquals(h.store.consumeCalls, 0);
  assertEquals(h.store.trialSlots.size, 0, "slot released on the error path");
});
