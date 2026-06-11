import "../test_setup.ts"; // sets test env before config.ts loads.

import { assert, assertThrows } from "jsr:@std/assert@1";
import { makeChatClient, makeSttClient } from "./factory.ts";
import { OpenAIChatClient, OpenAISttClient } from "./openai.ts";
import { GeminiChatClient } from "./gemini.ts";
import { AnthropicChatClient } from "./anthropic.ts";

// All branches are exercised in ONE process — only possible because the
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

Deno.test("makeChatClient: anthropic → AnthropicChatClient (key required)", () => {
  const c = makeChatClient({
    provider: "anthropic",
    model: "claude-sonnet-4-6",
    openaiKey: "k",
    anthropicKey: "a",
  });
  assert(c instanceof AnthropicChatClient);
});

Deno.test("makeChatClient: anthropic without ANTHROPIC_API_KEY throws", () => {
  assertThrows(
    () => makeChatClient({ provider: "anthropic", model: "claude-sonnet-4-6", openaiKey: "k" }),
    Error,
    "ANTHROPIC_API_KEY",
  );
});

Deno.test("makeChatClient: unknown provider throws at wiring time", () => {
  assertThrows(
    () => makeChatClient({ provider: "mistral", model: "x", openaiKey: "k" }),
    Error,
    "Unknown CHAT_PROVIDER: mistral",
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

// Sanity: all provider branches resolve to distinct outcomes in one run.
Deno.test("makeChatClient: openai / gemini / anthropic / unknown resolve independently in one process", () => {
  const a = makeChatClient({ provider: "openai", model: "gpt-4o", openaiKey: "k" });
  const b = makeChatClient({
    provider: "gemini",
    model: "gemini-3.5-flash",
    openaiKey: "k",
    geminiKey: "g",
  });
  const c = makeChatClient({
    provider: "anthropic",
    model: "claude-opus-4-7",
    openaiKey: "k",
    anthropicKey: "a",
  });
  assert(a instanceof OpenAIChatClient);
  assert(b instanceof GeminiChatClient);
  assert(c instanceof AnthropicChatClient);
  assertThrows(() => makeChatClient({ provider: "zzz", model: "x", openaiKey: "k" }));
});
