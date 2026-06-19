// =============================================================================
// refresh-agent-models — provider model-list fetcher (Anthropic only).
// =============================================================================
// Reads Anthropic's LIVE model catalog using the SAME ANTHROPIC_API_KEY the
// `generate` proxy already holds. THROWS on any non-OK status or transport
// error — refresh.ts treats a throw as "leave the rows untouched" (never wipe
// on a failed fetch). `fetchImpl` is injectable so tests can stub the wire.
// (OpenAI is retired — Codex sources its own per-account list client-side.)
//
//   Anthropic GET /v1/models   x-api-key, anthropic-version: 2023-06-01
//                              -> { data: [{ id, display_name, created_at }], has_more, ... }
// =============================================================================

import type { FetchedModel } from "./curate.ts";

const ANTHROPIC_BASE = "https://api.anthropic.com/v1";
const ANTHROPIC_VERSION = "2023-06-01";

/** Network-call timeout — the list endpoint is small + fast. */
const FETCH_TIMEOUT_MS = 15_000;
/** Page size for Anthropic's paginated list (its max), so one page suffices. */
const ANTHROPIC_PAGE_LIMIT = 1000;

export type FetchImpl = typeof fetch;

async function getJson(
  url: string,
  headers: Record<string, string>,
  fetchImpl: FetchImpl,
): Promise<unknown> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetchImpl(url, { method: "GET", headers, signal: ctrl.signal });
  } catch (e) {
    throw new Error(`transport_error: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) {
    // Drain the body so the connection closes cleanly; status is what matters.
    await res.text().catch(() => undefined);
    throw new Error(`http_${res.status}`);
  }
  return await res.json();
}

/**
 * Fetch Anthropic's model catalog. Requests the max page size so the small
 * (<100) catalog returns in one page; if the provider ever exceeds that we
 * still get the newest page (the list is created-desc) — logged, not silently
 * truncated, by the caller via the returned count.
 */
export async function fetchAnthropicModels(
  apiKey: string,
  fetchImpl: FetchImpl = fetch,
): Promise<FetchedModel[]> {
  const body = await getJson(
    `${ANTHROPIC_BASE}/models?limit=${ANTHROPIC_PAGE_LIMIT}`,
    {
      "x-api-key": apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
    },
    fetchImpl,
  );
  const data = (body as { data?: unknown }).data;
  if (!Array.isArray(data)) throw new Error("malformed_response: missing data[]");
  return data.map((m): FetchedModel => {
    const row = m as { id?: unknown; display_name?: unknown; created_at?: unknown };
    return {
      id: String(row.id ?? ""),
      displayName: typeof row.display_name === "string" ? row.display_name : undefined,
      createdAt: toUnixSeconds(row.created_at),
    };
  }).filter((m) => m.id !== "");
}

/** Coerce Anthropic's ISO `created_at` (or epoch) to unix seconds; 0 if absent. */
function toUnixSeconds(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const ms = Date.parse(value);
    if (Number.isFinite(ms)) return Math.floor(ms / 1000);
  }
  return 0;
}
