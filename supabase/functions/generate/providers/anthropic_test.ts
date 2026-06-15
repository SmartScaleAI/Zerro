import "../test_setup.ts"; // sets test env before config.ts loads.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { AnthropicChatClient, toAnthropicContent } from "./anthropic.ts";
import { ProviderError, type TimelineBlock } from "./types.ts";

const BLOCKS: TimelineBlock[] = [
  { type: "text", text: "\n[0:00] " },
  { type: "image", mime: "image/jpeg", base64: "AAAA" },
  { type: "text", text: `\n[0:00–0:02] "hello world"` },
];

function stubFetch(handler: (url: string, init: RequestInit) => Response) {
  const orig = globalThis.fetch;
  const calls: { url: string; init: RequestInit }[] = [];
  globalThis.fetch = (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init! });
    return Promise.resolve(handler(String(url), init!));
  };
  return { calls, restore: () => (globalThis.fetch = orig) };
}

function okResponse(
  extra: Record<string, unknown> = {},
  content: Array<{ type: string; text?: string }> = [{ type: "text", text: "RESULT" }],
) {
  return new Response(
    JSON.stringify({
      content,
      stop_reason: "end_turn",
      usage: { input_tokens: 30, output_tokens: 12 },
      model: "claude-sonnet-4-6",
      ...extra,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

Deno.test("toAnthropicContent: text + base64 image blocks, order preserved", () => {
  assertEquals(toAnthropicContent(BLOCKS), [
    { type: "text", text: "\n[0:00] " },
    { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "AAAA" } },
    { type: "text", text: `\n[0:00–0:02] "hello world"` },
  ]);
});

Deno.test("AnthropicChatClient.chat: posts the exact Messages API body, key + version headers", async () => {
  const f = stubFetch(() => okResponse());
  try {
    const client = new AnthropicChatClient("secret-key", "claude-sonnet-4-6");
    await client.chat("SYS", BLOCKS);

    const c = f.calls[0];
    assertEquals(c.url, "https://api.anthropic.com/v1/messages");
    // Key is in the x-api-key header, NEVER the URL.
    assert(!c.url.includes("secret-key"));
    const headers = c.init.headers as Record<string, string>;
    assertEquals(headers["x-api-key"], "secret-key");
    assertEquals(headers["anthropic-version"], "2023-06-01");

    assertEquals(JSON.parse(c.init.body as string), {
      model: "claude-sonnet-4-6",
      max_tokens: 16384, // REQUIRED by the Messages API
      system: "SYS", // top-level system field, not a message
      messages: [{
        role: "user",
        content: [
          { type: "text", text: "\n[0:00] " },
          { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "AAAA" } },
          { type: "text", text: `\n[0:00–0:02] "hello world"` },
        ],
      }],
    });
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: concatenates text blocks, maps usage + reported model", async () => {
  const f = stubFetch(() =>
    okResponse({}, [
      { type: "text", text: "Hello, " },
      { type: "tool_use" }, // non-text block must be skipped
      { type: "text", text: "world." },
    ])
  );
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    const res = await client.chat("SYS", [{ type: "text", text: "hi" }]);
    assertEquals(res.content, "Hello, world.");
    assertEquals(res.provider, "anthropic");
    assertEquals(res.inputTokens, 30);
    assertEquals(res.outputTokens, 12);
    assertEquals(res.model, "claude-sonnet-4-6"); // logs the response's model
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: stop_reason refusal → non-retryable empty content", async () => {
  const f = stubFetch(() =>
    okResponse({ stop_reason: "refusal" }, [{ type: "text", text: "I can't help with that." }])
  );
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assert(err instanceof ProviderError);
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).provider, "anthropic");
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: stop_reason max_tokens → non-retryable truncation", async () => {
  // A truncated response DOES carry partial text; it must still be withheld
  // (handoff-artifact-fence-leak) and surfaced as a truncation, not returned.
  const f = stubFetch(() =>
    okResponse({ stop_reason: "max_tokens" }, [{ type: "text", text: "partial <<<ZERRO_ARTIFACT" }])
  );
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assert(err instanceof ProviderError);
    assertEquals((err as ProviderError).truncated, true);
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).provider, "anthropic");
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: empty content array → non-retryable empty content", async () => {
  const f = stubFetch(() => okResponse({}, []));
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals((err as ProviderError).retryable, false);
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: 503 retries once then throws retryable", async () => {
  let calls = 0;
  const f = stubFetch(() => {
    calls++;
    return new Response("overloaded", { status: 503 });
  });
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals(calls, 2); // single retry
    assertEquals((err as ProviderError).retryable, true);
    assertEquals((err as ProviderError).status, 503);
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: 429 retries once; success on retry returns result", async () => {
  let calls = 0;
  const f = stubFetch(() => {
    calls++;
    return calls === 1 ? new Response("rate limited", { status: 429 }) : okResponse();
  });
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    const res = await client.chat("SYS", [{ type: "text", text: "hi" }]);
    assertEquals(calls, 2);
    assertEquals(res.content, "RESULT");
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: 401 auth → non-retryable", async () => {
  const f = stubFetch(() => new Response("unauthorized", { status: 401 }));
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).status, 401);
  } finally {
    f.restore();
  }
});

Deno.test("AnthropicChatClient.chat: other 4xx (400) → non-retryable, no retry", async () => {
  let calls = 0;
  const f = stubFetch(() => {
    calls++;
    return new Response("bad request", { status: 400 });
  });
  try {
    const client = new AnthropicChatClient("k", "claude-sonnet-4-6");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals(calls, 1); // 4xx (non-429) is not retried
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).status, 400);
  } finally {
    f.restore();
  }
});
