import "../test_setup.ts"; // sets test env before config.ts loads.

import { assertEquals } from "jsr:@std/assert@1";
import { OpenAIChatClient, OpenAISttClient, toOpenAIContent } from "./openai.ts";
import { ProviderError, type TimelineBlock } from "./types.ts";
import { buildInterleavedContent } from "../interleave.ts";

// A known timeline: two frames around a speech segment, exercising the
// frame-before-speech tie-break and the leading-newline tags.
const FRAMES = [
  { timestamp: 0, mime: "image/jpeg", base64: "AAAA" },
  { timestamp: 5, mime: "image/jpeg", base64: "BBBB" },
];
const SEGMENTS = [{ start: 0, end: 2, text: "hello world" }];

Deno.test("toOpenAIContent: byte-identical OpenAI content blocks (data-URL, detail:high, tag order)", () => {
  const blocks = buildInterleavedContent(FRAMES, SEGMENTS);
  const content = toOpenAIContent(blocks);

  // The exact shape today's code sends — frame text tag, then the image_url
  // data-URL with detail:"high", then the speech tag. Frame[0] before speech[0]
  // at t=0 (tie-break), then frame[1] at t=5.
  assertEquals(content, [
    { type: "text", text: "\n[0:00] " },
    { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA", detail: "high" } },
    { type: "text", text: `\n[0:00–0:02] "hello world"` },
    { type: "text", text: "\n[0:05] " },
    { type: "image_url", image_url: { url: "data:image/jpeg;base64,BBBB", detail: "high" } },
  ]);
});

Deno.test("OpenAIChatClient.chat: posts the exact /chat/completions body and maps usage", async () => {
  let captured: { url: string; init: RequestInit } | null = null;
  const origFetch = globalThis.fetch;
  globalThis.fetch = (url: string | URL | Request, init?: RequestInit) => {
    captured = { url: String(url), init: init! };
    return Promise.resolve(
      new Response(
        JSON.stringify({
          choices: [{ message: { content: "RESULT" } }],
          usage: { prompt_tokens: 11, completion_tokens: 7 },
          model: "gpt-4o-2024-xx",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
  };
  try {
    const client = new OpenAIChatClient("test-key", "gpt-4o");
    const blocks: TimelineBlock[] = [
      { type: "text", text: "\n[0:00] " },
      { type: "image", mime: "image/jpeg", base64: "AAAA" },
    ];
    const res = await client.chat("SYS", blocks);

    assertEquals(res.provider, "openai");
    assertEquals(res.content, "RESULT");
    assertEquals(res.inputTokens, 11);
    assertEquals(res.outputTokens, 7);
    assertEquals(res.model, "gpt-4o-2024-xx"); // logs the response version

    const c = captured!;
    assertEquals(c.url, "https://api.openai.com/v1/chat/completions");
    assertEquals((c.init.headers as Record<string, string>).Authorization, "Bearer test-key");
    assertEquals(JSON.parse(c.init.body as string), {
      model: "gpt-4o",
      // B-04: server-side output cap, mirroring Anthropic's 16384.
      max_completion_tokens: 16384,
      messages: [
        { role: "system", content: "SYS" },
        {
          role: "user",
          content: [
            { type: "text", text: "\n[0:00] " },
            { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA", detail: "high" } },
          ],
        },
      ],
    });
  } finally {
    globalThis.fetch = origFetch;
  }
});

Deno.test("OpenAIChatClient.chat: pins a max_completion_tokens output cap (B-04)", async () => {
  let captured: RequestInit | null = null;
  const origFetch = globalThis.fetch;
  globalThis.fetch = (_url: string | URL | Request, init?: RequestInit) => {
    captured = init!;
    return Promise.resolve(
      new Response(
        JSON.stringify({ choices: [{ message: { content: "X" } }], usage: {} }),
        { status: 200 },
      ),
    );
  };
  try {
    await new OpenAIChatClient("k", "gpt-5.5").chat("SYS", [{ type: "text", text: "hi" }]);
    const body = JSON.parse(captured!.body as string);
    // The cap is present and bounded — an uncapped request would omit this field.
    assertEquals(body.max_completion_tokens, 16384);
  } finally {
    globalThis.fetch = origFetch;
  }
});

Deno.test("OpenAIChatClient.chat: empty content → non-retryable ProviderError", async () => {
  const origFetch = globalThis.fetch;
  globalThis.fetch = () =>
    Promise.resolve(
      new Response(JSON.stringify({ choices: [{ message: { content: "" } }] }), { status: 200 }),
    );
  try {
    const client = new OpenAIChatClient("k", "gpt-4o");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals(err instanceof ProviderError, true);
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).provider, "openai");
  } finally {
    globalThis.fetch = origFetch;
  }
});

Deno.test("OpenAIChatClient.chat: finish_reason length → non-retryable truncation", async () => {
  // A truncated response carries partial content; withhold it and surface a
  // truncation rather than returning it (handoff-artifact-fence-leak).
  const origFetch = globalThis.fetch;
  globalThis.fetch = () =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          choices: [{ message: { content: "partial <<<ZERRO_ARTIFACT" }, finish_reason: "length" }],
          usage: { prompt_tokens: 11, completion_tokens: 16384 },
        }),
        { status: 200 },
      ),
    );
  try {
    const client = new OpenAIChatClient("k", "gpt-4o");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals(err instanceof ProviderError, true);
    assertEquals((err as ProviderError).truncated, true);
    assertEquals((err as ProviderError).retryable, false);
    assertEquals((err as ProviderError).provider, "openai");
  } finally {
    globalThis.fetch = origFetch;
  }
});

