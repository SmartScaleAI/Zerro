-- =============================================================================
-- X-02 — hold_credit under CONCURRENCY: two sessions racing for the SAME last
-- spendable credit must serialize on the account (period-row) lock, so only
-- one hold can be placed (invariants 1 + 2, the two-holds race).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/credit_holds_concurrency_test.sql
--
-- UNLIKE the rolled-back suites this file cannot run inside one transaction:
-- the two "sessions" are dblink connections, and they can only see COMMITTED
-- fixture rows — same harness as overspend_concurrency_test.sql (A-17).
-- Fixtures are committed up front, tagged 'test_x02_conc', and deleted
-- unconditionally at the end (plus defensively at the start, for reruns).
--
-- If dblink (or a loopback conninfo) is unavailable, the test SKIPs with a
-- notice — the invariant is then only covered by code review of hold_credit's
-- lock-then-check ordering.
--
-- The scenario: limit 100, used 99 (1 spendable, no top-ups, no other holds);
-- two concurrent hold_credit(sub, 1) calls with different keys.
--   * session 1 (open transaction) holds → 'held' (period row locked);
--   * session 2 MUST block on that lock while session 1's txn is open
--     (asserted via dblink_is_busy) — it must NOT compute spendable from the
--     pre-hold snapshot;
--   * after session 1 commits, session 2 re-reads the FRESH state: spendable
--     1 − 1 held = 0 → 'insufficient'.
-- A broken mutex would return 'held' twice → 2 reservations against 1 credit —
-- exactly the double-spend window invariant 2 closes.
-- =============================================================================

-- Defensive cleanup from any prior failed run.
delete from public.credit_holds where idempotency_key like 'x02conc-%';
delete from public.usage_periods where subscription_id in
  (select id from public.subscriptions where ls_subscription_id = 'test_x02_conc');
delete from public.subscriptions where ls_subscription_id = 'test_x02_conc';

-- Capability probe: dblink present AND a loopback conninfo that works from
-- inside the server (identical to A-17's probe).
create temp table x02_conc (conninfo text);
do $$
declare
  candidate text;
begin
  begin
    create extension if not exists dblink;
  exception when others then
    insert into x02_conc values (null);
    raise notice 'X-02 concurrency SKIPPED — dblink unavailable: %', sqlerrm;
    return;
  end;
  foreach candidate in array array[
    'dbname=' || current_database(),
    'host=localhost port=5432 dbname=' || current_database() || ' user=postgres password=postgres',
    'host=127.0.0.1 port=5432 dbname=' || current_database() || ' user=postgres password=postgres'
  ] loop
    begin
      perform dblink_connect('x02_probe', candidate);
      perform dblink_disconnect('x02_probe');
      insert into x02_conc values (candidate);
      return;
    exception when others then
      null; -- try the next candidate
    end;
  end loop;
  insert into x02_conc values (null);
  raise notice 'X-02 concurrency SKIPPED — no working loopback conninfo for dblink';
end;
$$;

-- Fixture (committed so the dblink sessions can see it) — only when runnable.
insert into public.subscriptions
  (id, ls_subscription_id, tier, status, billing_interval, current_period_end, credits_limit)
select gen_random_uuid(), 'test_x02_conc', 'managed', 'active', 'monthly', now() + interval '20 days', 100
where (select conninfo from x02_conc) is not null;

insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 99
from public.subscriptions where ls_subscription_id = 'test_x02_conc'
  and (select conninfo from x02_conc) is not null;

-- The test proper.
do $t$
declare
  v_conninfo text;
  v_sub      uuid;
  v_r1       text;
  v_r2       text;
  v_count    integer;
  v_waits    integer := 0;
begin
  select conninfo into v_conninfo from x02_conc;
  if v_conninfo is null then
    return; -- skipped (notice already raised by the probe)
  end if;
  select id into v_sub from public.subscriptions where ls_subscription_id = 'test_x02_conc';

  perform dblink_connect('x02_c1', v_conninfo);
  perform dblink_connect('x02_c2', v_conninfo);

  -- Session 1: hold inside an OPEN transaction — the period-row FOR UPDATE
  -- lock is held until the commit below.
  perform dblink_exec('x02_c1', 'begin');
  select r into v_r1 from dblink(
    'x02_c1',
    format('select public.hold_credit(%L, %L::uuid, null, 1, 600)', 'x02conc-a', v_sub)
  ) as t(r text);
  if v_r1 is distinct from 'held' then
    raise exception 'concurrency: session 1 expected held (1 spendable), got %', v_r1;
  end if;

  -- Session 2: a different-key hold for the same account, asynchronously — it
  -- must BLOCK on the period lock (NOT race past it on a stale snapshot).
  perform dblink_send_query(
    'x02_c2',
    format('select public.hold_credit(%L, %L::uuid, null, 1, 600)', 'x02conc-b', v_sub)
  );
  perform pg_sleep(0.5);
  if dblink_is_busy('x02_c2') <> 1 then
    raise exception 'concurrency: session 2 completed while session 1 held the period lock — hold_credit''s account mutex is broken';
  end if;

  -- Release the lock; session 2 must finish promptly on the FRESH state.
  perform dblink_exec('x02_c1', 'commit');
  while dblink_is_busy('x02_c2') = 1 loop
    v_waits := v_waits + 1;
    if v_waits > 100 then
      raise exception 'concurrency: session 2 still blocked 10s after the commit';
    end if;
    perform pg_sleep(0.1);
  end loop;

  select r into v_r2 from dblink_get_result('x02_c2') as t(r text);
  -- Drain the async cycle (dblink requires consuming until the empty set).
  perform r from dblink_get_result('x02_c2') as t(r text);

  if v_r2 is distinct from 'insufficient' then
    raise exception 'concurrency: session 2 expected insufficient (1 real - 1 committed hold), got % (held would mean 2 reservations against 1 credit)', v_r2;
  end if;

  select count(*) into v_count from public.credit_holds where subscription_id = v_sub;
  if v_count <> 1 then
    raise exception 'concurrency: exactly 1 hold row expected after the race, got %', v_count;
  end if;

  perform dblink_disconnect('x02_c1');
  perform dblink_disconnect('x02_c2');
  raise notice 'X-02 CONCURRENCY TEST PASSED — serialized on the account lock, one reservation for one spendable credit ✓';
end;
$t$;

-- Unconditional cleanup (the fixtures were committed).
delete from public.credit_holds where idempotency_key like 'x02conc-%';
delete from public.usage_periods where subscription_id in
  (select id from public.subscriptions where ls_subscription_id = 'test_x02_conc');
delete from public.subscriptions where ls_subscription_id = 'test_x02_conc';
