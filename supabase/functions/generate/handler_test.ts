import "./test_setup.ts"; // MUST be first — sets test env before config.ts loads.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { signSessionToken } from "../_shared/jwt.ts";
import { handleGenerate, type GenerateDeps } from "./handler.ts";
import { OpenAIError, type AudioInput, type OpenAIClient } from "./openai.ts";
import type { UserContentBlock } from "./interleave.ts";
import type { BillingStore, GenerationLogRow, SubRow } from "./store.ts";

const SECRET = "test_session_jwt_secret";
const NOW = 1_000_000;

// ---- In-memory BillingStore -------------------------------------------------
class InMemoryStore implements BillingStore {
  subs = new Map<string, SubRow>();
  used = new Map<string, number>(); // subId → credits_used (latest period)
  slots = new Set<string>();
  log: GenerationLogRow[] = [];
  rateOk = true;
  forceConsumeNull = false;

  seed(sub: SubRow, usedCredits = 0) {
    this.subs.set(sub.id, sub);
    this.used.set(sub.id, usedCredits);
  }

  loadSubscription(id: string) {
    return Promise.resolve(this.subs.get(id) ?? null);
  }
  creditsRemaining(subId: string, limit: number) {
    const used = this.used.get(subId) ?? limit;
    return Promise.resolve(Math.max(0, limit - used));
  }
  consumeCredit(subId: string) {
    if (this.forceConsumeNull) return Promise.resolve(null);
    const sub = this.subs.get(subId);
    if (!sub || (sub.status !== "active" && sub.status !== "past_due")) return Promise.resolve(null);
    const used = this.used.get(subId) ?? sub.credits_limit;
    if (used >= sub.credits_limit) return Promise.resolve(null);
    this.used.set(subId, used + 1);
    return Promise.resolve(sub.credits_limit - (used + 1));
  }
  acquireSlot(subId: string) {
    if (this.slots.has(subId)) return Promise.resolve(false);
    this.slots.add(subId);
    return Promise.resolve(true);
  }
  releaseSlot(subId: string) {
    this.slots.delete(subId);
    return Promise.resolve();
  }
  rateLimitOk() {
    return Promise.resolve(this.rateOk);
  }
  logGeneration(row: GenerationLogRow) {
    this.log.push(row);
    return Promise.resolve();
  }
}

// ---- Stub OpenAI transport (no network, no money) ---------------------------
class StubOpenAI implements OpenAIClient {
  transcribeCalls = 0;
  chatCalls = 0;
  duration = 10;
  failTranscribe: OpenAIError | null = null;
  failChat: OpenAIError | null = null;
  hang = false;
  private hangResolve: (() => void) | null = null;

  async transcribe(_audio: AudioInput) {
    this.transcribeCalls++;
    if (this.hang) await new Promise<void>((res) => (this.hangResolve = res));
    if (this.failTranscribe) throw this.failTranscribe;
    return { segments: [{ start: 0, end: 2, text: "hello world" }], durationSeconds: this.duration };
  }
  releaseHang() {
    this.hangResolve?.();
  }
  chat(_system: string, _content: UserContentBlock[]) {
    this.chatCalls++;
    if (this.failChat) return Promise.reject(this.failChat);
    return Promise.resolve({ content: "GENERATED PROMPT", inputTokens: 120, outputTokens: 60, model: "gpt-4o" });
  }
}

// ---- helpers ----------------------------------------------------------------
async function mintToken(
  sub = "sub-1",
  tier: "starter" | "pro" = "starter",
  kind: "subscription" | "trial" = "subscription",
) {
  const { token } = await signSessionToken({ sub, tier, kind }, SECRET, 1800, NOW);
  return token;
}

function makeBody(over: Record<string, unknown> = {}) {
  return {
    mode: "instruct",
    audio: { mime: "audio/m4a", filename: "rec.m4a", data: btoa("audio-bytes-here") },
    frames: [
      { timestamp: 0, mime: "image/jpeg", data: btoa("frame0") },
      { timestamp: 5, mime: "image/jpeg", data: btoa("frame1") },
    ],
    ...over,
  };
}

