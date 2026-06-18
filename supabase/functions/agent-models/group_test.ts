import { assertEquals } from "jsr:@std/assert@1";
import { groupByProvider, type ManifestRow } from "./group.ts";

Deno.test("groupByProvider: groups by provider, preserves input order, projects fields", () => {
  // Rows arrive ordered by the query: (provider asc, rank asc).
  const rows: ManifestRow[] = [
    { provider: "anthropic", model_id: "claude-opus-4-8", display_name: "Claude Opus 4.8" },
    { provider: "anthropic", model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6" },
    { provider: "openai", model_id: "gpt-5.5", display_name: "GPT-5.5" },
    { provider: "openai", model_id: "gpt-5.5-mini", display_name: "GPT-5.5 Mini" },
  ];
  assertEquals(groupByProvider(rows), {
    providers: {
      anthropic: [
        { model_id: "claude-opus-4-8", display_name: "Claude Opus 4.8" },
        { model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6" },
      ],
      openai: [
        { model_id: "gpt-5.5", display_name: "GPT-5.5" },
        { model_id: "gpt-5.5-mini", display_name: "GPT-5.5 Mini" },
      ],
    },
  });
});

Deno.test("groupByProvider: both provider keys always present, even when empty", () => {
  assertEquals(groupByProvider([]), { providers: { anthropic: [], openai: [] } });

  const onlyOpenai: ManifestRow[] = [
    { provider: "openai", model_id: "gpt-5.5", display_name: "GPT-5.5" },
  ];
  assertEquals(groupByProvider(onlyOpenai).providers.anthropic, []);
  assertEquals(groupByProvider(onlyOpenai).providers.openai.length, 1);
});

Deno.test("groupByProvider: ignores rows for an unknown provider", () => {
  const rows: ManifestRow[] = [
    { provider: "anthropic", model_id: "claude-opus-4-8", display_name: "Claude Opus 4.8" },
    { provider: "mystery", model_id: "x-1", display_name: "X" },
  ];
  const out = groupByProvider(rows);
  assertEquals(out.providers.anthropic.length, 1);
  assertEquals(out.providers.openai.length, 0);
});
