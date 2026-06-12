import "./test_setup.ts"; // MUST be first — sets test env before config.ts loads.

// =============================================================================
// handler_test.ts — the convert handler's gates and flow (Phase 6). Mirrors
// generate's handler tests for auth / method / size / validation / rate-limit
// / provider-error mapping — minus ALL billing (no credits, no slot, no
// idempotency, no generation_log on this endpoint, by design).
// =============================================================================

import { assert, assertEquals } from "jsr:@std/assert@1";
import { signSessionToken } from "../_shared/jwt.ts";
import { type ConvertDeps, handleConvert } from "./handler.ts";
import { conversionSystemPrompt } from "./prompt.ts";
import { DEFAULT_MODEL_ID } from "../generate/models.ts";
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

interface Harness {
  deps: ConvertDeps;
  chat: FakeChat;
  rateCalls: { key: string; max: number; windowSeconds: number }[];
  makeChatCalls: { provider: string; model: string }[];
  setRateOk(ok: boolean): void;
  setMakeChatThrows(): void;
}

function makeHarness(): Harness {
  const chat = new FakeChat();
  let rateOk = true;
  let makeChatThrows = false;
  const rateCalls: Harness["rateCalls"] = [];
  const makeChatCalls: Harness["makeChatCalls"] = [];
  const deps: ConvertDeps = {
    store: {
      rateLimitOk(key, max, windowSeconds) {
        rateCalls.push({ key, max, windowSeconds });
        return Promise.resolve(rateOk);
      },
    },
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
    rateCalls,
    makeChatCalls,
    setRateOk: (ok) => {
      rateOk = ok;
    },
    setMakeChatThrows: () => {
      makeChatThrows = true;
    },
  };
}

async function subToken(sub = "sub_1"): Promise<string> {
  const { token } = await signSessionToken({ sub, tier: "starter" }, SECRET, 3600, NOW);
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

function request(body: unknown, token: string | null, method = "POST"): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
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
  const res = await handleConvert(request(makeBody(), await trialToken("grant_7")), h.deps);
  assertEquals(res.status, 200);
  assertEquals(h.rateCalls[0].key, "convert:trial:grant_7");
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

Deno.test("convert: trial token converts exactly like a subscription token", async () => {
  const h = makeHarness();
  const res = await handleConvert(request(makeBody(), await trialToken()), h.deps);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).prompt, h.chat.result.content);
});
