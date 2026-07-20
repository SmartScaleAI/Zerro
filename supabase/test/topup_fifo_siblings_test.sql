-- =============================================================================
-- A-17 — multi-pack top-up FIFO ordering + sibling-subs/NULL-grant edges for
-- the consume_*_overspend family (20260622130000_overspend_allow_negative).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/topup_fifo_siblings_test.sql
--
-- Everything runs in ONE transaction that is ROLLED BACK at the end. Fills the
-- gaps the overspend suite leaves (its scenarios never cross a pack boundary
-- and never share a grant):
--   * spending across MULTIPLE top-up packs drains nearest-expiry FIRST, even
--     when the later-expiring pack has the lower (uuid) id / was inserted first;
--   * an exhausted pack is skipped on the next spend (credits_used < total gate);
--   * at an EQUAL expiry the id-asc tiebreaker decides, deterministically;
--   * two sibling subscriptions sharing ONE trial grant drain it exactly once —
--     the second sibling gets only the remainder, then falls to its own plan;
--   * consume_combined_credit_overspend with a NULL grant id (never-linked sub)
--     or a DANGLING grant id (privacy-deleted grant → ON DELETE SET NULL /
--     stale id) on a SPENDABLE sub is a plan-only spend, NOT the NULL return
--     (the overspend suite's TEST 5 only covers NULL-grant + non-spendable).
-- =============================================================================

begin;

create temp table fx (label text primary key, id uuid not null);

-- ---------------------------------------------------------------------------
-- Subscriptions.
--   fifo: limit 100, plan used 80 (20 left) + two packs at different expiries.
--   tie:  limit 100, plan used 100 (0 left) + two packs at the SAME expiry.
--   s1/s2: the siblings — one shared 20-credit grant, own periods.
-- ---------------------------------------------------------------------------
insert into public.subscriptions
  (id, ls_subscription_id, tier, status, billing_interval, current_period_end, credits_limit)
values
  (gen_random_uuid(), 'test_a17_fifo', 'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_a17_tie',  'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_a17_s1',   'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_a17_s2',   'managed', 'active', 'monthly', now() + interval '20 days', 100);

insert into fx
select replace(ls_subscription_id, 'test_a17_', 'sub_'), id
from public.subscriptions where ls_subscription_id like 'test_a17_%';

-- The shared grant: verified, 20 credits, untouched.
insert into public.trial_grants (id, email_normalized, verified_at, trial_credits_limit, trial_credits_used)
values (gen_random_uuid(), 'a17_siblings@test', now(), 20, 0);

insert into fx
select 'grant_shared', id from public.trial_grants where email_normalized = 'a17_siblings@test';

-- Link BOTH siblings to the one grant (many subs may map to one grant).
update public.subscriptions
set trial_grant_id = (select id from fx where label = 'grant_shared')
where id in (select id from fx where label in ('sub_s1', 'sub_s2'));

-- Periods: fifo 80/100, tie 100/100, s1 80/100, s2 90/100.
insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 80  from fx where label = 'sub_fifo'
union all
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 100 from fx where label = 'sub_tie'
union all
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 80  from fx where label = 'sub_s1'
union all
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 90  from fx where label = 'sub_s2';

-- fifo packs: the LATER-expiring pack gets the LOWER id and is inserted FIRST,
-- so an implementation that ordered by id or by insertion order would drain the
-- wrong pack — only expires_at-asc passes.
insert into public.topup_credits (id, subscription_id, credits_total, credits_used, expires_at)
select '00000000-0000-4000-8000-00000000000a'::uuid, id, 100, 0, now() + interval '365 days' from fx where label = 'sub_fifo';
insert into public.topup_credits (id, subscription_id, credits_total, credits_used, expires_at)
select '00000000-0000-4000-8000-00000000000b'::uuid, id, 50, 0, now() + interval '10 days' from fx where label = 'sub_fifo';

-- tie packs: identical expiry (now() is transaction-stable, so both rows get
-- the same timestamp) — only the id-asc tiebreaker separates them.
insert into public.topup_credits (id, subscription_id, credits_total, credits_used, expires_at)
select '00000000-0000-4000-8000-000000000001'::uuid, id, 10, 0, now() + interval '30 days' from fx where label = 'sub_tie';
insert into public.topup_credits (id, subscription_id, credits_total, credits_used, expires_at)
select '00000000-0000-4000-8000-000000000002'::uuid, id, 10, 0, now() + interval '30 days' from fx where label = 'sub_tie';

-- ---------------------------------------------------------------------------
-- TEST 1 — FIFO across pack boundaries: spend 75 against plan 20 + early 50 +
--   late 100. Plan drains first (→ 100/100), then the NEAR-expiry pack in
--   full (early 50/50), then 5 from the far pack (late 5/100).
--   Returns (20 + 150) − 75 = 95.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_remaining integer; v_plan integer; v_early integer; v_late integer;
begin
  select id into v_sub from fx where label = 'sub_fifo';
  select public.consume_credit_overspend(v_sub, 75) into v_remaining;
  if v_remaining is distinct from 95 then
    raise exception 'fifo: expected remaining 95 ((20+150)-75), got %', v_remaining;
  end if;
  select credits_used into v_plan from public.usage_periods where subscription_id = v_sub;
  select credits_used into v_early from public.topup_credits where id = '00000000-0000-4000-8000-00000000000b';
  select credits_used into v_late  from public.topup_credits where id = '00000000-0000-4000-8000-00000000000a';
  if v_plan <> 100 or v_early <> 50 or v_late <> 5 then
    raise exception 'fifo: expected plan/early/late = 100/50/5 (nearest expiry first), got %/%/%',
      v_plan, v_early, v_late;
  end if;
  raise notice 'TEST 1 FIFO across packs → plan 100, early 50 (drained first), late 5 ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 2 — the exhausted pack is skipped: spend 50 more. Plan is at its limit
--   (avail 0) and the early pack is spent out, so the whole 50 comes from the
--   far pack (late 5→55). Returns (0 + 95) − 50 = 45; no overflow (fully
--   funded), so the plan row stays at exactly 100.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_remaining integer; v_plan integer; v_early integer; v_late integer;
begin
  select id into v_sub from fx where label = 'sub_fifo';
  select public.consume_credit_overspend(v_sub, 50) into v_remaining;
  if v_remaining is distinct from 45 then
    raise exception 'fifo skip: expected remaining 45 ((0+95)-50), got %', v_remaining;
  end if;
  select credits_used into v_plan from public.usage_periods where subscription_id = v_sub;
  select credits_used into v_early from public.topup_credits where id = '00000000-0000-4000-8000-00000000000b';
  select credits_used into v_late  from public.topup_credits where id = '00000000-0000-4000-8000-00000000000a';
  if v_plan <> 100 or v_early <> 50 or v_late <> 55 then
    raise exception 'fifo skip: expected plan/early/late = 100/50/55 (exhausted pack untouched), got %/%/%',
      v_plan, v_early, v_late;
  end if;
  raise notice 'TEST 2 exhausted pack skipped → late 55, early untouched at 50 ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 3 — equal-expiry tiebreak is id asc: spend 12 against two 10-credit
--   packs with the SAME expiry → pack …0001 drains fully (10), pack …0002
--   funds the remainder (2). Returns (0 + 20) − 12 = 8.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_remaining integer; v_a integer; v_b integer;
begin
  select id into v_sub from fx where label = 'sub_tie';
  select public.consume_credit_overspend(v_sub, 12) into v_remaining;
  if v_remaining is distinct from 8 then
    raise exception 'tiebreak: expected remaining 8 ((0+20)-12), got %', v_remaining;
  end if;
  select credits_used into v_a from public.topup_credits where id = '00000000-0000-4000-8000-000000000001';
  select credits_used into v_b from public.topup_credits where id = '00000000-0000-4000-8000-000000000002';
  if v_a <> 10 or v_b <> 2 then
    raise exception 'tiebreak: expected pack1/pack2 = 10/2 (id asc at equal expiry), got %/%', v_a, v_b;
  end if;
  raise notice 'TEST 3 equal-expiry tiebreak → pack …0001 first (10), …0002 second (2) ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 4 — sibling subs drain the shared grant exactly once. S1 spends 15:
--   all from the grant (20 avail → 15 used), plan untouched. S2 then spends
--   15: only the 5-credit remainder comes from the grant, 10 from S2's own
--   plan. The grant lands at exactly its 20 limit — never double-drained.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_s1 uuid; v_s2 uuid; v_grant uuid; v_res jsonb; v_used integer;
begin
  select id into v_s1 from fx where label = 'sub_s1';
  select id into v_s2 from fx where label = 'sub_s2';
  select id into v_grant from fx where label = 'grant_shared';

  select public.consume_combined_credit_overspend(v_grant, v_s1, 15) into v_res;
  if (v_res->>'remaining')::int is distinct from 25
     or (v_res->>'trial_spent')::int <> 15 or (v_res->>'plan_spent')::int <> 0 then
    raise exception 'sibling S1: expected remaining/trial/plan = 25/15/0, got %/%/%',
      v_res->>'remaining', v_res->>'trial_spent', v_res->>'plan_spent';
  end if;

  select public.consume_combined_credit_overspend(v_grant, v_s2, 15) into v_res;
  if (v_res->>'remaining')::int is distinct from 0
     or (v_res->>'trial_spent')::int <> 5 or (v_res->>'plan_spent')::int <> 10 then
    raise exception 'sibling S2: expected remaining/trial/plan = 0/5/10 (only the remainder), got %/%/%',
      v_res->>'remaining', v_res->>'trial_spent', v_res->>'plan_spent';
  end if;

  select trial_credits_used into v_used from public.trial_grants where id = v_grant;
  if v_used <> 20 then
    raise exception 'siblings: shared grant must land at exactly its 20 limit, got %', v_used;
  end if;
  select credits_used into v_used from public.usage_periods
  where subscription_id = v_s1;
  if v_used <> 80 then
    raise exception 'siblings: S1 plan must be untouched at 80 (grant funded it all), got %', v_used;
  end if;
  select credits_used into v_used from public.usage_periods
  where subscription_id = v_s2;
  if v_used <> 100 then
    raise exception 'siblings: S2 plan should carry the 10-credit shortfall (90+10), got %', v_used;
  end if;
  raise notice 'TEST 4 siblings share one grant → drained once (15 then 5), S2 plan covers the rest ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 5 — NULL / dangling grant on a SPENDABLE sub is a plan-only spend, not
--   the non-spendable NULL. (A never-linked sub passes grant NULL; a privacy-
--   deleted grant leaves trial_grant_id NULL via ON DELETE SET NULL, but a
--   stale/dangling id must degrade the same way.)
-- ---------------------------------------------------------------------------
do $t$
declare
  v_s1 uuid; v_res jsonb; v_used integer;
begin
  select id into v_s1 from fx where label = 'sub_s1';

  -- NULL grant id → trial bucket contributes 0, the plan funds it.
  select public.consume_combined_credit_overspend(null, v_s1, 5) into v_res;
  if v_res is null then
    raise exception 'null-grant: a spendable sub must spend plan-only, not return NULL';
  end if;
  if (v_res->>'remaining')::int is distinct from 15
     or (v_res->>'trial_spent')::int <> 0 or (v_res->>'plan_spent')::int <> 5 then
    raise exception 'null-grant: expected remaining/trial/plan = 15/0/5, got %/%/%',
      v_res->>'remaining', v_res->>'trial_spent', v_res->>'plan_spent';
  end if;

  -- Dangling grant id (no matching row) → identical plan-only degradation.
  select public.consume_combined_credit_overspend(gen_random_uuid(), v_s1, 5) into v_res;
  if v_res is null
     or (v_res->>'remaining')::int is distinct from 10
     or (v_res->>'trial_spent')::int <> 0 or (v_res->>'plan_spent')::int <> 5 then
    raise exception 'dangling-grant: expected remaining/trial/plan = 10/0/5, got %',
      coalesce(v_res::text, 'NULL');
  end if;

  -- The shared grant was never touched by either call.
  select trial_credits_used into v_used from public.trial_grants
  where id = (select id from fx where label = 'grant_shared');
  if v_used <> 20 then
    raise exception 'null/dangling-grant: the real grant must be untouched at 20, got %', v_used;
  end if;
  raise notice 'TEST 5 NULL + dangling grant on a spendable sub → plan-only spend, never NULL ✓';
end;
$t$;

do $$ begin raise notice 'ALL FIFO/SIBLINGS TESTS PASSED'; end $$;

rollback;