Deno.test("OpenAIChatClient.chat: 500 retries once then throws retryable ProviderError", async () => {
  let calls = 0;
  const origFetch = globalThis.fetch;
  globalThis.fetch = () => {
    calls++;
    return Promise.resolve(new Response("err", { status: 500 }));
  };
  try {
    const client = new OpenAIChatClient("k", "gpt-4o");
    let err: unknown;
    try {
      await client.chat("SYS", [{ type: "text", text: "hi" }]);
    } catch (e) {
      err = e;
    }
    assertEquals(calls, 2); // single retry
    assertEquals((err as ProviderError).retryable, true);
    assertEquals((err as ProviderError).status, 500);
  } finally {
    globalThis.fetch = origFetch;
  }
});

Deno.test("OpenAISttClient.transcribe: multipart + verbose_json, trims segment text", async () => {
  let captured: { url: string; body: FormData } | null = null;
  const origFetch = globalThis.fetch;
  globalThis.fetch = (url: string | URL | Request, init?: RequestInit) => {
    captured = { url: String(url), body: init!.body as FormData };
    return Promise.resolve(
      new Response(
        JSON.stringify({
          duration: 12.5,
          segments: [{ start: 0, end: 2, text: " hello " }],
        }),
        { status: 200 },
      ),
    );
  };
  try {
    const client = new OpenAISttClient("test-key", "whisper-1");
    const res = await client.transcribe({
      bytes: new Uint8Array([1, 2, 3]),
      mime: "audio/m4a",
      filename: "rec.m4a",
    });
    assertEquals(res.durationSeconds, 12.5);
    assertEquals(res.segments, [{ start: 0, end: 2, text: "hello" }]); // leading space trimmed

    const c = captured!;
    assertEquals(c.url, "https://api.openai.com/v1/audio/transcriptions");
    assertEquals(c.body.get("model"), "whisper-1");
    assertEquals(c.body.get("response_format"), "verbose_json");
    assertEquals(c.body.get("timestamp_granularities[]"), "segment");
  } finally {
    globalThis.fetch = origFetch;
  }
});

Deno.test("OpenAIChatClient.chat: absent usage block → null tokens, not 0 (B-06)", async () => {
  // No usage key in the response at all: the adapter must report unknown (null)
  // so the cost math charges fallbackCredits, never a $0 chat.
  const origFetch = globalThis.fetch;
  globalThis.fetch = () =>
    Promise.resolve(
      new Response(
        JSON.stringify({ choices: [{ message: { content: "X" }, finish_reason: "stop" }] }),
        { status: 200 },
      ),
    );
  try {
    const res = await new OpenAIChatClient("k", "gpt-4o").chat("SYS", [{ type: "text", text: "hi" }]);
    assertEquals(res.inputTokens, null);
    assertEquals(res.outputTokens, null);
    assertEquals(res.content, "X"); // the result itself is still usable
  } finally {
    globalThis.fetch = origFetch;
  }
});
