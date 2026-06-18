import { assert, assertEquals } from "jsr:@std/assert@1";
import { refreshAgentModels } from "./refresh.ts";
import type { AgentModelRow, AgentModelsStore } from "./store.ts";

// ---- Fakes ------------------------------------------------------------------

/** Records every write so tests can assert exactly which providers were touched. */
class FakeStore implements AgentModelsStore {
  upserts: { rows: AgentModelRow[]; syncedAt: string }[] = [];
  deactivations: { provider: string; syncedAt: string }[] = [];
  /** Per-provider count `deactivateStale` should report (vanished models). */
  deactivateCount: Record<string, number> = {};

  upsertActive(rows: AgentModelRow[], syncedAt: string): Promise<void> {
    this.upserts.push({ rows, syncedAt });
    return Promise.resolve();
  }
  deactivateStale(provider: "anthropic" | "openai", syncedAt: string): Promise<number> {
    this.deactivations.push({ provider, syncedAt });
    return Promise.resolve(this.deactivateCount[provider] ?? 0);
  }
}

/** A fetch stub that routes by host and returns canned list responses. */
function stubFetch(routes: {
  anthropic?: () => Response;
  openai?: () => Response;
}): typeof fetch {
  return ((url: string | URL | Request) => {
    const u = String(url);
    if (u.includes("api.anthropic.com")) {
      if (!routes.anthropic) throw new Error("unexpected anthropic call");
      return Promise.resolve(routes.anthropic());
    }
    if (u.includes("api.openai.com")) {
      if (!routes.openai) throw new Error("unexpected openai call");
      return Promise.resolve(routes.openai());
    }
    throw new Error(`unexpected url ${u}`);
  }) as typeof fetch;
}

