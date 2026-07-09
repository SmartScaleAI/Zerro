import "../test_setup.ts"; // sets test env before config.ts loads.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { GeminiChatClient, toGeminiParts } from "./gemini.ts";
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
  parts: Array<{ text: string; thought?: boolean }> = [{ text: "RESULT" }],
) {
  return new Response(
    JSON.stringify({
      candidates: [{ content: { parts }, finishReason: "STOP" }],
      usageMetadata: { promptTokenCount: 30, candidatesTokenCount: 12, thoughtsTokenCount: 5 },
      modelVersion: "gemini-3.5-flash-2026xx",
      ...extra,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

Deno.test("toGeminiParts: per-part inlineData + mediaResolution, order preserved", () => {
  assertEquals(toGeminiParts(BLOCKS), [
    { text: "\n[0:00] " },
    {
      inlineData: { mimeType: "image/jpeg", data: "AAAA" },
      mediaResolution: { level: "media_resolution_high" },
    },
    { text: `\n[0:00–0:02] "hello world"` },
  ]);
});

Deno.test("GeminiChatClient.chat: posts the exact generateContent body, key in header not URL", async () => {
  const f = stubFetch(() => okResponse());
  try {
    const client = new GeminiChatClient("secret-key", "gemini-3.5-flash", "low");
    await client.chat("SYS", BLOCKS);

    const c = f.calls[0];
    // Key is in the header, NEVER the URL query string.
    assertEquals(
      c.url,
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent",
    );
    assert(!c.url.includes("secret-key"));
    assertEquals((c.init.headers as Record<string, string>)["x-goog-api-key"], "secret-key");

    assertEquals(JSON.parse(c.init.body as string), {
      systemInstruction: { parts: [{ text: "SYS" }] },
      contents: [{
        role: "user",
        parts: [
          { text: "\n[0:00] " },
          {
            inlineData: { mimeType: "image/jpeg", data: "AAAA" },
            mediaResolution: { level: "media_resolution_high" },
          },
          { text: `\n[0:00–0:02] "hello world"` },
        ],
      }],
      // B-04: server-side output cap (maxOutputTokens), mirroring Anthropic's 16384.
      generationConfig: { maxOutputTokens: 16384, thinkingConfig: { thinkingLevel: "low" } },
    });
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: pins a maxOutputTokens output cap (B-04)", async () => {
  const f = stubFetch(() => okResponse());
  try {
    await new GeminiChatClient("k", "gemini-3.5-flash", "low").chat("SYS", [{ type: "text", text: "hi" }]);
    const body = JSON.parse(f.calls[0].init.body as string);
    // The cap is present and bounded — an uncapped request would omit this field.
    assertEquals(body.generationConfig.maxOutputTokens, 16384);
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: thinkingLevel reflects config (high)", async () => {
  const f = stubFetch(() => okResponse());
  try {
    const client = new GeminiChatClient("k", "gemini-3.1-pro-preview", "high");
    await client.chat("SYS", [{ type: "text", text: "hi" }]);
    const body = JSON.parse(f.calls[0].init.body as string);
    assertEquals(body.generationConfig.thinkingConfig.thinkingLevel, "high");
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: concatenates text parts, skips thought parts, folds thought tokens", async () => {
  const f = stubFetch(() =>
    okResponse({}, [
      { text: "Hello, ", thought: false },
      { text: "internal reasoning", thought: true }, // must be skipped
      { text: "world." },
    ])
  );
  try {
    const client = new GeminiChatClient("k", "gemini-3.5-flash", "low");
    const res = await client.chat("SYS", [{ type: "text", text: "hi" }]);
    assertEquals(res.content, "Hello, world."); // thought text excluded
    assertEquals(res.provider, "gemini");
    assertEquals(res.inputTokens, 30);
    assertEquals(res.outputTokens, 17); // 12 candidates + 5 thoughts
    assertEquals(res.model, "gemini-3.5-flash-2026xx"); // logs modelVersion
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: promptFeedback.blockReason → non-retryable empty content", async () => {
  const f = stubFetch(() =>
    new Response(JSON.stringify({ promptFeedback: { blockReason: "SAFETY" } }), { status: 200 })
  );
  try {
    const client = new GeminiChatClient("k", "gemini-3.5-flash", "low");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assert(err instanceof ProviderError);
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).provider, "gemini");
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: finishReason SAFETY → non-retryable empty content", async () => {
  const f = stubFetch(() =>
    new Response(
      JSON.stringify({ candidates: [{ content: { parts: [] }, finishReason: "SAFETY" }] }),
      { status: 200 },
    )
  );
  try {
    const client = new GeminiChatClient("k", "gemini-3.5-flash", "low");
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

Deno.test("GeminiChatClient.chat: finishReason MAX_TOKENS → non-retryable truncation", async () => {
  // A truncated response carries partial parts; withhold it and surface a
  // truncation rather than returning it (handoff-artifact-fence-leak).
  const f = stubFetch(() =>
    new Response(
      JSON.stringify({
        candidates: [{ content: { parts: [{ text: "partial <<<ZERRO_ARTIFACT" }] }, finishReason: "MAX_TOKENS" }],
        usageMetadata: { promptTokenCount: 30, candidatesTokenCount: 16384 },
      }),
      { status: 200 },
    )
  );
  try {
    const client = new GeminiChatClient("k", "gemini-3.5-flash", "low");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assert(err instanceof ProviderError);
    assertEquals((err as ProviderError).truncated, true);
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).provider, "gemini");
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: 503 retries once then throws retryable", async () => {
  let calls = 0;
  const f = stubFetch(() => {
    calls++;
    return new Response("unavailable", { status: 503 });
  });
  try {
    const client = new GeminiChatClient("k", "gemini-3.5-flash", "low");
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

Deno.test("GeminiChatClient.chat: 403 auth → non-retryable", async () => {
  const f = stubFetch(() => new Response("forbidden", { status: 403 }));
  try {
    const client = new GeminiChatClient("k", "gemini-3.5-flash", "low");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).status, 403);
  } finally {
    f.restore();
  }
});

Deno.test("GeminiChatClient.chat: absent usageMetadata block → null tokens, not 0 (B-06)", async () => {
  // `usageMetadata: undefined` in the spread makes JSON.stringify DROP the key —
  // the response carries no usage block at all. The adapter must report unknown
  // (null) so the cost math charges fallbackCredits, never a $0 chat. (A present
  // block with only thoughtsTokenCount missing keeps the per-field `?? 0`.)
  const f = stubFetch(() => okResponse({ usageMetadata: undefined }));
  try {
    const res = await new GeminiChatClient("k", "gemini-3.5-flash", "low")
      .chat("SYS", [{ type: "text", text: "hi" }]);
    assertEquals(res.inputTokens, null);
    assertEquals(res.outputTokens, null);
    assertEquals(res.content, "RESULT"); // the result itself is still usable
  } finally {
    f.restore();
  }
});