function makeReq(token: string | null, body: unknown) {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;
  return new Request("http://local/generate", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function deps(store: InMemoryStore, openai: StubOpenAI): GenerateDeps {
  return { store, openai, jwtSecret: SECRET, nowSeconds: NOW + 1 };
}

function activeStore(usedCredits = 0): InMemoryStore {
  const s = new InMemoryStore();
  s.seed({ id: "sub-1", tier: "starter", status: "active", credits_limit: 100 }, usedCredits);
  return s;
}

// ---- happy path -------------------------------------------------------------
Deno.test("happy path: charges exactly one credit, logs cost (no content), returns prompt", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.prompt, "GENERATED PROMPT");
  assertEquals(json.credits_remaining, 99); // decremented exactly once (100→99)
  assertEquals(json.usage.input_tokens, 120);
  assertEquals(json.usage.output_tokens, 60);

  // exactly one OpenAI round-trip of each.
  assertEquals(openai.transcribeCalls, 1);
  assertEquals(openai.chatCalls, 1);

  // one generation_log row, success, tokens + cost present, slot released.
  assertEquals(store.log.length, 1);
  const row = store.log[0];
  assertEquals(row.success, true);
  assertEquals(row.tokensIn, 120);
  assertEquals(row.tokensOut, 60);
  assert(row.estCostUsd !== null && row.estCostUsd > 0);
  assertEquals(store.slots.size, 0);

  // NO CONTENT LEAKAGE: the logged row carries only token/cost/success fields.
  assertEquals(
    Object.keys(row).sort(),
    ["estCostUsd", "subscriptionId", "success", "tokensIn", "tokensOut"],
  );
});

Deno.test("past_due still generates on remaining credits", async () => {
  const store = new InMemoryStore();
  store.seed({ id: "sub-1", tier: "starter", status: "past_due", credits_limit: 100 }, 40);
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.credits_remaining, 59); // 100-40 = 60 available → 59 after spend
  assertEquals(openai.chatCalls, 1);
});

// ---- credit gating ----------------------------------------------------------
Deno.test("zero credits → 402, no OpenAI call, no decrement, slot released", async () => {
  const store = activeStore(100); // used == limit
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 402);
  assertEquals(openai.transcribeCalls, 0);
  assertEquals(openai.chatCalls, 0);
  assertEquals(store.used.get("sub-1"), 100); // unchanged
  assertEquals(store.log.length, 0);
  assertEquals(store.slots.size, 0);
});

// ---- input fuse (before any OpenAI call / credit work) ----------------------
Deno.test("too many frames → 413, no OpenAI call, no charge", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const frames = Array.from({ length: 201 }, (_, i) => ({
    timestamp: i,
    mime: "image/jpeg",
    data: btoa("f"),
  }));
  const res = await handleGenerate(makeReq(await mintToken(), makeBody({ frames })), deps(store, openai));
  assertEquals(res.status, 413);
  assertEquals((await res.json()).error, "too_many_frames");
  assertEquals(openai.transcribeCalls, 0);
  assertEquals(store.used.get("sub-1"), 0);
});

Deno.test("wrong audio mime → 415, no OpenAI call", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const body = makeBody({ audio: { mime: "audio/wav", data: btoa("x") } });
  const res = await handleGenerate(makeReq(await mintToken(), body), deps(store, openai));
  assertEquals(res.status, 415);
  assertEquals((await res.json()).error, "unsupported_audio_mime");
  assertEquals(openai.transcribeCalls, 0);
});

Deno.test("wrong frame mime → 415, no OpenAI call", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const body = makeBody({ frames: [{ timestamp: 0, mime: "image/png", data: btoa("x") }] });
  const res = await handleGenerate(makeReq(await mintToken(), body), deps(store, openai));
  assertEquals(res.status, 415);
  assertEquals((await res.json()).error, "unsupported_frame_mime");
  assertEquals(openai.transcribeCalls, 0);
});

Deno.test("oversized payload → 413 before parse, no OpenAI call", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  // Body > GENERATE_MAX_PAYLOAD_BYTES (50000, set in test_setup.ts).
  const big = makeBody({ audio: { mime: "audio/m4a", data: "A".repeat(60_000) } });
  const res = await handleGenerate(makeReq(await mintToken(), big), deps(store, openai));
  assertEquals(res.status, 413);
  assertEquals((await res.json()).error, "payload_too_large");
  assertEquals(openai.transcribeCalls, 0);
});

Deno.test("audio too long (measured post-transcription) → 413 before chat, no charge", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  openai.duration = 999; // > MAX_AUDIO_SECONDS (300)
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 413);
  assertEquals((await res.json()).error, "audio_too_long");
  assertEquals(openai.transcribeCalls, 1); // whisper ran
  assertEquals(openai.chatCalls, 0); // chat did NOT
  assertEquals(store.used.get("sub-1"), 0); // no charge
  assertEquals(store.log.length, 1);
  assertEquals(store.log[0].success, false);
  assert((store.log[0].estCostUsd ?? 0) > 0); // whisper cost recorded honestly
});

