import "./test_setup.ts"; // sets test env before config.ts loads.

import { assertAlmostEquals, assertEquals } from "jsr:@std/assert@1";
import { chatCostUsd, estimatedCostUsd, sttCostUsd } from "./cost.ts";

const M = 1_000_000;

Deno.test("chatCostUsd: openai:gpt-4o priced from the table", () => {
  // 1M in @ $2.5, 1M out @ $10.0 → $12.5
  assertAlmostEquals(chatCostUsd("openai", "gpt-4o", M, M)!, 12.5, 1e-9);
});

Deno.test("chatCostUsd: gemini-3.5-flash flat pricing", () => {
  // 1M in @ $1.5, 1M out @ $9.0 → $10.5
  assertAlmostEquals(chatCostUsd("gemini", "gemini-3.5-flash", M, M)!, 10.5, 1e-9);
});

Deno.test("chatCostUsd: gemini-3.1-pro-preview below the 200k tier uses base rates", () => {
  // 100k in @ $2.0, 100k out @ $12.0 → 0.2 + 1.2 = $1.4
  assertAlmostEquals(chatCostUsd("gemini", "gemini-3.1-pro-preview", 100_000, 100_000)!, 1.4, 1e-9);
});

Deno.test("chatCostUsd: gemini-3.1-pro-preview above 200k input raises BOTH rates", () => {
  // 300k in @ $4.0 (above), 100k out @ $18.0 (above) → 1.2 + 1.8 = $3.0
  assertAlmostEquals(chatCostUsd("gemini", "gemini-3.1-pro-preview", 300_000, 100_000)!, 3.0, 1e-9);
});

Deno.test("chatCostUsd: unknown provider:model → null (no wrong number)", () => {
  assertEquals(chatCostUsd("anthropic", "claude-x", M, M), null);
  assertEquals(chatCostUsd("gemini", "gemini-9-imaginary", M, M), null);
});

Deno.test("sttCostUsd: whisper per-minute (configured openai:whisper-1)", () => {
  assertAlmostEquals(sttCostUsd(60)!, 0.006, 1e-9); // 1 minute
  assertEquals(sttCostUsd(0), 0);
});

Deno.test("estimatedCostUsd: stt + chat for a known chat model", () => {
  // 60s STT ($0.006) + gpt-4o 1M/1M ($12.5) = $12.506
  assertAlmostEquals(estimatedCostUsd(60, "openai", "gpt-4o", M, M)!, 12.506, 1e-9);
});

Deno.test("estimatedCostUsd: unknown chat model → null (generation still proceeds upstream)", () => {
  assertEquals(estimatedCostUsd(60, "gemini", "gemini-9-imaginary", M, M), null);
});
