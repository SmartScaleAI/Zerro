-- =============================================================================
-- consume_*_overspend() — money-logic tests (20260622130000_overspend_allow_negative).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/overspend_allow_negative_test.sql
--
-- Everything runs in ONE transaction that is ROLLED BACK at the end — the
-- fixtures never persist. Each scenario asserts the bucket bookkeeping AND the
-- returned remaining, so the negative-balance behavior is pinned both ways.
-- RAISE EXCEPTION on any violated invariant; ON_ERROR_STOP makes psql exit
-- non-zero. Invariants proven:
--   * a costlier-than-balance spend ALWAYS goes through (no all-or-nothing null);
--   * the shortfall overflows onto usage_periods.credits_used (subscription) or
--     trial_grants.trial_credits_used (pure trial), pushing it ABOVE the limit;
--   * a top-up row is NEVER overspent (credits_used <= credits_total holds);
--   * the returned remaining is the true (negative) balance;
--   * NULL is returned ONLY for a genuinely non-spendable account;
--   * a renewal (fresh usage_periods row) / a fresh top-up start from their own
--     positive balance — the prior negative is NOT netted against them.
-- =============================================================================

begin;

create temp table fx (label text primary key, id uuid not null);

-- ---------------------------------------------------------------------------
-- Subscriptions (all active so the status gate passes).
--   single:   limit 100, plan used 96 (4 left) + a 5-credit top-up → spend 20.
--   combined: limit 100, plan used 98 (2 left), linked grant 3 left → spend 10.
--   noperiod: active but has NO usage_period → the non-spendable NULL case.
-- ---------------------------------------------------------------------------
insert into public.subscriptions
  (id, ls_subscription_id, tier, status, billing_interval, current_period_end, credits_limit)
values
  (gen_random_uuid(), 'test_overspend_single',   'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_overspend_combined', 'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_overspend_noperiod', 'managed', 'active', 'monthly', now() + interval '20 days', 100);

insert into fx
select replace(ls_subscription_id, 'test_overspend_', 'sub_'), id
from public.subscriptions where ls_subscription_id like 'test_overspend_%';

-- Trial grants.
--   combined: verified, 15 limit / 12 used (3 left) — drained first, then plan.
--   trial:    verified, 15 limit / 13 used (2 left) — pure-trial overspend.
--   unverif:  NOT verified — must return NULL (non-spendable).
insert into public.trial_grants
  (id, email_normalized, verified_at, trial_credits_limit, trial_credits_used)
values
  (gen_random_uuid(), 'overspend_combined@test', now(), 15, 12),
  (gen_random_uuid(), 'overspend_trial@test',    now(), 15, 13),
  (gen_random_uuid(), 'overspend_unverif@test',  null,  15, 0);

insert into fx
select case email_normalized
         when 'overspend_combined@test' then 'grant_combined'
         when 'overspend_trial@test'    then 'grant_trial'
         when 'overspend_unverif@test'  then 'grant_unverif'
       end,
       id
from public.trial_grants where email_normalized like 'overspend_%@test';

-- usage_periods: single (used 96), combined (used 98). noperiod gets none.
insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 96 from fx where label = 'sub_single'
union all
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 98 from fx where label = 'sub_combined';

-- A 5-credit top-up on the single sub (non-expired).
insert into public.topup_credits (subscription_id, credits_total, credits_used, expires_at)
select id, 5, 0, now() + interval '12 months' from fx where label = 'sub_single';

-- ---------------------------------------------------------------------------
-- TEST 1 — consume_credit_overspend: spend 20 against 4 plan + 5 top-up.
--   Funded: 4 plan + 5 top-up = 9; the 11-credit shortfall overflows onto the
--   plan period. Returns (4 + 5) − 20 = −11.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_remaining integer; v_plan_used integer; v_topup_used integer;
begin
  select id into v_sub from fx where label = 'sub_single';
  select public.consume_credit_overspend(v_sub, 20) into v_remaining;
  if v_remaining is distinct from -11 then
    raise exception 'single overspend: expected remaining -11, got %', v_remaining;
  end if;
  select credits_used into v_plan_used from public.usage_periods where subscription_id = v_sub;
  if v_plan_used <> 111 then
    raise exception 'single overspend: plan credits_used should overflow to 111 (96+4+11), got %', v_plan_used;
  end if;
  select credits_used into v_topup_used from public.topup_credits where subscription_id = v_sub;
  if v_topup_used <> 5 then
    raise exception 'single overspend: top-up spent only its real 5 (never overspent), got %', v_topup_used;
  end if;
  raise notice 'TEST 1 consume_credit_overspend → −11, plan 111, top-up 5 ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 2 — renewal starts fresh (no carry-over of TEST 1's negative).
--   Insert a NEW (later) usage_period with credits_used 0; consume_credit_
--   overspend targets the LATEST period, so spending 4 returns 96 — the old
--   overspent period (111) is NOT netted in. (The expired-from-balance top-up
--   was fully spent in TEST 1, so it contributes 0.)
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_remaining integer;
begin
  select id into v_sub from fx where label = 'sub_single';
  insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
  values (v_sub, now(), '9999-12-31'::timestamptz, 0);
  select public.consume_credit_overspend(v_sub, 4) into v_remaining;
  if v_remaining is distinct from 96 then
    raise exception 'renewal: fresh period should give 100−4=96 with NO carry-over, got %', v_remaining;
  end if;
  raise notice 'TEST 2 renewal fresh period → 96 (no debt carry-over) ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 3 — consume_combined_credit_overspend: spend 10 against trial 3 + plan 2.
