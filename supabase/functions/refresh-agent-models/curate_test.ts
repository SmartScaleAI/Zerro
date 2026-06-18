import { assert, assertEquals } from "jsr:@std/assert@1";
import { curate, type FetchedModel } from "./curate.ts";

Deno.test("curate: keeps opus/sonnet/haiku-N, drops the rest", () => {
  const models: FetchedModel[] = [
    { id: "claude-opus-4-8", displayName: "Claude Opus 4.8", createdAt: 300 },
    { id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", createdAt: 200 },
    { id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", createdAt: 100 },
    { id: "claude-2.1", displayName: "Claude 2.1", createdAt: 50 }, // no family-N
    { id: "claude-3-opus-20240229", displayName: "old", createdAt: 10 }, // wrong shape
  ];
  assertEquals(curate(models).map((r) => r.model_id), [
    "claude-opus-4-8",
    "claude-sonnet-4-6",
    "claude-haiku-4-5",
  ]);
});

Deno.test("curate: ranks newest-first, rank 0 = newest, uses display_name", () => {
  const models: FetchedModel[] = [
    { id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", createdAt: 200 },
    { id: "claude-opus-4-8", displayName: "Claude Opus 4.8", createdAt: 300 },
  ];
  const rows = curate(models);
  assertEquals(rows[0], {
    provider: "anthropic",
    model_id: "claude-opus-4-8",
    display_name: "Claude Opus 4.8",
    rank: 0,
  });
  assertEquals(rows[1].model_id, "claude-sonnet-4-6");
  assertEquals(rows[1].rank, 1);
});

Deno.test("curate: falls back to id when display_name is blank", () => {
  const rows = curate([{ id: "claude-opus-4-8", displayName: "   ", createdAt: 1 }]);
  assertEquals(rows[0].display_name, "claude-opus-4-8");
});

Deno.test("curate: stable tie-break by id when createdAt is equal", () => {
  const rows = curate([
    { id: "claude-sonnet-4-6", displayName: "s", createdAt: 100 },
    { id: "claude-opus-4-8", displayName: "o", createdAt: 100 },
  ]);
  // equal createdAt -> localeCompare ascending: "claude-opus" < "claude-sonnet"
  assertEquals(rows.map((r) => r.model_id), ["claude-opus-4-8", "claude-sonnet-4-6"]);
});

Deno.test("curate: de-dupes a repeated model_id", () => {
  const rows = curate([
    { id: "claude-opus-4-8", displayName: "o", createdAt: 200 },
    { id: "claude-opus-4-8", displayName: "o", createdAt: 200 },
  ]);
  assertEquals(rows.length, 1);
});

Deno.test("curate: empty input -> empty output (refresh treats this as a skip)", () => {
  assert(curate([]).length === 0);
});

Deno.test("curate: a non-anthropic id never slips through (OpenAI retired)", () => {
  const rows = curate([
    { id: "gpt-5.5", createdAt: 500 },
    { id: "gpt-5-codex", createdAt: 400 },
    { id: "claude-opus-4-8", displayName: "Claude Opus 4.8", createdAt: 300 },
  ]);
  assertEquals(rows.map((r) => r.model_id), ["claude-opus-4-8"]);
});
