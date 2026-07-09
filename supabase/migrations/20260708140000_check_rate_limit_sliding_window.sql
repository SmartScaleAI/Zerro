-- =============================================================================
-- Pre-launch hardening A-15 — check_rate_limit: fixed → SLIDING window
-- =============================================================================
-- The fixed-window counter allows a 2x boundary burst: p_max requests in the
-- last instant of one window plus p_max in the first instant of the next is
-- 2*p_max inside a single rolling window. This replaces the body with the
-- standard two-bucket sliding-window ESTIMATE (the Cloudflare algorithm):
--
--   cur_count  := count-then-increment of the CURRENT fixed window's row
--                 (unchanged from the old body — the row is created/incremented
--                 even when the verdict is FALSE);
--   prev_count := the PREVIOUS window's row count (0 when absent);
--   weight     := (w - elapsed_in_current_window) / w
--                 — the fraction of the previous window still inside the
--                 rolling window that ends now;
--   allowed    := cur_count + prev_count * weight <= p_max.
--
-- Any rolling-window burst is now bounded to ~p_max instead of 2x, with at
-- most 2 live rows per key (current + previous) — both already swept by A-14's
-- rate-limits-prune. Callers are untouched: same RPC name, args, and boolean.
--
-- CRITICAL invariants preserved by this replace:
--   * The EXACT 3-arg signature (text, integer, integer) — the function's
--     identity. create-or-replace onto the same signature keeps the existing
--     service_role EXECUTE grant (20260601120200_billing_grants.sql); a
--     signature change would silently orphan it. The grant is re-affirmed
--     below anyway (idempotent).
--   * `set search_path = ''` — the D-02 hardening pin. create-or-replace WIPES
--     a function's SET clauses, so omitting it here would silently UNDO the
--     pin; it is re-included inline. (All object references are
--     schema-qualified accordingly; pg_catalog builtins need no qualifier.)
--   * SECURITY INVOKER (the default, as before) — only service_role can
--     execute it, and it owns the table access.
--
-- IDEMPOTENT: create-or-replace + a repeated grant are no-ops on re-apply.
-- =============================================================================

create or replace function public.check_rate_limit(
  p_key            text,
  p_max            integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_now_epoch  double precision;
  v_cur_epoch  double precision;  -- epoch of the current fixed-window start
  v_cur_count  integer;
  v_prev_count integer;
  v_weight     double precision;
begin
  v_now_epoch := extract(epoch from now());
  v_cur_epoch := floor(v_now_epoch / p_window_seconds) * p_window_seconds;

  -- Count-then-check on the current window (exactly the old fixed-window
  -- upsert), so the accounting row exists even when the verdict is FALSE.
  insert into public.rate_limits (key, window_start, count)
  values (p_key, to_timestamp(v_cur_epoch), 1)
  on conflict (key, window_start)
    do update set count = public.rate_limits.count + 1
  returning count into v_cur_count;

  select r.count into v_prev_count
    from public.rate_limits r
    where r.key = p_key
      and r.window_start = to_timestamp(v_cur_epoch - p_window_seconds);
  v_prev_count := coalesce(v_prev_count, 0);

  -- Fraction of the previous window still inside the rolling window ending
  -- now. elapsed is in [0, w), so the weight is in (0, 1].
  v_weight := (p_window_seconds - (v_now_epoch - v_cur_epoch)) / p_window_seconds;

  return (v_cur_count + v_prev_count * v_weight) <= p_max;
end;
$$;

comment on function public.check_rate_limit(text, integer, integer) is
  'Atomic SLIDING-window rate limiter (two-bucket estimate: cur + prev*weight). TRUE if within p_max for the rolling p_window_seconds window. search_path pinned (D-02).';

-- create-or-replace preserves the ACL, but re-affirm the D1 grant so this
-- migration also stands alone on a fresh database.
grant execute on function public.check_rate_limit(text, integer, integer) to service_role;