--   Funded: 3 trial + 2 plan = 5; the 5-credit shortfall overflows onto the
--   plan period (folded into plan_spent). Returns remaining −5.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_grant uuid; v_res jsonb; v_plan_used integer; v_trial_used integer;
begin
  select id into v_sub from fx where label = 'sub_combined';
  select id into v_grant from fx where label = 'grant_combined';
  select public.consume_combined_credit_overspend(v_grant, v_sub, 10) into v_res;
  if (v_res->>'remaining')::int is distinct from -5 then
    raise exception 'combined overspend: expected remaining -5, got %', v_res->>'remaining';
  end if;
  if (v_res->>'trial_spent')::int <> 3 then
    raise exception 'combined overspend: trial_spent should be 3, got %', v_res->>'trial_spent';
  end if;
  -- plan_spent folds the 2 funded + 5 overflow = 7; trial+plan+topup must == 10.
  if (v_res->>'plan_spent')::int <> 7 or (v_res->>'topup_spent')::int <> 0 then
    raise exception 'combined overspend: plan_spent/topup_spent should be 7/0, got %/%',
      v_res->>'plan_spent', v_res->>'topup_spent';
  end if;
  if (v_res->>'trial_spent')::int + (v_res->>'plan_spent')::int + (v_res->>'topup_spent')::int <> 10 then
    raise exception 'combined overspend: split must sum to 10';
  end if;
  select credits_used into v_plan_used from public.usage_periods where subscription_id = v_sub;
  if v_plan_used <> 105 then
    raise exception 'combined overspend: plan credits_used should overflow to 105 (98+2+5), got %', v_plan_used;
  end if;
  select trial_credits_used into v_trial_used from public.trial_grants where id = v_grant;
  if v_trial_used <> 15 then
    raise exception 'combined overspend: trial drained to its 15 limit (never overshot), got %', v_trial_used;
  end if;
  raise notice 'TEST 3 consume_combined_credit_overspend → −5, plan 105, trial 15 ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 4 — consume_trial_credit_overspend: spend 10 against 2 trial credits.
--   The single bucket absorbs the full charge: trial_credits_used 13→23 (ABOVE
--   the 15 limit), remaining 15−23 = −8.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_grant uuid; v_remaining integer; v_used integer;
begin
  select id into v_grant from fx where label = 'grant_trial';
  select public.consume_trial_credit_overspend(v_grant, 10) into v_remaining;
  if v_remaining is distinct from -8 then
    raise exception 'trial overspend: expected remaining -8, got %', v_remaining;
  end if;
  select trial_credits_used into v_used from public.trial_grants where id = v_grant;
  if v_used <> 23 then
    raise exception 'trial overspend: trial_credits_used should overflow to 23 (13+10), got %', v_used;
  end if;
  raise notice 'TEST 4 consume_trial_credit_overspend → −8, used 23 (> limit 15) ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 5 — NULL only for genuinely non-spendable accounts.
--   * single/combined on a sub with NO usage_period → NULL.
--   * trial on an unverified grant → NULL; on a missing grant → NULL.
--   None of these write anything.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_grant uuid; v_int integer; v_res jsonb;
begin
  select id into v_sub from fx where label = 'sub_noperiod';

  select public.consume_credit_overspend(v_sub, 5) into v_int;
  if v_int is not null then
    raise exception 'non-spendable single: expected NULL (no period), got %', v_int;
  end if;

  select public.consume_combined_credit_overspend(null, v_sub, 5) into v_res;
  if v_res is not null then
    raise exception 'non-spendable combined: expected NULL (no period), got %', v_res;
  end if;

  select id into v_grant from fx where label = 'grant_unverif';
  select public.consume_trial_credit_overspend(v_grant, 5) into v_int;
  if v_int is not null then
    raise exception 'non-spendable trial (unverified): expected NULL, got %', v_int;
  end if;

  select public.consume_trial_credit_overspend(gen_random_uuid(), 5) into v_int;
  if v_int is not null then
    raise exception 'non-spendable trial (missing): expected NULL, got %', v_int;
  end if;

  -- The unverified grant was never touched.
  select trial_credits_used into v_int from public.trial_grants where id = v_grant;
  if v_int <> 0 then
    raise exception 'non-spendable trial: unverified grant must be untouched, got %', v_int;
  end if;
  raise notice 'TEST 5 NULL only for non-spendable accounts (nothing written) ✓';
end;
$t$;

-- ---------------------------------------------------------------------------
-- TEST 6 — a fresh top-up starts from its own balance after the plan went
--   negative (greatest(0, ...) clamp = the "new credits never net the debt"
--   guardrail). sub_combined's latest period is at 105 (TEST 3); add a 50-credit
--   top-up and spend 4 → funded entirely from the top-up: returns (0 + 50) − 4
--   = 46, NOT (−5 + 50) − 4 = 41.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub uuid; v_remaining integer; v_topup_used integer;
begin
  select id into v_sub from fx where label = 'sub_combined';
  insert into public.topup_credits (subscription_id, credits_total, credits_used, expires_at)
  values (v_sub, 50, 0, now() + interval '12 months');
  select public.consume_credit_overspend(v_sub, 4) into v_remaining;
  if v_remaining is distinct from 46 then
    raise exception 'fresh top-up: expected 46 ((0 clamp)+50−4), NOT a debt-netted 41, got %', v_remaining;
  end if;
  select credits_used into v_topup_used from public.topup_credits where subscription_id = v_sub;
  if v_topup_used <> 4 then
    raise exception 'fresh top-up: should have spent 4 of the 50, got %', v_topup_used;
  end if;
  raise notice 'TEST 6 fresh top-up → 46 (negative plan clamped, no debt netting) ✓';
end;
$t$;

do $$ begin raise notice 'ALL OVERSPEND TESTS PASSED'; end $$;

rollback;
