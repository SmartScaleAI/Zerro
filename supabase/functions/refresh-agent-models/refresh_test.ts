import { assert, assertEquals } from "jsr:@std/assert@1";
import { refreshAgentModels } from "./refresh.ts";
import type { AgentModelRow, AgentModelsStore } from "./store.ts";

// ---- Fakes ------------------------------------------------------------------

/** Records every write so tests can assert exactly what was touched. */
class FakeStore implements AgentModelsStore {
  upserts: { rows: AgentModelRow[]; syncedAt: string }[] = [];
  deactivations: { provider: string; syncedAt: string }[] = [];
  deactivateCount = 0;

  upsertActive(rows: AgentModelRow[], syncedAt: string): Promise<void> {
    this.upserts.push({ rows, syncedAt });
    return Promise.resolve();
  }
  deactivateStale(provider: "anthropic" | "openai", syncedAt: string): Promise<number> {
    this.deactivations.push({ provider, syncedAt });
    return Promise.resolve(this.deactivateCount);
  }
}

/** A fetch stub that returns a canned Anthropic list response (or an error). */
function stubFetch(response: () => Response): typeof fetch {
  return ((url: string | URL | Request) => {
    const u = String(url);
    if (!u.includes("api.anthropic.com")) throw new Error(`unexpected url ${u}`);
    return Promise.resolve(response());
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

const FIXED_NOW = () => new Date("2026-06-18T06:00:00.000Z");
const SYNCED_AT = "2026-06-18T06:00:00.000Z";

// ---- Happy path -------------------------------------------------------------

Deno.test("refresh: success -> curated upsert + sweep, count in summary", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    fetchImpl: stubFetch(anthropicOk),
    now: FIXED_NOW,
  });

  assertEquals(summary.anthropic, 2);
  assertEquals(summary.errors, []);

  assertEquals(store.upserts.length, 1);
  assertEquals(store.upserts[0].syncedAt, SYNCED_AT);
  assertEquals(store.upserts[0].rows.map((r) => r.model_id), ["claude-opus-4-8", "claude-sonnet-4-6"]);
  assertEquals(store.upserts[0].rows[0].rank, 0); // newest

  // The vanished->inactive sweep runs after the upsert, same timestamp.
  assertEquals(store.deactivations.map((d) => d.provider), ["anthropic"]);
  assertEquals(store.deactivations[0].syncedAt, SYNCED_AT);
});

Deno.test("refresh: deactivateStale reports vanished models (sweep wired)", async () => {
  const store = new FakeStore();
  store.deactivateCount = 3;
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    fetchImpl: stubFetch(anthropicOk),
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, 2);
  assertEquals(store.upserts.length, 1);
  assert(store.deactivations.some((d) => d.provider === "anthropic"));
});

// ---- Never wipe on a failed fetch ------------------------------------------

Deno.test("refresh: an HTTP failure leaves rows untouched", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    fetchImpl: stubFetch(() => new Response("upstream boom", { status: 503 })),
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, null);
  assert(summary.errors.some((e) => e.provider === "anthropic" && e.error.includes("503")));
  assertEquals(store.upserts.length, 0);
  assertEquals(store.deactivations.length, 0);
});

Deno.test("refresh: a transport error (fetch throws) is caught, rows untouched", async () => {
  const store = new FakeStore();
  const throwingFetch = (() => {
    throw new Error("network down");
  }) as unknown as typeof fetch;
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    fetchImpl: throwingFetch,
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, null);
  assertEquals(store.upserts.length, 0);
  assertEquals(store.deactivations.length, 0);
  assertEquals(summary.errors.length, 1);
});

// ---- Successful-but-empty must NOT wipe ------------------------------------

Deno.test("refresh: a successful but zero-match fetch skips writes (no wipe)", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    fetchImpl: stubFetch(() =>
      new Response(JSON.stringify({ data: [{ id: "claude-2.1", created_at: "2024-01-01T00:00:00Z" }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    ),
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, null);
  assert(summary.errors.some((e) => e.error === "no_models_matched"));
  assertEquals(store.upserts.length, 0);
  assertEquals(store.deactivations.length, 0);
});

// ---- Malformed response is a failure, not a wipe ---------------------------

Deno.test("refresh: malformed provider JSON is treated as a failed fetch", async () => {
  const store = new FakeStore();
  const summary = await refreshAgentModels({
    store,
    anthropicKey: "ak",
    fetchImpl: stubFetch(() =>
      new Response(JSON.stringify({ not_data: [] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    ),
    now: FIXED_NOW,
  });
  assertEquals(summary.anthropic, null);
  assert(summary.errors.some((e) => e.error.includes("malformed")));
  assertEquals(store.upserts.length, 0);
});
