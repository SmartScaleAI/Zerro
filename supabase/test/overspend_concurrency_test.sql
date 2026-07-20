-- =============================================================================
-- A-17 — consume_credit_overspend under CONCURRENCY: two sessions spending the
-- same subscription at once must serialize on the period-row lock (no lost
-- update, the second spender sees the first's committed write).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/overspend_concurrency_test.sql
--
-- UNLIKE the other suites this file cannot run inside one rolled-back
-- transaction: the two "sessions" are dblink connections, and they can only
-- see COMMITTED fixture rows. So the fixtures are committed up front, tagged
-- 'test_a17_conc', and deleted unconditionally at the end (plus defensively at
-- the start, for reruns after a mid-file failure).
--
-- If the dblink extension (or a loopback conninfo) is unavailable in the
-- harness, the test SKIPs with a notice instead of failing — the invariant is
-- then only covered by code review of the FOR UPDATE lock order.
--
-- The scenario: limit 100, used 90 (10 avail, no top-ups); two concurrent
-- consume_credit_overspend(sub, 8) calls.
--   * session 1 (open transaction) spends 8 → remaining 2, used 98;
--   * session 2 MUST block on the period-row lock while session 1's
--     transaction is open (asserted via dblink_is_busy);
--   * after session 1 commits, session 2 re-reads the FRESH row: avail 2,
--     spend 8 → remaining −6, used 98+2+6(overflow) = 106.
-- A lost update (session 2 computing from the stale used=90) would return 2
-- and/or leave used at 98 — both asserted against.
-- =============================================================================

-- Defensive cleanup from any prior failed run.
delete from public.usage_periods where subscription_id in
  (select id from public.subscriptions where ls_subscription_id = 'test_a17_conc');
delete from public.subscriptions where ls_subscription_id = 'test_a17_conc';

-- Capability probe: dblink present AND a loopback conninfo that works from
-- inside the server. Records the working conninfo (or NULL = skip).
create temp table a17_conc (conninfo text);
do $$
declare
  candidate text;
begin
  begin
    create extension if not exists dblink;
  exception when others then
    insert into a17_conc values (null);
    raise notice 'A-17 concurrency SKIPPED — dblink unavailable: %', sqlerrm;
    return;
  end;
  foreach candidate in array array[
    'dbname=' || current_database(),
    'host=localhost port=5432 dbname=' || current_database() || ' user=postgres password=postgres',
    'host=127.0.0.1 port=5432 dbname=' || current_database() || ' user=postgres password=postgres'
  ] loop
    begin
      perform dblink_connect('a17_probe', candidate);
      perform dblink_disconnect('a17_probe');
      insert into a17_conc values (candidate);
      return;
    exception when others then
      null; -- try the next candidate
    end;
  end loop;
  insert into a17_conc values (null);
  raise notice 'A-17 concurrency SKIPPED — no working loopback conninfo for dblink';
end;
$$;

-- Fixture (committed so the dblink sessions can see it) — only when runnable.
insert into public.subscriptions
  (id, ls_subscription_id, tier, status, billing_interval, current_period_end, credits_limit)
select gen_random_uuid(), 'test_a17_conc', 'managed', 'active', 'monthly', now() + interval '20 days', 100
where (select conninfo from a17_conc) is not null;

insert into public.usage_periods (subscription_id, period_start, period_end, credits_used)
select id, now() - interval '5 days', '9999-12-31'::timestamptz, 90
from public.subscriptions where ls_subscription_id = 'test_a17_conc'
  and (select conninfo from a17_conc) is not null;

-- The test proper.
do $t$
declare
  v_conninfo text;
  v_sub      uuid;
  v_r1       integer;
  v_r2       integer;
  v_used     integer;
  v_waits    integer := 0;
begin
  select conninfo into v_conninfo from a17_conc;
  if v_conninfo is null then
    return; -- skipped (notice already raised by the probe)
  end if;
  select id into v_sub from public.subscriptions where ls_subscription_id = 'test_a17_conc';

  perform dblink_connect('a17_c1', v_conninfo);
  perform dblink_connect('a17_c2', v_conninfo);

  -- Session 1: spend inside an OPEN transaction — the period-row FOR UPDATE
  -- lock is held until the commit below.
  perform dblink_exec('a17_c1', 'begin');
  select r into v_r1 from dblink(
    'a17_c1',
    format('select public.consume_credit_overspend(%L::uuid, 8)', v_sub)
  ) as t(r integer);
  if v_r1 is distinct from 2 then
    raise exception 'concurrency: session 1 expected remaining 2 ((10)-8), got %', v_r1;
  end if;

  -- Session 2: the same spend, asynchronously — it must BLOCK on the lock.
  perform dblink_send_query(
    'a17_c2',
    format('select public.consume_credit_overspend(%L::uuid, 8)', v_sub)
  );
  perform pg_sleep(0.5);
  if dblink_is_busy('a17_c2') <> 1 then
    raise exception 'concurrency: session 2 completed while session 1 held the period lock — the FOR UPDATE mutex is broken';
  end if;

  -- Release the lock; session 2 must finish promptly on the FRESH row state.
  perform dblink_exec('a17_c1', 'commit');
  while dblink_is_busy('a17_c2') = 1 loop
    v_waits := v_waits + 1;
    if v_waits > 100 then
      raise exception 'concurrency: session 2 still blocked 10s after the commit';
    end if;
    perform pg_sleep(0.1);
  end loop;

  select r into v_r2 from dblink_get_result('a17_c2') as t(r integer);
  -- Drain the async cycle (dblink requires consuming until the empty set).
  perform r from dblink_get_result('a17_c2') as t(r integer);

  if v_r2 is distinct from -6 then
    raise exception 'concurrency: session 2 expected remaining -6 (fresh avail 2 - 8), got % (2 would mean it read the STALE pre-commit row)', v_r2;
  end if;

  select credits_used into v_used from public.usage_periods where subscription_id = v_sub;
  if v_used <> 106 then
    raise exception 'concurrency: expected credits_used 106 (90+8+8, both spends applied), got % (98 would be a lost update)', v_used;
  end if;

  perform dblink_disconnect('a17_c1');
  perform dblink_disconnect('a17_c2');
  raise notice 'A-17 CONCURRENCY TEST PASSED — serialized on the period lock, no lost update (used 106, returns 2/-6) ✓';
end;
$t$;

-- Unconditional cleanup (the fixtures were committed).
delete from public.usage_periods where subscription_id in
  (select id from public.subscriptions where ls_subscription_id = 'test_a17_conc');
delete from public.subscriptions where ls_subscription_id = 'test_a17_conc';
