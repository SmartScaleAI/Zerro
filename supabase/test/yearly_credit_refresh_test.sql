-- =============================================================================
-- refresh_yearly_credit_periods() — money-logic tests (Appendix E2).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/yearly_credit_refresh_test.sql
--
-- Everything runs in ONE transaction that is ROLLED BACK at the end — the
-- fixtures never persist. Each scenario asserts per-subscription period
-- counts (not just the function's global return) so unrelated rows in a dev
-- database can't mask a failure. RAISE EXCEPTION on any violated invariant;
-- ON_ERROR_STOP makes psql exit non-zero.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Fixtures. Anchored relative to now() so the tests are date-independent.
--   A: yearly, active, signed up 1 month + 1 day ago, initial period only.
--   B: monthly, active, same age              → must NEVER be touched.
--   C: yearly, active, 3 months + 1 day in    → catch-up: exactly 3 rolls.
--   D: yearly, active, year ENDED (latest period = month 12; renews_at past)
--                                              → 0, the annual renewal owns it.
--   E: yearly, CANCELLED, 2 months in          → 0 (status filter).
--   F: yearly, active, latest period = signup+10mo, year end = signup+12mo
--                                              → exactly 1 (month 12 granted;
--                                                month 13 = year end waits).
-- ---------------------------------------------------------------------------
create temp table fixture (label text primary key, sub_id uuid not null);

insert into public.subscriptions
  (id, ls_subscription_id, tier, status, billing_interval, current_period_end, credits_limit)
values
  (gen_random_uuid(), 'test_yearly_A', 'pro', 'active',    'yearly',  now() - interval '1 month 1 day' + interval '1 year', 300),
  (gen_random_uuid(), 'test_month_B',  'pro', 'active',    'monthly', now() + interval '29 days',                            300),
  (gen_random_uuid(), 'test_yearly_C', 'pro', 'active',    'yearly',  now() - interval '3 months 1 day' + interval '1 year', 300),
  (gen_random_uuid(), 'test_yearly_D', 'pro', 'active',    'yearly',  now() - interval '1 month',                            300),
  (gen_random_uuid(), 'test_yearly_E', 'pro', 'cancelled', 'yearly',  now() - interval '2 months 1 day' + interval '1 year', 300),
  (gen_random_uuid(), 'test_yearly_F', 'pro', 'active',    'yearly',  now() - interval '11 months 1 day' + interval '1 year', 300);

insert into fixture
select replace(ls_subscription_id, 'test_', ''), id
from public.subscriptions where ls_subscription_id like 'test_%';

-- Initial signup periods (what subscription_created's openPeriod creates).
insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select sub_id,
       case label
         when 'yearly_A' then now() - interval '1 month 1 day'
         when 'month_B'  then now() - interval '1 month 1 day'
         when 'yearly_C' then now() - interval '3 months 1 day'
         when 'yearly_D' then now() - interval '13 months'
         when 'yearly_E' then now() - interval '2 months 1 day'
         when 'yearly_F' then now() - interval '11 months 1 day'
       end,
       '9999-12-31'::timestamptz,
       0
from fixture;

-- D's latest period is month 12 of its (now-ended) year: next anchor lands
-- exactly AT current_period_end, which must NOT be granted.
insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select sub_id, now() - interval '2 months', '9999-12-31'::timestamptz, 0
from fixture where label = 'yearly_D';

-- F's latest period is signup + 10 months (its 11th period): exactly one
-- month (the 12th) remains inside the paid year.
insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select sub_id, now() - interval '11 months 1 day' + interval '10 months', '9999-12-31'::timestamptz, 0
from fixture where label = 'yearly_F';

-- ---------------------------------------------------------------------------
-- RUN 1
-- ---------------------------------------------------------------------------
do $t$
declare
  v_rolled integer;
  v_n integer;
begin
  select public.refresh_yearly_credit_periods() into v_rolled;
  raise notice 'run 1 rolled % period(s)', v_rolled;

  -- A: 1 month in → exactly ONE new period (2 total).
  select count(*) into v_n from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id where f.label = 'yearly_A';
  if v_n <> 2 then raise exception 'A: expected 2 periods after run 1, got %', v_n; end if;

  -- B (monthly): NEVER touched.
  select count(*) into v_n from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id where f.label = 'month_B';
  if v_n <> 1 then raise exception 'B (monthly): expected 1 period (untouched), got %', v_n; end if;

  -- C: 3 months behind → catches up exactly 3 (4 total), not more.
  select count(*) into v_n from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id where f.label = 'yearly_C';
  if v_n <> 4 then raise exception 'C: expected 4 periods after catch-up, got %', v_n; end if;

  -- D: past year end → 0 new (still 2). The annual renewal owns the boundary.
  select count(*) into v_n from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id where f.label = 'yearly_D';
  if v_n <> 2 then raise exception 'D: expected 2 periods (year over → none rolled), got %', v_n; end if;

  -- E: cancelled → 0 new (still 1).
  select count(*) into v_n from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id where f.label = 'yearly_E';
  if v_n <> 1 then raise exception 'E: expected 1 period (cancelled untouched), got %', v_n; end if;

  -- F: month 12 granted (anchor < year end) → 3 total; month 13 NOT.
  select count(*) into v_n from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id where f.label = 'yearly_F';
  if v_n <> 3 then raise exception 'F: expected 3 periods (month 12 granted, 13 waits), got %', v_n; end if;
end;
$t$;

-- ---------------------------------------------------------------------------
-- RUN 2 — same day: must roll NOTHING for the fixtures (idempotent).
-- ---------------------------------------------------------------------------
do $t$
declare
  v_n integer;
  v_total_before integer;
  v_total_after integer;
begin
  select count(*) into v_total_before from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id;
  perform public.refresh_yearly_credit_periods();
  select count(*) into v_total_after from public.usage_periods up
    join fixture f on f.sub_id = up.subscription_id;
  if v_total_after <> v_total_before then
    raise exception 'idempotency: run 2 changed fixture periods (% -> %)', v_total_before, v_total_after;
  end if;
  raise notice 'run 2 rolled 0 fixture periods (idempotent) ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- Spendability: the fresh period really is a spendable 300. consume_credit
-- targets the LATEST period; A's latest is the just-rolled one (credits_used
-- 0 against credits_limit 300) → spending 4 returns 296 (no top-ups).
-- ---------------------------------------------------------------------------
do $t$
declare
  v_remaining integer;
  v_sub uuid;
begin
  select sub_id into v_sub from fixture where label = 'yearly_A';
  select public.consume_credit(v_sub, 4) into v_remaining;
  if v_remaining is distinct from 296 then
    raise exception 'spendability: expected 296 remaining after consuming 4 of the fresh 300, got %', v_remaining;
  end if;
  raise notice 'fresh period spendable: consume_credit(4) -> % ✓', v_remaining;
end;
$t$;

-- ---------------------------------------------------------------------------
-- Cadence: A's new period_start is EXACTLY initial + 1 month (anchored, not
-- now()-derived).
-- ---------------------------------------------------------------------------
do $t$
declare
  v_initial timestamptz;
  v_next timestamptz;
  v_sub uuid;
begin
  select sub_id into v_sub from fixture where label = 'yearly_A';
  select min(period_start), max(period_start) into v_initial, v_next
  from public.usage_periods where subscription_id = v_sub;
  if v_next <> v_initial + interval '1 month' then
    raise exception 'cadence: expected next period_start = initial + 1 month (% vs %)', v_next, v_initial + interval '1 month';
  end if;
  raise notice 'cadence anchored to period_start + 1 month ✓';
end;
$t$;

do $$ begin raise notice 'ALL YEARLY-REFRESH TESTS PASSED'; end $$;

rollback;
