-- =============================================================================
-- A-15 sliding-window limiter test (20260708140000_check_rate_limit_sliding_window).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/check_rate_limit_sliding_test.sql
--
-- One transaction, ROLLED BACK at the end — fixtures never persist. RAISE
-- EXCEPTION on any violated invariant; ON_ERROR_STOP makes psql exit non-zero.
-- Invariants proven:
--   * within limit in a fresh window → TRUE; the (max+1)th call → FALSE
--     (count-then-check preserved);
--   * BOUNDARY: a previous-window row at count = p_max still weighs into the
--     current window's verdict (no fixed-window 2x reset). With p_max = 1 the
--     assertion is time-independent: weight ∈ (0, 1] anywhere in the window,
--     so estimated = 1 + 1*weight > 1 ALWAYS → FALSE, deterministically.
--   * control: the same first call WITHOUT a seeded previous row → TRUE.
-- NOTE: now() is transaction-fixed, so the window starts computed here match
-- the ones the function computes exactly.
-- =============================================================================

begin;

do $$
declare
  w          integer := 3600; -- 1 hour
  v_cur      timestamptz;
  v_prev     timestamptz;
  ok         boolean;
  i          integer;
begin
  -- The SAME window anchoring the function uses (now() is fixed in this tx).
  v_cur  := to_timestamp(floor(extract(epoch from now()) / w) * w);
  v_prev := to_timestamp(floor(extract(epoch from now()) / w) * w - w);

  -- 1) Fresh window, max 3: three calls pass, the 4th is limited.
  for i in 1..3 loop
    ok := public.check_rate_limit('test:sliding:basic', 3, w);
    if not ok then
      raise exception 'basic: call % of 3 unexpectedly limited', i;
    end if;
  end loop;
  ok := public.check_rate_limit('test:sliding:basic', 3, w);
  if ok then
    raise exception 'basic: the (max+1)th call in the same window must be limited';
  end if;

  -- 2) BOUNDARY: previous window already at p_max (= 1) → the first call of
  --    the CURRENT window must be limited (the old fixed window would have
  --    reset to a fresh allowance here — the 2x burst).
  insert into public.rate_limits (key, window_start, count)
  values ('test:sliding:boundary', v_prev, 1);
  ok := public.check_rate_limit('test:sliding:boundary', 1, w);
  if ok then
    raise exception 'boundary: previous window at p_max must still limit the current window';
  end if;

  -- 3) Control: identical first call with NO previous-window row → allowed.
  ok := public.check_rate_limit('test:sliding:control', 1, w);
  if not ok then
    raise exception 'control: first call with no history must be allowed';
  end if;

  raise notice 'A-15 sliding-window limiter OK: count-then-check + boundary carry-over hold';
end $$;

rollback;
