// =============================================================================
// LemonSqueezy live status client — the §14.6 missed-webhook money-leak guard.
// =============================================================================
// LemonSqueezy is the system of record; our `subscriptions` table is a webhook-
// fed MIRROR. If a `subscription_cancelled` / `_expired` webhook is DROPPED, the
// mirror would keep showing `active` forever and `session` would keep minting
// tokens for a non-paying user. The guard: when the mirror is STALE (no webhook
// or prior live re-check within the staleness window), `session` calls THIS
// client to confirm the subscription is still live with LemonSqueezy before
// minting (see session/handler.ts).
//
// This client is read-only — it never mutates LemonSqueezy. It needs a
// LEMONSQUEEZY_API_KEY (an API key from LS Settings → API), distinct from the
// webhook signing secret. The transport is behind the `LemonSqueezyClient`
// interface so the session handler depends on the interface, not on `fetch` —
// tests inject a stub and never hit the network.
//
// FAIL-OPEN ON INCONCLUSIVE: every transport/parse failure returns `null`
// ("couldn't determine"), and the session handler treats null as fail-open
// (mint anyway). A LemonSqueezy outage must NEVER lock a paying user out — the
// guard only acts on a CONCLUSIVE cancelled/expired answer. Spend is still gated
// server-side at generate time regardless.
// =============================================================================

/** The normalized status the guard reasons about (matches our mirror enum). */
export type LsLiveStatus = "active" | "past_due" | "cancelled" | "expired";

export interface LemonSqueezyClient {
  /**
   * Live status of a LemonSqueezy subscription, or `null` if it could not be
   * determined (network error, non-200, unparseable, unknown status string).
   * `null` MUST be treated as inconclusive → fail-open by the caller.
   */
  getSubscriptionStatus(lsSubscriptionId: string): Promise<LsLiveStatus | null>;
}

/**
 * Map a raw LemonSqueezy subscription status string to our normalized enum.
 * LS statuses: active | on_trial | paused | past_due | unpaid | cancelled |
 * expired. We mirror the webhook's own semantics so a live re-check and a
 * delivered webhook reconcile the mirror to the SAME value:
 *   - active / on_trial / paused → "active"  (entitled; generation allowed)
 *   - past_due                    → "past_due" (entitled on remaining credits, §9.1)
 *   - cancelled                   → "cancelled" (terminal; session refuses, §9)
 *   - unpaid / expired            → "expired"   (terminal; session refuses)
 *   - anything unknown            → null        (inconclusive → fail-open)
 */
export function normalizeLsStatus(raw: string | null | undefined): LsLiveStatus | null {
  switch ((raw ?? "").toLowerCase()) {
    case "active":
    case "on_trial":
    case "paused":
      return "active";
    case "past_due":
      return "past_due";
    case "cancelled":
      return "cancelled";
    case "unpaid":
    case "expired":
      return "expired";
    default:
      return null; // unknown / empty → inconclusive
  }
}

/** Real transport. Reads the API key once; one retry on a transient fault. */
export class HttpLemonSqueezyClient implements LemonSqueezyClient {
  constructor(
    private readonly apiKey: string,
    private readonly base: string = "https://api.lemonsqueezy.com/v1",
    private readonly timeoutMs: number = 8_000,
  ) {}

  async getSubscriptionStatus(lsSubscriptionId: string): Promise<LsLiveStatus | null> {
    const url = `${this.base}/subscriptions/${encodeURIComponent(lsSubscriptionId)}`;
    const send = async (): Promise<Response | null> => {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
      try {
        return await fetch(url, {
          method: "GET",
          headers: {
            Authorization: `Bearer ${this.apiKey}`,
            Accept: "application/vnd.api+json",
          },
          signal: ctrl.signal,
        });
      } catch {
        return null; // network/abort → inconclusive
      } finally {
        clearTimeout(timer);
      }
    };

    let res = await send();
    // Retry once on a transient fault (network error or 5xx).
    if (res === null || res.status >= 500) res = await send();
    if (res === null) return null;
    if (!res.ok) {
      // 401/403 (bad/absent API key), 404 (unknown id), etc. → inconclusive.
      // Never revoke on a non-200; only a CONCLUSIVE cancelled/expired revokes.
      console.error(
        JSON.stringify({ fn: "lemonsqueezy_client", warn: "non_ok_status", status: res.status }),
      );
      return null;
    }

    try {
      const json = await res.json();
      const status = json?.data?.attributes?.status;
      return normalizeLsStatus(typeof status === "string" ? status : null);
    } catch {
      return null; // unparseable → inconclusive
    }
  }
}
