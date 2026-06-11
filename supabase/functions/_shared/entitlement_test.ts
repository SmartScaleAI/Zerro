// buildEntitlementSnapshot — focused on the E8 reset_date rules (yearly subs
// show the NEXT MONTHLY refresh anchor, not the annual renewal) plus the
// combined plan+top-up balance. The fake client answers the two queries the
// builder makes (latest usage_period, non-expired top-ups).

import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { buildEntitlementSnapshot, type SubscriptionRow } from "./entitlement.ts";

interface FakeData {
  period?: { credits_used: number; period_start: string } | null;
  topups?: Array<{ credits_total: number; credits_used: number }>;
}

function fakeDb(data: FakeData): SupabaseClient {
  return {
    from(table: string) {
      const result = table === "usage_periods"
        ? { data: data.period ?? null, error: null }
        : { data: data.topups ?? [], error: null };
      const builder = {
        select: () => builder,
        eq: () => builder,
        gt: () => builder,
        order: () => builder,
        limit: () => builder,
        maybeSingle: () => Promise.resolve(result),
        // The top-up query is awaited directly (no .maybeSingle) — supabase
        // builders are thenables, so the fake must be one too.
        then: (
          resolve: (v: unknown) => unknown,
          reject: (e: unknown) => unknown,
        ) => Promise.resolve(result).then(resolve, reject),
      };
      return builder;
    },
  } as unknown as SupabaseClient;
}

function sub(overrides: Partial<SubscriptionRow> = {}): SubscriptionRow {
  return {
    id: "sub-1",
    tier: "pro",
    status: "active",
    credits_limit: 300,
    current_period_end: "2027-06-01T00:00:00.000Z",
    billing_interval: "monthly",
    ...overrides,
  };
}

Deno.test("monthly sub: reset_date is current_period_end", async () => {
  const db = fakeDb({ period: { credits_used: 10, period_start: "2026-06-01T00:00:00.000Z" } });
  const snap = await buildEntitlementSnapshot(db, sub({ current_period_end: "2026-07-01T00:00:00.000Z" }));
  assertEquals(snap.reset_date, "2026-07-01T00:00:00.000Z");
  assertEquals(snap.credits_remaining, 290);
});

Deno.test("NULL billing_interval (pre-Phase-5 row) behaves as monthly", async () => {
  const db = fakeDb({ period: { credits_used: 0, period_start: "2026-06-01T00:00:00.000Z" } });
  const snap = await buildEntitlementSnapshot(
    db,
    sub({ billing_interval: null, current_period_end: "2026-07-01T00:00:00.000Z" }),
  );
  assertEquals(snap.reset_date, "2026-07-01T00:00:00.000Z");
});

Deno.test("yearly sub: reset_date is latest period_start + 1 month (E8)", async () => {
  const db = fakeDb({ period: { credits_used: 50, period_start: "2026-06-15T10:30:00.000Z" } });
  const snap = await buildEntitlementSnapshot(
    db,
    sub({ billing_interval: "yearly", current_period_end: "2027-06-11T00:00:00.000Z" }),
  );
  assertEquals(snap.reset_date, "2026-07-15T10:30:00.000Z");
});

Deno.test("yearly sub: day-of-month clamps like Postgres interval (Jan 31 → Feb 28)", async () => {
  const db = fakeDb({ period: { credits_used: 0, period_start: "2026-01-31T08:00:00.000Z" } });
  const snap = await buildEntitlementSnapshot(
    db,
    sub({ billing_interval: "yearly", current_period_end: "2027-01-31T08:00:00.000Z" }),
  );
  assertEquals(snap.reset_date, "2026-02-28T08:00:00.000Z");
});

Deno.test("yearly sub: anchor at/past year end caps at current_period_end (annual renewal owns the boundary)", async () => {
  // Month 12: the next anchor would land exactly ON the year end — the cron
  // job's strict < refuses it, so the next refresh IS the annual renewal.
  const db = fakeDb({ period: { credits_used: 0, period_start: "2026-12-11T00:00:00.000Z" } });
  const snap = await buildEntitlementSnapshot(
    db,
    sub({ billing_interval: "yearly", current_period_end: "2027-01-11T00:00:00.000Z" }),
  );
  assertEquals(snap.reset_date, "2027-01-11T00:00:00.000Z");
});

Deno.test("yearly sub with no usage period: falls back to current_period_end, exhausted", async () => {
  const db = fakeDb({ period: null });
  const snap = await buildEntitlementSnapshot(
    db,
    sub({ billing_interval: "yearly", current_period_end: "2027-06-11T00:00:00.000Z" }),
  );
  assertEquals(snap.reset_date, "2027-06-11T00:00:00.000Z");
  assertEquals(snap.credits_remaining, 0);
});

Deno.test("combined balance: plan remaining + non-expired top-ups, with breakdown", async () => {
  const db = fakeDb({
    period: { credits_used: 280, period_start: "2026-06-01T00:00:00.000Z" },
    topups: [
      { credits_total: 200, credits_used: 50 },
      { credits_total: 500, credits_used: 500 },
    ],
  });
  const snap = await buildEntitlementSnapshot(db, sub());
  assertEquals(snap.plan_credits_used, 280);
  assertEquals(snap.plan_credits_limit, 300);
  assertEquals(snap.topup_credits_remaining, 150);
  assertEquals(snap.credits_remaining, 20 + 150);
});
