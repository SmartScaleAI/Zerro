import "../test_setup.ts"; // sets test env before config.ts loads.

import { assert, assertThrows } from "jsr:@std/assert@1";
import { makeChatClient, makeSttClient } from "./factory.ts";
import { OpenAIChatClient, OpenAISttClient } from "./openai.ts";
import { GeminiChatClient } from "./gemini.ts";

// All three branches are exercised in ONE process — only possible because the
// factory takes the provider as an argument rather than reading a frozen
// config.ts const evaluated at import.

Deno.test("makeChatClient: openai → OpenAIChatClient", () => {
  const c = makeChatClient({ provider: "openai", model: "gpt-4o", openaiKey: "k" });
  assert(c instanceof OpenAIChatClient);
});

Deno.test("makeChatClient: gemini → GeminiChatClient (key required)", () => {
  const c = makeChatClient({
    provider: "gemini",
    model: "gemini-3.5-flash",
    openaiKey: "k",
    geminiKey: "g",
    thinkingLevel: "low",
  });
  assert(c instanceof GeminiChatClient);
});

Deno.test("makeChatClient: gemini without GEMINI_API_KEY throws", () => {
  assertThrows(
    () => makeChatClient({ provider: "gemini", model: "gemini-3.5-flash", openaiKey: "k" }),
    Error,
    "GEMINI_API_KEY",
  );
});

Deno.test("makeChatClient: unknown provider throws at wiring time", () => {
  assertThrows(
    () => makeChatClient({ provider: "anthropic", model: "x", openaiKey: "k" }),
    Error,
    "Unknown CHAT_PROVIDER: anthropic",
  );
});

Deno.test("makeSttClient: openai → OpenAISttClient; unknown throws", () => {
  assert(makeSttClient({ provider: "openai", openaiKey: "k" }) instanceof OpenAISttClient);
  assertThrows(
    () => makeSttClient({ provider: "gemini", openaiKey: "k" }),
    Error,
    "Unknown STT_PROVIDER: gemini",
  );
});

// Sanity: the three chat branches resolve to three distinct outcomes in one run.
Deno.test("makeChatClient: openai / gemini / unknown resolve independently in one process", () => {
  const a = makeChatClient({ provider: "openai", model: "gpt-4o", openaiKey: "k" });
  const b = makeChatClient({
    provider: "gemini",
    model: "gemini-3.5-flash",
    openaiKey: "k",
    geminiKey: "g",
  });
  assert(a instanceof OpenAIChatClient);
  assert(b instanceof GeminiChatClient);
  assertThrows(() => makeChatClient({ provider: "zzz", model: "x", openaiKey: "k" }));
});
