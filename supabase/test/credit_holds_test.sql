-- =============================================================================
-- X-02 credit_holds — deposit-and-settle money-logic tests
-- (20260710120000_credit_holds_deposit_settle).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/credit_holds_test.sql
--
-- Everything runs in ONE transaction that is ROLLED BACK at the end — the
-- fixtures never persist. RAISE EXCEPTION on any violated invariant;
-- ON_ERROR_STOP makes psql exit non-zero. Invariants proven:
--   * a hold reduces the SPENDABLE balance: a second hold past spendable
--     returns 'insufficient' (invariant 2);
--   * a duplicate-key hold is an idempotent no-op — ONE reservation per key,
--     retry-safe (invariant 3, call-1 half);
--   * active_hold_credits excludes p_exclude_key, so a request can settle its
--     OWN hold (the call-2 floor-gate contract);
--   * an EXPIRED hold stops reducing spendable immediately (correctness never
--     waits on the sweep), and the sweep's delete removes only expired rows
--     (invariant 6);
--   * settle consumes EXACTLY p_credits via the existing spender AND removes
--     the hold in the same transaction — never hold + separate charge, never
--     neither (invariant 4); works across all three ledgers (subscription,
--     pure trial with overspend-to-negative, combined trial-first);
--   * settle with no prior hold consumes normally (hold_released=false);
--   * settle against a NON-spendable account returns NULL, spends NOTHING,
--     and leaves the hold to its TTL (invariant 5);
--   * a cross-account key collision and invalid arguments RAISE (fail closed),
--     and the one-owner CHECK rejects malformed rows.
-- The two-sessions race (two concurrent holds can't both take the last
-- spendable credit) lives in credit_holds_concurrency_test.sql (dblink).
-- =============================================================================

begin;

create temp table fx (label text primary key, id uuid not null);

-- ---------------------------------------------------------------------------
-- Fixtures.
--   sub_hold:     limit 100, used 99 → 1 plan credit spendable, no top-ups.
--   sub_settle:   limit 100, used 90 → 10 spendable.
--   sub_combined: limit 100, used 98 → 2 plan left, + linked grant 3 left.
--   sub_noperiod: active but NO usage_period → the non-spendable case.
--   grant_trial:  verified, 15 limit / 14 used → 1 spendable.
--   grant_unverif: NOT verified → non-spendable.
-- ---------------------------------------------------------------------------
insert into public.subscriptions
  (id, ls_subscription_id, tier, status, billing_interval, current_period_end, credits_limit)
values
  (gen_random_uuid(), 'test_x02_hold',     'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_x02_settle',   'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_x02_combined', 'managed', 'active', 'monthly', now() + interval '20 days', 100),
  (gen_random_uuid(), 'test_x02_noperiod', 'managed', 'active', 'monthly', now() + interval '20 days', 100);

insert into fx
select replace(ls_subscription_id, 'test_x02_', 'sub_'), id
from public.subscriptions where ls_subscription_id like 'test_x02_%';

insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
values
  ((select id from fx where label = 'sub_hold'),     now() - interval '5 days', '9999-12-31'::timestamptz, 99),
  ((select id from fx where label = 'sub_settle'),   now() - interval '5 days', '9999-12-31'::timestamptz, 90),
  ((select id from fx where label = 'sub_combined'), now() - interval '5 days', '9999-12-31'::timestamptz, 98);

insert into public.trial_grants
  (id, email_normalized, verified_at, trial_credits_limit, trial_credits_used)
values
  (gen_random_uuid(), 'x02_trial@test',    now(), 15, 14),
  (gen_random_uuid(), 'x02_combined@test', now(), 15, 12),
  (gen_random_uuid(), 'x02_unverif@test',  null,  15, 0);

insert into fx
select case email_normalized
         when 'x02_trial@test'    then 'grant_trial'
         when 'x02_combined@test' then 'grant_combined'
         when 'x02_unverif@test'  then 'grant_unverif'
       end,
       id
from public.trial_grants where email_normalized like 'x02_%@test';

