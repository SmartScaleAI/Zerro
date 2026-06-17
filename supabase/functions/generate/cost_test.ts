import "./test_setup.ts"; // sets test env before config.ts loads.

import { assert, assertAlmostEquals, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  chatCostUsd,
  creditCostForModel,
  estimateGenerationCredits,
  estimatedCostUsd,
  sttCostUsd,
} from "./cost.ts";
import { modelById } from "./models.ts";
import {
  FRAME_TOKENS_OPENAI,
  HEADROOM_CREDITS,
  OUTPUT_TOKENS_ESTIMATE,
  SYSTEM_PROMPT_TOKENS,
} from "./config.ts";

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

// ---- estimateGenerationCredits: preflight estimate for the gate (Phase 2) ----

Deno.test("estimateGenerationCredits: a heavy recording estimates higher than a light one", () => {
  const light = estimateGenerationCredits({
    provider: "gemini",
    model: "gemini-3.5-flash",
    frameCount: 3,
    transcriptChars: 200,
    ocrChars: 0,
    audioSeconds: 15,
  });
  const heavy = estimateGenerationCredits({
    provider: "gemini",
    model: "gemini-3.5-flash",
    frameCount: 28,
    transcriptChars: 4000,
    ocrChars: 2000,
    audioSeconds: 180,
  });
  // More frames + transcript + OCR + audio must cost more.
  assert(heavy > light, `heavy (${heavy}) should exceed light (${light})`);
  // Both land in a sane range — a light recording is a handful of credits, a
  // heavy one is bounded well under the per-recording hard cap (~44).
  assert(light >= 1 && light <= 10, `light out of range: ${light}`);
  assert(heavy >= light && heavy <= 44, `heavy out of range: ${heavy}`);
});

Deno.test("estimateGenerationCredits: a pricier model estimates higher for the same inputs", () => {
  const inputs = { frameCount: 10, transcriptChars: 1000, ocrChars: 500, audioSeconds: 60 };
  const flash = estimateGenerationCredits({ provider: "gemini", model: "gemini-3.5-flash", ...inputs });
  const opus = estimateGenerationCredits({ provider: "anthropic", model: "claude-opus-4-7", ...inputs });
  assert(opus > flash, `opus (${opus}) should exceed flash (${flash}) on identical inputs`);
});

Deno.test("estimateGenerationCredits: unpriced model falls back to fallbackCredits, never 0", () => {
  // gpt-4o has no registry entry → modelById is undefined → floor of 1. But more
  // importantly, an unknown chat model makes estimatedCostUsd null, exercising the
  // fallback branch. Using a real registry model with an unpriced *id* isn't
  // possible (all six are priced), so assert the unknown-id floor here.
  const est = estimateGenerationCredits({
    provider: "openai",
    model: "gpt-9-imaginary",
    frameCount: 5,
    transcriptChars: 100,
    ocrChars: 0,
    audioSeconds: 30,
  });
  assertEquals(est, 1); // unknown id → fallbackCredits ?? 1
});

// ---- gate ↔ charge consistency (the headroom holds) -------------------------

Deno.test("estimate and metered charge agree within HEADROOM for a heavy gpt-5.5 recording", () => {
  // A representative heavy gpt-5.5 recording (28 frames, long transcript + OCR,
  // 3 min). The PREFLIGHT estimate (gate input) is computed from the known
  // inputs + a conservative output allowance; the ACTUAL metered charge is
  // computed post-chat from real token usage. The gate is only sound if the
  // estimate doesn't UNDER-shoot the real charge by more than the headroom —
  // i.e. estimate >= actual - HEADROOM_CREDITS. Here we model the real output
  // OVERSHOOTING the estimate's allowance to prove the headroom absorbs it.
  const heavy = {
    provider: "openai",
    model: "gpt-5.5",
    frameCount: 28,
    transcriptChars: 4000,
    ocrChars: 2000,
    audioSeconds: 180,
  };
  const estimate = estimateGenerationCredits(heavy);

  // Reconstruct the input tokens the estimator used (these are KNOWN exactly
  // pre-chat — system prompt + per-frame image tokens + chars/4), then model a
  // real generation whose OUTPUT ran 1000 tokens past the conservative
  // OUTPUT_TOKENS_ESTIMATE allowance.
  const inputTokens = SYSTEM_PROMPT_TOKENS +
    heavy.frameCount * FRAME_TOKENS_OPENAI +
    Math.ceil(heavy.transcriptChars / 4) +
    Math.ceil(heavy.ocrChars / 4);
  const actualOutputTokens = OUTPUT_TOKENS_ESTIMATE + 1000;
  const actualUsd = estimatedCostUsd(heavy.audioSeconds, heavy.provider, heavy.model, inputTokens, actualOutputTokens);
  const actual = creditCostForModel(heavy.model, actualUsd);

  // The gate's estimate is within HEADROOM of the real charge — it never
  // under-estimates the spend by more than the tolerance the gate allows.
  assert(
    estimate >= actual - HEADROOM_CREDITS,
    `estimate ${estimate} should be >= actual ${actual} - headroom ${HEADROOM_CREDITS}`,
  );
  // And both are in the sane heavy range (well under the ~44-credit per-recording
  // hard cap), confirming neither blew up.
  assert(estimate >= 20 && estimate <= 44, `estimate out of range: ${estimate}`);
  assert(actual >= 20 && actual <= 44, `actual out of range: ${actual}`);
});
