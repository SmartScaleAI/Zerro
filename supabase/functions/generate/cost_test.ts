import "./test_setup.ts"; // sets test env before config.ts loads.

import { assertAlmostEquals, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  chatCostUsd,
  creditCostForModel,
  estimatedCostUsd,
  sttCostUsd,
} from "./cost.ts";
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

// ---- creditCostForModel: always metered on real cost (plan §1.2) ------------

Deno.test("creditCostForModel: normal cost meters to ceil(usd / USD_PER_CREDIT)", () => {
  // $0.045 → ceil(4.5) = 5 credits, independent of the model's fallbackCredits.
  assertEquals(creditCostForModel("gemini-3.5-flash", 0.045), 5);
  // $0.025 → ceil(2.5) = 3, NOT opus's fallbackCredits of 10 — the charge is the
  // real metered cost, not the per-model fallback.
  assertEquals(creditCostForModel("claude-opus-4-7", 0.025), 3);
  // Rounds UP to the next whole credit: $0.305 → ceil(30.5) = 31, never 30.
  assertEquals(creditCostForModel("gemini-3.5-flash", 0.305), 31);
  // A heavy/abusive workload is metered straight through (no breaker cap):
  // $1.00 → 100 credits.
  assertEquals(creditCostForModel("gpt-5.4-mini", 1.0), 100);
});

Deno.test("creditCostForModel: a tiny cost still charges the floor of 1 credit", () => {
  // Sub-cent real cost must never charge 0 on a successful generation.
  assertEquals(creditCostForModel("gemini-3.5-flash", 0.002), 1);
  assertEquals(creditCostForModel("gpt-5.4-mini", 0.0001), 1);
  // Exactly $0 (e.g. a no-speech, no-priced-frames edge) still floors to 1.
  assertEquals(creditCostForModel("claude-sonnet-4-6", 0), 1);
});

Deno.test("creditCostForModel: null/non-finite est cost falls back to fallbackCredits", () => {
  // Unpriced model / missing usage → the per-model fallback estimate, never 0.
  assertEquals(creditCostForModel("claude-sonnet-4-6", null), modelById("claude-sonnet-4-6")!.fallbackCredits);
  assertEquals(creditCostForModel("claude-sonnet-4-6", Number.NaN), 7);
  assertEquals(creditCostForModel("claude-sonnet-4-6", Number.POSITIVE_INFINITY), 7);
  assertEquals(creditCostForModel("gpt-5.4-mini", null), 2);
});

Deno.test("creditCostForModel: unknown model throws (caller bug — validation is upstream)", () => {
  assertThrows(() => creditCostForModel("gpt-9-imaginary", 0.01), Error, "unknown model");
});

// The pre-generation credit ESTIMATOR (estimateGenerationCredits + its
// estimate↔charge-headroom consistency tests) was removed with the estimate
// gate: the one final generation is uncapped and metered on the REAL post-chat
// cost, so there is no longer a pre-chat estimate to test. See handler step 8
// (the `remaining < 1` floor gate) for the only remaining credit decision.

// ---- B-06: a missing usage block must fall back, never undercharge ----------

Deno.test("chatCostUsd: null tokens (usage block absent) → null even on a PRICED model", () => {
  // The old `?? 0` coalesce made a usage-less response look like a finite $0
  // chat, so STT alone set the charge (~1-2 credits). Null tokens must yield a
  // null (unknown) cost so creditCostForModel charges fallbackCredits instead.
  assertEquals(chatCostUsd("openai", "gpt-4o", null, M), null);
  assertEquals(chatCostUsd("openai", "gpt-4o", M, null), null);
  assertEquals(chatCostUsd("anthropic", "claude-opus-4-7", null, null), null);
});

Deno.test("estimatedCostUsd: null tokens → null total (never a partial STT-only number)", () => {
  assertEquals(estimatedCostUsd(60, "openai", "gpt-5.5", null, M), null);
  assertEquals(estimatedCostUsd(60, "openai", "gpt-5.5", M, null), null);
  assertEquals(estimatedCostUsd(60, "gemini", "gemini-3.5-flash", null, null), null);
});

Deno.test("B-06: null-usage generation on a priced model charges exactly fallbackCredits", () => {
  // End-to-end through the cost helpers: usage absent → null est → the model's
  // fallbackCredits, NOT the ~1-credit STT-only charge the 0-coalesce produced.
  for (const id of ["gemini-3.5-flash", "claude-opus-4-7", "gpt-5.5"]) {
    const entry = modelById(id)!;
    const est = estimatedCostUsd(60, entry.provider, id, null, null);
    assertEquals(est, null, id);
    assertEquals(creditCostForModel(id, est), entry.fallbackCredits, id);
  }
});
