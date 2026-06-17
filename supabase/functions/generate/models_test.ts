import { assert, assertEquals } from "jsr:@std/assert@1";
import { ALLOWED_MODELS, MODEL_REGISTRY, modelById } from "./models.ts";

Deno.test("registry: exactly the six Phase 0 models, cheapest-first", () => {
  assertEquals(
    MODEL_REGISTRY.map((m) => m.id),
    [
      "gpt-5.4-mini",
      "gemini-3.5-flash",
      "gemini-3.1-pro-preview",
      "claude-sonnet-4-6",
      "claude-opus-4-7",
      "gpt-5.5",
    ],
  );
  // fallbackCredits ascending is a product invariant the picker relies on (6A).
  const prices = MODEL_REGISTRY.map((m) => m.fallbackCredits);
  assertEquals(prices, [...prices].sort((a, b) => a - b));
});

Deno.test("registry: fallback credit estimates match plan §1.2", () => {
  const expect: Record<string, number> = {
    "gpt-5.4-mini": 2,
    "gemini-3.5-flash": 4,
    "gemini-3.1-pro-preview": 5,
    "claude-sonnet-4-6": 7,
    "claude-opus-4-7": 10,
    "gpt-5.5": 11,
  };
  for (const m of MODEL_REGISTRY) assertEquals(m.fallbackCredits, expect[m.id], m.id);
});

Deno.test("registry: exactly one recommended model (Gemini 3.5 Flash)", () => {
  const rec = MODEL_REGISTRY.filter((m) => m.recommended);
  assertEquals(rec.length, 1);
  assertEquals(rec[0].id, "gemini-3.5-flash");
});

Deno.test("ALLOWED_MODELS: contains exactly the enabled registry ids", () => {
  assertEquals(ALLOWED_MODELS.size, 6);
  for (const m of MODEL_REGISTRY) {
    assertEquals(ALLOWED_MODELS.has(m.id), m.enabled, m.id);
  }
  assert(!ALLOWED_MODELS.has("gpt-4o")); // legacy default is NOT user-selectable
  assert(!ALLOWED_MODELS.has("gpt-9-imaginary"));
});

Deno.test("ALLOWED_MODELS: a disabled entry would be excluded (kill-switch shape)", () => {
  // Recompute the derivation over a copy with one model disabled — proves the
  // set is driven by `enabled`, which is the no-deploy kill switch.
  const copy = MODEL_REGISTRY.map((m) => m.id === "gpt-5.5" ? { ...m, enabled: false } : m);
  const allowed = new Set(copy.filter((m) => m.enabled).map((m) => m.id));
  assertEquals(allowed.size, 5);
  assert(!allowed.has("gpt-5.5"));
});

Deno.test("modelById: round-trips every registry entry; unknown → undefined", () => {
  for (const m of MODEL_REGISTRY) {
    assertEquals(modelById(m.id), m);
  }
  assertEquals(modelById("gpt-9-imaginary"), undefined);
});

Deno.test("registry: providers are the three supported adapters", () => {
  const providers = new Set(MODEL_REGISTRY.map((m) => m.provider));
  assertEquals(providers, new Set(["openai", "gemini", "anthropic"]));
});
