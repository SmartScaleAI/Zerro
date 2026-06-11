-- =============================================================================
-- Zerro billing — monthly credit refresh for YEARLY subscriptions (Appendix E2)
-- =============================================================================
-- LemonSqueezy bills a yearly subscription ONCE A YEAR, so the renewal webhook
-- (subscription_payment_success / billing_reason "renewal" → openPeriod) rolls
-- a fresh 300-credit usage period only annually. Without this job a yearly
-- subscriber would get credits at signup and then NOTHING for 12 months.
--
-- This migration adds:
--   1. refresh_yearly_credit_periods() — rolls a fresh monthly usage period
--      for every active|past_due `billing_interval = 'yearly'` subscription
--      whose latest period is ≥ 1 month old, catching up month-by-month if
--      cron missed runs, and NEVER granting at/past the paid year's end
--      (subscriptions.current_period_end = the annual renews_at; from there
--      the annual renewal webhook takes over).
--   2. A pg_cron schedule running it hourly. Idempotent + cheap, so hourly
--      just means a fresh period lands within an hour of its month boundary.
--
-- MONEY-SAFETY ARGUMENT (Phase-1 rigor):
--   * IDEMPOTENT BY CONSTRUCTION, two independent layers:
--       (a) the age gate — anchors derive from the LATEST period_start, so the
--           moment a period is rolled, the next anchor moves > now() and a
--           re-run selects nothing to do;
--       (b) the (subscription_id, period_start) UNIQUE key — anchors are
--           deterministic (latest + n months), so even two RACING executions
--           compute identical period_starts and ON CONFLICT DO NOTHING lets
--           exactly one insert win. A same-day re-run rolls 0.
--   * MONTHLY SUBS UNTOUCHED: the billing_interval = 'yearly' filter excludes
--     them (their cadence stays webhook-renewal-driven). A NULL interval
--     (pre-Phase-5 rows) is excluded too — fail-safe.
--   * YEAR-END BOUNDARY: anchors are granted only while
--     anchor < current_period_end (strict <). Month 12's anchor
--     (signup + 11 months) is < the year end → granted; month 13's anchor
--     (signup + 12 months) = the year end → NOT granted: that period is the
--     annual renewal's to roll (and renews_at moves a year forward when it
--     does). A NULL current_period_end (data anomaly for a yearly sub —
--     LS always sends renews_at) rolls NOTHING: fail-SAFE under-grant that
--     the next webhook event self-heals, never an unbounded grant.
--   * STATUS FILTER: active|past_due only — the same spendable set
--     consume_credit honors (§9.1: past_due keeps generating on remaining
--     credits, and its monthly refresh continues until LS resolves dunning
--     into recovered or expired). cancelled/expired roll nothing.
--   * RACES: concurrent with consume_credit — inserting a NEW period while a
--     spend holds the latest-period row lock is the documented benign class
--     (the spend lands on the just-superseded period; the user got a fresh
--     allowance anyway). Concurrent with the annual-renewal webhook — its
--     period_start is the invoice's created_at, ours are anchor-derived;
--     consume_credit always targets the LATEST period, so the renewal period
--     simply supersedes. No locks needed beyond the unique key.
--
-- CADENCE NOTE: anchoring to latest period_start + 1 month keeps periods on
-- the signup day-of-month with no drift for days 1–28. Days 29–31 clamp at
-- the first short month (Postgres interval arithmetic: Jan 31 + 1 month =
-- Feb 28) and STAY at the clamped day thereafter — a one-time shift of up to
-- 3 days earlier, never a missed or doubled grant. Accepted.
--
-- Conventions (F9): append-only migration; pinned search_path with fully-
-- qualified relations (advisor 0011); invoker rights (matches the other
-- billing functions — the callers are the postgres-owned cron job and the
-- service role, which holds the table grants); explicit EXECUTE grant.
-- =============================================================================

create or replace function public.refresh_yearly_credit_periods()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_rolled integer := 0;
  v_count  integer;
  v_anchor timestamptz;
  r        record;
begin
  -- One row per refresh-eligible yearly subscription, with its latest period
  -- start (the cadence anchor base). The INNER join deliberately skips a sub
  -- with no usage_periods row at all: there is no anchor to derive from, and
  -- subscription_created always opens the first period — a missing one is an
  -- anomaly to surface, not to silently backfill from now().
  for r in
    select s.id, s.current_period_end, max(up.period_start) as latest_start
    from public.subscriptions s
    join public.usage_periods up on up.subscription_id = s.id
    where s.billing_interval = 'yearly'
      and s.status in ('active', 'past_due')
      and s.current_period_end is not null
    group by s.id, s.current_period_end
  loop
    v_anchor := r.latest_start + interval '1 month';
    -- Catch-up loop: if cron missed a boundary (downtime), advance month by
    -- month until current — but never to/past the paid year's end. Each
    -- iteration's insert is independently idempotent, so a catch-up that
    -- races another execution still can't double-grant.
    while now() >= v_anchor and v_anchor < r.current_period_end loop
      insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
      values (r.id, v_anchor, v_anchor + interval '1 month', 0)
      on conflict (subscription_id, period_start) do nothing;
      get diagnostics v_count = row_count;
      v_rolled := v_rolled + v_count;
      v_anchor := v_anchor + interval '1 month';
    end loop;
  end loop;

  return v_rolled;
end;
$$;

comment on function public.refresh_yearly_credit_periods() is
  'Rolls fresh monthly usage periods for active|past_due yearly subscriptions (Appendix E2: LS bills yearly subs annually, so the renewal webhook can''t provide the monthly 300-credit cadence). Anchored to latest period_start + 1 month; catches up missed months; strict < current_period_end so the annual renewal owns the year boundary. Idempotent via the age gate + the (subscription_id, period_start) unique key. Returns periods rolled.';

grant execute on function public.refresh_yearly_credit_periods() to service_role;

-- -----------------------------------------------------------------------------
-- Schedule — hourly via pg_cron. The function is idempotent and the eligible-
-- sub scan is cheap (indexed by subscription in usage_periods), so hourly just
-- bounds how stale a month boundary can get (≤1h).
--
-- pg_cron was NOT previously assumed by this schema (the idempotency-cache
-- migration's optional prune job documents that), so it is enabled here. On
-- the hosted project `create extension` works from a migration (pg_cron is in
-- Supabase's allowed list; it lands in the `pg_catalog`/`cron` schemas) — if
-- the project has extensions locked to dashboard-management, enable pg_cron
-- under Database → Extensions BEFORE `db push`, and this statement becomes a
-- no-op via IF NOT EXISTS.
--
-- `cron.schedule` with a job name UPSERTS (pg_cron ≥1.4 replaces the schedule/
-- command for an existing name), so a re-applied migration can't duplicate
-- the job. The job runs as the migration role (postgres), which owns the
-- billing tables.
-- -----------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'refresh-yearly-credits',
  '0 * * * *',
  $$ select public.refresh_yearly_credit_periods(); $$
);
