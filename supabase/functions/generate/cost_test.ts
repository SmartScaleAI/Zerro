import "./test_setup.ts"; // sets test env before config.ts loads.

import { assertAlmostEquals, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { chatCostUsd, creditCostForModel, estimatedCostUsd, sttCostUsd } from "./cost.ts";
import { CIRCUIT_BREAKER_MULTIPLIER, USD_PER_CREDIT } from "./config.ts";
import { modelById } from "./models.ts";

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

// ---- the six selectable models (multi-model plan §1.1; F8 mirror) -----------

Deno.test("chatCostUsd: openai:gpt-5.4-mini priced from the table", () => {
  // 1M in @ $0.75, 1M out @ $4.5 → $5.25
  assertAlmostEquals(chatCostUsd("openai", "gpt-5.4-mini", M, M)!, 5.25, 1e-9);
});

Deno.test("chatCostUsd: openai:gpt-5.5 priced from the table", () => {
  // 1M in @ $5.0, 1M out @ $30.0 → $35.0
  assertAlmostEquals(chatCostUsd("openai", "gpt-5.5", M, M)!, 35.0, 1e-9);
});

Deno.test("chatCostUsd: anthropic:claude-sonnet-4-6 priced from the table", () => {
  // 1M in @ $3.0, 1M out @ $15.0 → $18.0
  assertAlmostEquals(chatCostUsd("anthropic", "claude-sonnet-4-6", M, M)!, 18.0, 1e-9);
});

Deno.test("chatCostUsd: anthropic:claude-opus-4-7 priced from the table", () => {
  // 1M in @ $5.0, 1M out @ $25.0 → $30.0
  assertAlmostEquals(chatCostUsd("anthropic", "claude-opus-4-7", M, M)!, 30.0, 1e-9);
});

// ---- creditCostForModel: fixed price + circuit-breaker (plan §1.2) ----------

Deno.test("creditCostForModel: normal cost charges the fixed price", () => {
  // Realistic flash generation (~$0.04) is far below 3 × 4 × $0.01 = $0.12.
  assertEquals(creditCostForModel("gemini-3.5-flash", 0.04), 4);
  // Opus at its expected ~$0.07 is below 3 × 10 × $0.01 = $0.30.
  assertEquals(creditCostForModel("claude-opus-4-7", 0.07), 10);
});

Deno.test("creditCostForModel: boundary — exactly 3× the fixed price still charges fixed (> not >=)", () => {
  const fixed = modelById("gemini-3.5-flash")!.creditPrice; // 4
  const breakerUsd = CIRCUIT_BREAKER_MULTIPLIER * fixed * USD_PER_CREDIT; // computed exactly as the impl does
  assertEquals(creditCostForModel("gemini-3.5-flash", breakerUsd), fixed);
});

Deno.test("creditCostForModel: just above the boundary charges the metered ceil amount", () => {
  // $0.121 > $0.12 → ceil(0.121 / 0.01) = 13 credits.
  assertEquals(creditCostForModel("gemini-3.5-flash", 0.121), 13);
  // Way over (abuse case): $1.00 on gpt-5.4-mini (fixed 2, breaker at $0.06) → 100.
  assertEquals(creditCostForModel("gpt-5.4-mini", 1.0), 100);
});

Deno.test("creditCostForModel: metered amount rounds UP to the next whole credit", () => {
  // $0.305 on flash → ceil(30.5) = 31, never 30.
  assertEquals(creditCostForModel("gemini-3.5-flash", 0.305), 31);
});

Deno.test("creditCostForModel: null/non-finite est cost falls back to the fixed price", () => {
  assertEquals(creditCostForModel("claude-sonnet-4-6", null), 7);
  assertEquals(creditCostForModel("claude-sonnet-4-6", Number.NaN), 7);
  assertEquals(creditCostForModel("claude-sonnet-4-6", Number.POSITIVE_INFINITY), 7);
});

Deno.test("creditCostForModel: unknown model throws (caller bug — validation is upstream)", () => {
  assertThrows(() => creditCostForModel("gpt-9-imaginary", 0.01), Error, "unknown model");
});