// ---- OpenAI failure never charges ------------------------------------------
Deno.test("transcribe 429 → 503 retryable, chat not called, no charge", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  openai.failTranscribe = new OpenAIError("rate", true, 429);
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 503);
  assertEquals((await res.json()).retryable, true);
  assertEquals(openai.chatCalls, 0);
  assertEquals(store.used.get("sub-1"), 0);
  assertEquals(store.log.length, 1);
  assertEquals(store.log[0].success, false);
  assertEquals(store.log[0].estCostUsd, null);
  assertEquals(store.slots.size, 0);
});

Deno.test("chat 500 → 503 retryable, credit NOT consumed", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  openai.failChat = new OpenAIError("server", true, 500);
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 503);
  assertEquals(openai.transcribeCalls, 1);
  assertEquals(store.used.get("sub-1"), 0); // not charged
  assertEquals(store.log.length, 1);
  assertEquals(store.log[0].success, false);
});

Deno.test("non-retryable OpenAI error → 502", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  openai.failChat = new OpenAIError("bad key", false, 401);
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 502);
  assertEquals(store.used.get("sub-1"), 0);
});

// ---- auth -------------------------------------------------------------------
Deno.test("missing token → 401, nothing happens", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(null, makeBody()), deps(store, openai));
  assertEquals(res.status, 401);
  assertEquals(openai.transcribeCalls, 0);
});

Deno.test("invalid token → 401", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq("not.a.jwt", makeBody()), deps(store, openai));
  assertEquals(res.status, 401);
});

Deno.test("expired token → 401", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const { token } = await signSessionToken({ sub: "sub-1", tier: "starter" }, SECRET, 60, NOW);
  // verify with a clock past expiry
  const res = await handleGenerate(makeReq(token, makeBody()), { store, openai, jwtSecret: SECRET, nowSeconds: NOW + 61 });
  assertEquals(res.status, 401);
  assertEquals(openai.transcribeCalls, 0);
});

Deno.test("trial-kind token → 401 (Phase F)", async () => {
  const store = activeStore(0);
  const openai = new StubOpenAI();
  const token = await mintToken("sub-1", "starter", "trial");
  const res = await handleGenerate(makeReq(token, makeBody()), deps(store, openai));
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error, "unsupported_token_kind");
});

// ---- subscriber status ------------------------------------------------------
Deno.test("cancelled subscriber → 403, no OpenAI call", async () => {
  const store = new InMemoryStore();
  store.seed({ id: "sub-1", tier: "starter", status: "cancelled", credits_limit: 100 }, 0);
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 403);
  assertEquals(openai.transcribeCalls, 0);
});

Deno.test("expired subscriber → 403", async () => {
  const store = new InMemoryStore();
  store.seed({ id: "sub-1", tier: "starter", status: "expired", credits_limit: 100 }, 0);
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 403);
});

Deno.test("unknown subscriber → 404", async () => {
  const store = new InMemoryStore(); // sub-1 not seeded
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 404);
});

// ---- rate limit -------------------------------------------------------------
Deno.test("rate limited → 429, no OpenAI call", async () => {
  const store = activeStore(0);
  store.rateOk = false;
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, "rate_limited");
  assertEquals(openai.transcribeCalls, 0);
});

// ---- concurrency cap (double-spend guard) -----------------------------------
Deno.test("second concurrent request for same subscriber → 429 (concurrency cap)", async () => {
  const store = activeStore(99); // exactly 1 credit left
  const openai = new StubOpenAI();
  openai.hang = true; // first request parks inside transcribe, holding the slot

  const p1 = handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  // Let p1's microtasks run up to the hung transcribe (slot now held).
  await new Promise((r) => setTimeout(r, 0));

  const r2 = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(r2.status, 429);
  assertEquals((await r2.json()).error, "generation_in_progress");

  // release p1 and let it finish: exactly one generation charges the 1 credit.
  openai.releaseHang();
  const r1 = await p1;
  assertEquals(r1.status, 200);
  assertEquals((await r1.json()).credits_remaining, 0);
  assertEquals(store.used.get("sub-1"), 100); // charged exactly once
  assertEquals(store.slots.size, 0); // both slots released
});

// ---- consume race edge ------------------------------------------------------
Deno.test("credit becomes unspendable after the check → result returned once, logged, not double-charged", async () => {
  const store = activeStore(0);
  store.forceConsumeNull = true; // simulate a mid-flight state change
  const openai = new StubOpenAI();
  const res = await handleGenerate(makeReq(await mintToken(), makeBody()), deps(store, openai));
  assertEquals(res.status, 200); // we already paid OpenAI → return the result once
  const json = await res.json();
  assertEquals(json.prompt, "GENERATED PROMPT");
  assertEquals(json.credits_remaining, 0);
  assertEquals(store.log.length, 1);
  assertEquals(store.log[0].success, true);
  assertEquals(store.slots.size, 0);
});
