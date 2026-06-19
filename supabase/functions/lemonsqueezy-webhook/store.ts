// =============================================================================
// WebhookStore — the DB operations the webhook handler needs (Phase G refactor).
// =============================================================================
// The handler depends on this domain-level interface, not on the Supabase
// client, so the lifecycle + idempotency + stale-drop logic is unit-testable
// with an in-memory fake (no Postgres). The production impl
// (SupabaseWebhookStore) wraps the SHARED service-role client and the SAME table
// operations the function has always used — this is a pure extraction, not a
// behavior change. RLS is unaffected: every op goes through the service role.
//
// `recordEvent` is the idempotency gate: a FRESH insert means "not yet
// processed"; a unique-violation (the composite event id already present) means
// "duplicate" (LemonSqueezy redelivers). That maps the raw 23505 here so the
// handler reasons in domain terms.
// =============================================================================

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { Tier } from "../_shared/config.ts";
import type { BillingInterval } from "./tier.ts";

export type Status = "active" | "past_due" | "cancelled" | "expired";

/** The subscription-mirror fields the handler reads back after a lookup. */
export interface MirrorSub {
  id: string;
  ls_updated_at: string | null;
}

/** A full subscription upsert row (subscription_created / first-seen updated). */
export interface SubscriptionUpsert {
  ls_subscription_id: string;
  ls_customer_id: string | null;
  /** Buyer email, lowercased + trimmed (attributes.user_email). Denormalized,
   *  mutable, non-key identifier for human lookups; null when LS omits it. */
  email_normalized: string | null;
  ls_order_id: string | null;
  tier: Tier;
  status: Status;
  current_period_end: string | null;
  credits_limit: number;
  /** 'monthly' | 'yearly' from the matched variant (Phase 5); null when the
   *  variant is unmapped. Metadata only — both intervals share the tier's
   *  allowance and 30-day reset cadence. */
  billing_interval: BillingInterval | null;
  ls_updated_at: string | null;
}

/** A partial mirror patch (status / tier / credits / period-end / ls_updated_at). */
export interface SubscriptionPatch {
  status?: Status;
  tier?: Tier;
  credits_limit?: number;
  current_period_end?: string | null;
  billing_interval?: BillingInterval | null;
  ls_updated_at?: string | null;
  license_key_hash?: string;
  /** Refresh the denormalized buyer email on subscription_updated (it can change
   *  in LemonSqueezy). Omitted when the event carries no user_email. */
  email_normalized?: string | null;
}

/** A top-up pack purchase (order_created → topup_credits row). */
export interface TopupInsert {
  subscriptionId: string;
  credits: number;
  expiresAt: string;
  /** The LS order id — the table's UNIQUE column, so a redelivered order
   *  conflicts instead of double-crediting (second dedupe layer after
   *  recordEvent). */
  lsOrderId: string;
}

export interface WebhookStore {
  /** Idempotency gate. "fresh" → process; "duplicate" → already handled (no-op). */
  recordEvent(eventId: string, eventName: string): Promise<"fresh" | "duplicate">;
  /** Roll back the idempotency row so a genuine retry can re-process. */
  deleteEvent(eventId: string): Promise<void>;

  getSubByLsId(lsSubscriptionId: string): Promise<MirrorSub | null>;
  /** Upsert (onConflict ls_subscription_id); returns the row id + order id. */
  upsertSubscription(row: SubscriptionUpsert): Promise<{ id: string; ls_order_id: string | null }>;
  updateSubscription(id: string, patch: SubscriptionPatch): Promise<void>;
  /** Resolve a subscription mirror for an invoice event, via subscription_id. */
  getSubByLsIdForInvoice(lsSubscriptionId: string): Promise<MirrorSub | null>;
  /** order_refunded: set status by order id; returns affected subscription ids. */
  setStatusByOrderId(orderId: string, status: Status): Promise<string[]>;
  /** license_key_created: link a key hash by order id; returns affected ids. */
  linkLicenseKeyByOrderId(orderId: string, keyHash: string): Promise<string[]>;

  /** Open (or no-op if already open) a usage period. Idempotent on (sub, start). */
  openPeriod(subscriptionId: string, periodStart: string, periodEnd: string | null): Promise<void>;

  /** Top-up attach point: the buyer's most recent spendable (active|past_due)
   *  subscription, by LS customer id. Null → nowhere to credit (logged + flagged
   *  by the handler, not an error). */
  getActiveSubByCustomerId(lsCustomerId: string): Promise<{ id: string } | null>;
  /** Insert a purchased top-up pack. "duplicate" on the ls_order_id unique
   *  conflict (redelivered order) — credited at most once. */
  insertTopup(row: TopupInsert): Promise<"inserted" | "duplicate">;
  /** order_refunded for a top-up: kill the pack's UNSPENT remainder by expiring
   *  it at `revokedAtIso` (spend + balance paths filter expires_at > now(), so
   *  expiry is the structural off-switch; the credits_total > 0 CHECK forbids
   *  total=used for an unspent pack). credits_used is untouched — already-spent
   *  credits stay spent, never clawed back. Returns the number of packs revoked
   *  (0 when the order id isn't a top-up, or the pack is already revoked/expired). */
  revokeTopupByOrderId(orderId: string, revokedAtIso: string): Promise<number>;

  getPendingKey(orderId: string): Promise<{ license_key_hash: string } | null>;
  upsertPendingKey(row: { orderId: string; keyHash: string; customerId: string | null }): Promise<void>;
  deletePendingKey(orderId: string): Promise<void>;
}