-- ---------------------------------------------------------------------------
-- The assertions.
-- ---------------------------------------------------------------------------
do $t$
declare
  v_sub_hold     uuid := (select id from fx where label = 'sub_hold');
  v_sub_settle   uuid := (select id from fx where label = 'sub_settle');
  v_sub_combined uuid := (select id from fx where label = 'sub_combined');
  v_sub_noperiod uuid := (select id from fx where label = 'sub_noperiod');
  v_grant_trial  uuid := (select id from fx where label = 'grant_trial');
  v_grant_comb   uuid := (select id from fx where label = 'grant_combined');
  v_grant_unver  uuid := (select id from fx where label = 'grant_unverif');
  v_status  text;
  v_json    jsonb;
  v_count   integer;
  v_int     integer;
  v_raised  boolean;
begin
  -- T1: a hold reduces spendable — the second hold past spendable refuses.
  v_status := public.hold_credit('x02-k1', v_sub_hold, null, 1, 600);
  if v_status <> 'held' then
    raise exception 'T1: first hold on 1 spendable credit expected held, got %', v_status;
  end if;
  v_int := public.active_hold_credits(v_sub_hold, null, null);
  if v_int <> 1 then
    raise exception 'T1: active_hold_credits expected 1, got %', v_int;
  end if;
  v_status := public.hold_credit('x02-k2', v_sub_hold, null, 1, 600);
  if v_status <> 'insufficient' then
    raise exception 'T1: second hold must see spendable 0 (1 real - 1 held) and refuse, got %', v_status;
  end if;
  select count(*) into v_count from public.credit_holds where subscription_id = v_sub_hold;
  if v_count <> 1 then
    raise exception 'T1: exactly one hold row expected, got %', v_count;
  end if;

  -- T2: a duplicate-key hold is an idempotent no-op (one reservation per key).
  v_status := public.hold_credit('x02-k1', v_sub_hold, null, 1, 600);
  if v_status <> 'held' then
    raise exception 'T2: duplicate-key hold expected idempotent held, got %', v_status;
  end if;
  select count(*) into v_count from public.credit_holds where subscription_id = v_sub_hold;
  if v_count <> 1 then
    raise exception 'T2: duplicate-key hold must not create a second row, got %', v_count;
  end if;

  -- T3: excluding a request's OWN key exposes its held credit — the call-2
  -- floor gate's contract (settle can afford what call 1 reserved for it).
  v_int := public.active_hold_credits(v_sub_hold, null, 'x02-k1');
  if v_int <> 0 then
    raise exception 'T3: own-key-excluded holds expected 0, got %', v_int;
  end if;

  -- T4: an EXPIRED hold stops reducing spendable immediately (no sweep needed),
  -- and the sweep's delete removes exactly the expired rows.
  update public.credit_holds set expires_at = now() - interval '1 second'
  where idempotency_key = 'x02-k1';
  v_status := public.hold_credit('x02-k3', v_sub_hold, null, 1, 600);
  if v_status <> 'held' then
    raise exception 'T4: hold after the prior one expired expected held, got %', v_status;
  end if;
  delete from public.credit_holds where expires_at < now(); -- the sweep's statement
  select count(*) into v_count from public.credit_holds where subscription_id = v_sub_hold;
  if v_count <> 1 then
    raise exception 'T4: sweep should leave only the live hold, got % rows', v_count;
  end if;
  if not exists (select 1 from public.credit_holds where idempotency_key = 'x02-k3') then
    raise exception 'T4: sweep must not delete an unexpired hold';
  end if;

  -- T5: settle consumes EXACTLY p_credits AND removes the hold, in one call
  -- (= one transaction). The hold itself never charged: used goes 90 → 94 on a
  -- 4-credit settle, not 95.
  v_status := public.hold_credit('x02-k5', v_sub_settle, null, 1, 600);
  if v_status <> 'held' then
    raise exception 'T5: hold expected held, got %', v_status;
  end if;
  v_json := public.settle_credit_hold('x02-k5', v_sub_settle, null, 4);
  if (v_json ->> 'remaining')::integer <> 6 then
    raise exception 'T5: settle remaining expected 6 (10-4), got %', v_json ->> 'remaining';
  end if;
  if (v_json ->> 'hold_released')::boolean is distinct from true then
    raise exception 'T5: settle must report the hold released';
  end if;
  select credits_used into v_int from public.usage_periods where subscription_id = v_sub_settle;
  if v_int <> 94 then
    raise exception 'T5: settle must consume exactly 4 (90→94, the hold is not a charge), got used=%', v_int;
  end if;
  if exists (select 1 from public.credit_holds where idempotency_key = 'x02-k5') then
    raise exception 'T5: settle must delete the hold row';
  end if;

  -- T6: settle with NO prior hold consumes normally (the plain non-dev path).
  v_json := public.settle_credit_hold('x02-k6-never-held', v_sub_settle, null, 2);
  if (v_json ->> 'remaining')::integer <> 4 then
    raise exception 'T6: no-hold settle remaining expected 4 (6-2), got %', v_json ->> 'remaining';
  end if;
  if (v_json ->> 'hold_released')::boolean is distinct from false then
    raise exception 'T6: no-hold settle must report hold_released=false';
  end if;

  -- T7: settle against a NON-spendable account → NULL, NOTHING spent, and the
  -- hold row is left in place (TTL is its release path).
  insert into public.credit_holds (idempotency_key, subscription_id, credits_held, expires_at)
  values ('x02-k7', v_sub_noperiod, 1, now() + interval '10 minutes');
  v_json := public.settle_credit_hold('x02-k7', v_sub_noperiod, null, 3);
  if v_json is not null then
    raise exception 'T7: settle on a no-period subscription expected NULL, got %', v_json;
  end if;
  if not exists (select 1 from public.credit_holds where idempotency_key = 'x02-k7') then
    raise exception 'T7: a failed (non-spendable) settle must NOT release the hold';
  end if;

  -- T8: pure-trial ledger — hold gates on the grant's spendable remainder;
  -- settle consumes via consume_trial_credit_overspend (may go negative).
  v_status := public.hold_credit('x02-k8', null, v_grant_trial, 1, 600);
  if v_status <> 'held' then
    raise exception 'T8: trial hold on 1 spendable expected held, got %', v_status;
  end if;
  v_status := public.hold_credit('x02-k8b', null, v_grant_trial, 1, 600);
  if v_status <> 'insufficient' then
    raise exception 'T8: second trial hold must refuse (spendable 0), got %', v_status;
  end if;
  v_json := public.settle_credit_hold('x02-k8', null, v_grant_trial, 3);
  if (v_json ->> 'remaining')::integer <> -2 then
    raise exception 'T8: trial settle remaining expected -2 (1-3, overspend), got %', v_json ->> 'remaining';
  end if;
  select trial_credits_used into v_int from public.trial_grants where id = v_grant_trial;
  if v_int <> 17 then
    raise exception 'T8: trial settle must consume exactly 3 (14→17), got %', v_int;
  end if;
  if exists (select 1 from public.credit_holds where idempotency_key = 'x02-k8') then
    raise exception 'T8: trial settle must delete the hold row';
  end if;

  -- T9: an unverified grant is non-spendable for a pure-trial hold.
  v_status := public.hold_credit('x02-k9', null, v_grant_unver, 1, 600);
  if v_status <> 'insufficient' then
    raise exception 'T9: unverified-grant hold expected insufficient, got %', v_status;
  end if;

  -- T9b: a subscription with NO usage_period is non-spendable for a hold.
  v_status := public.hold_credit('x02-k9b', v_sub_noperiod, null, 1, 600);
  if v_status <> 'insufficient' then
    raise exception 'T9b: no-period-subscription hold expected insufficient, got %', v_status;
  end if;

  -- T10: COMBINED account — the verified grant's remainder participates in the
  -- hold's spendable figure, and settle dispatches to the combined spender
  -- (trial drained first). Spendable = 2 plan + 3 trial = 5.
  v_status := public.hold_credit('x02-k10', v_sub_combined, v_grant_comb, 1, 600);
  if v_status <> 'held' then
    raise exception 'T10: combined hold expected held, got %', v_status;
  end if;
  v_status := public.hold_credit('x02-k11', v_sub_combined, v_grant_comb, 4, 600);
  if v_status <> 'held' then
    raise exception 'T10: second combined hold (4 of remaining spendable 4) expected held, got %', v_status;
  end if;
  v_status := public.hold_credit('x02-k12', v_sub_combined, v_grant_comb, 1, 600);
  if v_status <> 'insufficient' then
    raise exception 'T10: combined hold past spendable (5 real, 5 held) expected insufficient, got %', v_status;
  end if;
  v_json := public.settle_credit_hold('x02-k10', v_sub_combined, v_grant_comb, 4);
  if (v_json ->> 'remaining')::integer <> 1 then
    raise exception 'T10: combined settle remaining expected 1 (5-4), got %', v_json ->> 'remaining';
  end if;
  if (v_json ->> 'trial_spent')::integer <> 3 or (v_json ->> 'plan_spent')::integer <> 1 then
    raise exception 'T10: combined settle must drain trial first (3 trial + 1 plan), got %', v_json;
  end if;
  if (v_json ->> 'hold_released')::boolean is distinct from true then
    raise exception 'T10: combined settle must release its hold';
  end if;
  if not exists (select 1 from public.credit_holds where idempotency_key = 'x02-k11') then
    raise exception 'T10: settling k10 must not touch the unrelated k11 hold';
  end if;

  -- T11: a cross-account collision on the SAME key fails closed (raises) and
  -- never touches the existing hold. k11 is owned by sub_combined; a trial
  -- identity replaying that key must not get an idempotent pass.
  v_raised := false;
  begin
    perform public.hold_credit('x02-k11', null, v_grant_trial, 1, 600);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'T11: cross-account key collision must raise (fail closed)';
  end if;
  select count(*) into v_count from public.credit_holds where idempotency_key = 'x02-k11';
  if v_count <> 1 then
    raise exception 'T11: the foreign hold must survive the collision untouched';
  end if;

  -- T11b: settle with a mismatched owner must not release a foreign hold (it
  -- consumes normally on ITS ledger; k11 belongs to sub_combined).
  v_json := public.settle_credit_hold('x02-k11', null, v_grant_trial, 1);
  if (v_json ->> 'hold_released')::boolean is distinct from false then
    raise exception 'T11b: owner-mismatched settle must not release the foreign hold';
  end if;
  if not exists (select 1 from public.credit_holds where idempotency_key = 'x02-k11') then
    raise exception 'T11b: the foreign hold must still exist';
  end if;

  -- T12: the one-owner CHECK rejects malformed rows (both / neither).
  v_raised := false;
  begin
    insert into public.credit_holds (idempotency_key, subscription_id, trial_grant_id, credits_held, expires_at)
    values ('x02-bad-both', v_sub_hold, v_grant_trial, 1, now() + interval '1 minute');
  exception when check_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'T12: both-owners insert must violate credit_holds_one_owner';
  end if;
  v_raised := false;
  begin
    insert into public.credit_holds (idempotency_key, credits_held, expires_at)
    values ('x02-bad-neither', 1, now() + interval '1 minute');
  exception when check_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'T12: no-owner insert must violate credit_holds_one_owner';
  end if;

  -- T13: invalid hold arguments fail closed (raise), never a silent pass.
  v_raised := false;
  begin
    perform public.hold_credit('x02-k13', v_sub_hold, null, 0, 600);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'T13: p_credits=0 must raise';
  end if;
  v_raised := false;
  begin
    perform public.hold_credit(null, v_sub_hold, null, 1, 600);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'T13: null key must raise';
  end if;

  -- T14: the sweep cron job exists (invariant 6's scheduled half).
  if not exists (select 1 from cron.job where jobname = 'credit-holds-prune') then
    raise exception 'T14: credit-holds-prune cron job missing';
  end if;

  raise notice 'X-02 CREDIT HOLDS TESTS PASSED — hold/settle/release/expiry/owner-matching all hold ✓';
end;
$t$;

rollback;
