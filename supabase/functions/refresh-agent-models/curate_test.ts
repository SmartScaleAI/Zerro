import { assert, assertEquals } from "jsr:@std/assert@1";
import { curate, deriveOpenAIDisplayName, type FetchedModel } from "./curate.ts";

// ---- OpenAI display-name derivation ----------------------------------------

Deno.test("deriveOpenAIDisplayName: GPT family glues version to brand", () => {
  assertEquals(deriveOpenAIDisplayName("gpt-5"), "GPT-5");
  assertEquals(deriveOpenAIDisplayName("gpt-5.5"), "GPT-5.5");
  assertEquals(deriveOpenAIDisplayName("gpt-5.5-mini"), "GPT-5.5 Mini");
  assertEquals(deriveOpenAIDisplayName("gpt-5-nano"), "GPT-5 Nano");
});

Deno.test("deriveOpenAIDisplayName: Codex family", () => {
  assertEquals(deriveOpenAIDisplayName("codex"), "Codex");
  assertEquals(deriveOpenAIDisplayName("codex-mini"), "Codex Mini");
});

// ---- Anthropic curation -----------------------------------------------------

Deno.test("curate(anthropic): keeps opus/sonnet/haiku-N, drops the rest", () => {
  const models: FetchedModel[] = [
    { id: "claude-opus-4-8", displayName: "Claude Opus 4.8", createdAt: 300 },
    { id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", createdAt: 200 },
    { id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", createdAt: 100 },
    { id: "claude-2.1", displayName: "Claude 2.1", createdAt: 50 }, // no family-N
    { id: "claude-3-opus-20240229", displayName: "old", createdAt: 10 }, // wrong shape
  ];
  const rows = curate("anthropic", models);
  assertEquals(rows.map((r) => r.model_id), [
    "claude-opus-4-8",
    "claude-sonnet-4-6",
    "claude-haiku-4-5",
  ]);
});

Deno.test("curate(anthropic): ranks newest-first, rank 0 = newest, uses display_name", () => {
  const models: FetchedModel[] = [
    { id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", createdAt: 200 },
    { id: "claude-opus-4-8", displayName: "Claude Opus 4.8", createdAt: 300 },
  ];
  const rows = curate("anthropic", models);
  assertEquals(rows[0], {
    provider: "anthropic",
    model_id: "claude-opus-4-8",
    display_name: "Claude Opus 4.8",
    rank: 0,
  });
  assertEquals(rows[1].model_id, "claude-sonnet-4-6");
  assertEquals(rows[1].rank, 1);
});

Deno.test("curate(anthropic): falls back to id when display_name is blank", () => {
  const rows = curate("anthropic", [
    { id: "claude-opus-4-8", displayName: "   ", createdAt: 1 },
  ]);
  assertEquals(rows[0].display_name, "claude-opus-4-8");
});

// ---- OpenAI curation --------------------------------------------------------

Deno.test("curate(openai): keeps the gpt-*-codex* family, drops base/size/dated/non-chat", () => {
  // Mirrors the live /v1/models response (2026-06-18).
  const models: FetchedModel[] = [
    { id: "gpt-5.3-codex", createdAt: 530 },
    { id: "gpt-5.1-codex-max", createdAt: 511 },
    { id: "gpt-5.1-codex-mini", createdAt: 510 },
    { id: "gpt-5-codex", createdAt: 500 },
    { id: "gpt-5.5", createdAt: 600 }, // base chat — NOT a Codex model
    { id: "gpt-5.5-pro", createdAt: 601 }, // reasoning variant — excluded
    { id: "gpt-5-mini", createdAt: 480 }, // size variant — excluded
    { id: "gpt-5.1-codex-2026-01-01", createdAt: 515 }, // dated dupe — excluded
    { id: "gpt-4o", createdAt: 300 }, // not codex
    { id: "text-embedding-3-large", createdAt: 200 }, // excluded
  ];
  const rows = curate("openai", models);
  assertEquals(rows.map((r) => r.model_id), [
    "gpt-5.3-codex",
    "gpt-5.1-codex-max",
    "gpt-5.1-codex-mini",
    "gpt-5-codex",
  ]);
});

Deno.test("curate(openai): ranks newest-first and derives codex display names", () => {
  const rows = curate("openai", [
    { id: "gpt-5-codex", createdAt: 100 },
    { id: "gpt-5.3-codex", createdAt: 200 },
  ]);
  assertEquals(rows[0], {
    provider: "openai",
    model_id: "gpt-5.3-codex",
    display_name: "GPT-5.3 Codex",
    rank: 0,
  });
  assertEquals(rows[1].display_name, "GPT-5 Codex");
});

// ---- Cross-cutting ----------------------------------------------------------

Deno.test("curate: stable tie-break by id when createdAt is equal", () => {
  const rows = curate("anthropic", [
    { id: "claude-sonnet-4-6", displayName: "s", createdAt: 100 },
    { id: "claude-opus-4-8", displayName: "o", createdAt: 100 },
  ]);
  // equal createdAt -> localeCompare ascending: "claude-opus" < "claude-sonnet"
  assertEquals(rows.map((r) => r.model_id), ["claude-opus-4-8", "claude-sonnet-4-6"]);
});

Deno.test("curate: de-dupes a repeated model_id", () => {
  const rows = curate("openai", [
    { id: "gpt-5-codex", createdAt: 200 },
    { id: "gpt-5-codex", createdAt: 200 },
  ]);
  assertEquals(rows.length, 1);
});

Deno.test("curate: empty input -> empty output (refresh treats this as a skip)", () => {
  assert(curate("anthropic", []).length === 0);
  assert(curate("openai", []).length === 0);
});