const FAR_FUTURE = "9999-12-31T00:00:00Z";

export class SupabaseWebhookStore implements WebhookStore {
  constructor(private readonly db: SupabaseClient) {}

  async recordEvent(eventId: string, eventName: string): Promise<"fresh" | "duplicate"> {
    const { error } = await this.db
      .from("webhook_events")
      .insert({ ls_event_id: eventId, event_name: eventName });
    if (!error) return "fresh";
    if (error.code === "23505") return "duplicate"; // unique violation → already processed
    throw error;
  }

  async deleteEvent(eventId: string): Promise<void> {
    await this.db.from("webhook_events").delete().eq("ls_event_id", eventId);
  }

  async getSubByLsId(lsSubscriptionId: string): Promise<MirrorSub | null> {
    const { data } = await this.db
      .from("subscriptions")
      .select("id, ls_updated_at")
      .eq("ls_subscription_id", lsSubscriptionId)
      .maybeSingle();
    return (data as MirrorSub) ?? null;
  }

  async upsertSubscription(row: SubscriptionUpsert): Promise<{ id: string; ls_order_id: string | null }> {
    const { data, error } = await this.db
      .from("subscriptions")
      .upsert(row, { onConflict: "ls_subscription_id" })
      .select("id, ls_order_id")
      .single();
    if (error) throw error;
    return { id: data.id as string, ls_order_id: (data.ls_order_id as string | null) ?? null };
  }

  async updateSubscription(id: string, patch: SubscriptionPatch): Promise<void> {
    const { error } = await this.db.from("subscriptions").update(patch).eq("id", id);
    if (error) throw error;
  }

  async getSubByLsIdForInvoice(lsSubscriptionId: string): Promise<MirrorSub | null> {
    const { data } = await this.db
      .from("subscriptions")
      .select("id, ls_updated_at")
      .eq("ls_subscription_id", lsSubscriptionId)
      .maybeSingle();
    return (data as MirrorSub) ?? null;
  }

  async setStatusByOrderId(orderId: string, status: Status): Promise<string[]> {
    const { data, error } = await this.db
      .from("subscriptions")
      .update({ status })
      .eq("ls_order_id", orderId)
      .select("id");
    if (error) throw error;
    return (data ?? []).map((r: { id: string }) => r.id);
  }

  async linkLicenseKeyByOrderId(orderId: string, keyHash: string): Promise<string[]> {
    const { data, error } = await this.db
      .from("subscriptions")
      .update({ license_key_hash: keyHash })
      .eq("ls_order_id", orderId)
      .select("id");
    if (error) throw error;
    return (data ?? []).map((r: { id: string }) => r.id);
  }

  async openPeriod(subscriptionId: string, periodStart: string, periodEnd: string | null): Promise<void> {
    const end = periodEnd ?? FAR_FUTURE;
    const { error } = await this.db
      .from("usage_periods")
      .upsert(
        { subscription_id: subscriptionId, period_start: periodStart, period_end: end, credits_used: 0 },
        { onConflict: "subscription_id,period_start", ignoreDuplicates: true },
      );
    if (error) throw error;
  }

  async getActiveSubByCustomerId(lsCustomerId: string): Promise<{ id: string } | null> {
    // Most recent spendable subscription wins — the same status set the credit
    // spend path honors (§9.1: past_due still spends remaining credits).
    const { data, error } = await this.db
      .from("subscriptions")
      .select("id")
      .eq("ls_customer_id", lsCustomerId)
      .in("status", ["active", "past_due"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    return (data as { id: string }) ?? null;
  }

  async insertTopup(row: TopupInsert): Promise<"inserted" | "duplicate"> {
    const { error } = await this.db.from("topup_credits").insert({
      subscription_id: row.subscriptionId,
      credits_total: row.credits,
      expires_at: row.expiresAt,
      ls_order_id: row.lsOrderId,
    });
    if (!error) return "inserted";
    if (error.code === "23505") return "duplicate"; // ls_order_id unique → already credited
    throw error;
  }

  async revokeTopupByOrderId(orderId: string, revokedAtIso: string): Promise<number> {
    // One conditional UPDATE: expire the pack as of the refund. The
    // expires_at > revokedAt guard makes a redelivered refund (or a refund of
    // an already-expired pack) a 0-row no-op instead of re-stamping.
    const { data, error } = await this.db
      .from("topup_credits")
      .update({ expires_at: revokedAtIso })
      .eq("ls_order_id", orderId)
      .gt("expires_at", revokedAtIso)
      .select("id");
    if (error) throw error;
    return (data ?? []).length;
  }

  async getPendingKey(orderId: string): Promise<{ license_key_hash: string } | null> {
    const { data } = await this.db
      .from("pending_license_keys")
      .select("license_key_hash")
      .eq("ls_order_id", orderId)
      .maybeSingle();
    return (data as { license_key_hash: string }) ?? null;
  }

  async upsertPendingKey(row: { orderId: string; keyHash: string; customerId: string | null }): Promise<void> {
    const { error } = await this.db
      .from("pending_license_keys")
      .upsert(
        { ls_order_id: row.orderId, license_key_hash: row.keyHash, ls_customer_id: row.customerId },
        { onConflict: "ls_order_id" },
      );
    if (error) throw error;
  }

  async deletePendingKey(orderId: string): Promise<void> {
    await this.db.from("pending_license_keys").delete().eq("ls_order_id", orderId);
  }
}