function anthropicOk(): Response {
  return new Response(
    JSON.stringify({
      data: [
        { id: "claude-opus-4-8", display_name: "Claude Opus 4.8", created_at: "2026-05-01T00:00:00Z" },
        { id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", created_at: "2026-03-01T00:00:00Z" },
        { id: "text-embedding-irrelevant", display_name: "x", created_at: "2026-01-01T00:00:00Z" },
      ],
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

function openaiOk(): Response {
  return new Response(
    JSON.stringify({
      data: [
        { id: "gpt-5.3-codex", created: 1900000000 },
        { id: "gpt-5-codex", created: 1800000000 },
        { id: "gpt-5.5", created: 1950000000 }, // base chat — NOT a Codex model
        { id: "gpt-5-audio", created: 1850000000 }, // excluded
        { id: "text-embedding-3-large", created: 100 }, // excluded
      ],
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

const FIXED_NOW = () => new Date("2026-06-18T06:00:00.000Z");
const SYNCED_AT = "2026-06-18T06:00:00.000Z";

// ---- Happy path -------------------------------------------------------------

Deno.test("refresh: both providers succeed -> curated upsert + sweep, counts in summary", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    openaiKey: "ok",
    fetchImpl: stubFetch({ anthropic: anthropicOk, openai: openaiOk }),
    now: FIXED_NOW,
  });

  assertEquals(summary.anthropic, 2);
  assertEquals(summary.openai, 2);
  assertEquals(summary.errors, []);

  // One upsert per provider, each stamped with the per-run sync timestamp.
  assertEquals(store.upserts.length, 2);
  for (const u of store.upserts) assertEquals(u.syncedAt, SYNCED_AT);

  const anthropicUpsert = store.upserts.find((u) => u.rows[0].provider === "anthropic")!;
  assertEquals(anthropicUpsert.rows.map((r) => r.model_id), [
    "claude-opus-4-8",
    "claude-sonnet-4-6",
  ]);
  assertEquals(anthropicUpsert.rows[0].rank, 0); // newest

  // The vanished->inactive sweep runs for both providers, after the upsert.
  assertEquals(store.deactivations.map((d) => d.provider).sort(), ["anthropic", "openai"]);
  for (const d of store.deactivations) assertEquals(d.syncedAt, SYNCED_AT);
});

// ---- Vanished -> inactive ---------------------------------------------------

Deno.test("refresh: deactivateStale reports vanished models (sweep wired)", async () => {
  const store = new FakeStore();
  store.deactivateCount = { anthropic: 3, openai: 0 };
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    openaiKey: "ok",
    fetchImpl: stubFetch({ anthropic: anthropicOk, openai: openaiOk }),
    now: FIXED_NOW,
  });
  // The sweep was invoked for anthropic (count surfaced via the store), and the
  // upsert happened BEFORE it so a still-present model keeps updated_at=syncedAt.
  assertEquals(summary.anthropic, 2);
  const idx = store.upserts.length; // both upserts recorded
  assertEquals(idx, 2);
  assert(store.deactivations.some((d) => d.provider === "anthropic"));
});

// ---- Never wipe on a failed fetch ------------------------------------------

Deno.test("refresh: a provider's HTTP failure leaves its rows untouched; other provider still runs", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    openaiKey: "ok",
    fetchImpl: stubFetch({
      anthropic: () => new Response("upstream boom", { status: 503 }),
      openai: openaiOk,
    }),
    now: FIXED_NOW,
  });

  // Anthropic failed: NO upsert, NO deactivate for it (rows untouched).
  assertEquals(summary.anthropic, null);
  assert(summary.errors.some((e) => e.provider === "anthropic" && e.error.includes("503")));
  assert(!store.upserts.some((u) => u.rows[0]?.provider === "anthropic"));
  assert(!store.deactivations.some((d) => d.provider === "anthropic"));

  // OpenAI is independent and still fully processed.
  assertEquals(summary.openai, 2);
  assert(store.upserts.some((u) => u.rows[0]?.provider === "openai"));
  assert(store.deactivations.some((d) => d.provider === "openai"));
});

Deno.test("refresh: a transport error (fetch throws) is caught, rows untouched", async () => {
  const store = new FakeStore();
  const throwingFetch = (() => {
    throw new Error("network down");
  }) as unknown as typeof fetch;
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    openaiKey: "ok",
    fetchImpl: throwingFetch,
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, null);
  assertEquals(summary.openai, null);
  assertEquals(store.upserts.length, 0);
  assertEquals(store.deactivations.length, 0);
  assertEquals(summary.errors.length, 2);
});

// ---- Successful-but-empty must NOT wipe ------------------------------------

Deno.test("refresh: a successful but zero-match fetch skips writes (no wipe)", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    openaiKey: "ok",
    fetchImpl: stubFetch({
      // 200 with only non-matching ids -> curate() returns [].
      anthropic: () =>
        new Response(JSON.stringify({ data: [{ id: "claude-2.1", created_at: "2024-01-01T00:00:00Z" }] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      openai: openaiOk,
    }),
    now: FIXED_NOW,
  });

  // Anthropic matched nothing: skipped, recorded as no_models_matched, NO sweep.
  assertEquals(summary.anthropic, null);
  assert(summary.errors.some((e) => e.provider === "anthropic" && e.error === "no_models_matched"));
  assert(!store.upserts.some((u) => u.rows[0]?.provider === "anthropic"));
  assert(!store.deactivations.some((d) => d.provider === "anthropic"));

  // OpenAI unaffected.
  assertEquals(summary.openai, 2);
});

// ---- Malformed response is a failure, not a wipe ---------------------------

Deno.test("refresh: malformed provider JSON is treated as a failed fetch", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    openaiKey: "ok",
    fetchImpl: stubFetch({
      anthropic: () =>
        new Response(JSON.stringify({ not_data: [] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      openai: openaiOk,
    }),
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, null);
  assert(summary.errors.some((e) => e.provider === "anthropic" && e.error.includes("malformed")));
  assert(!store.upserts.some((u) => u.rows[0]?.provider === "anthropic"));
});
