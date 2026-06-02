-- =============================================================================
-- Zerro billing — generation concurrency slots (Phase D2)
-- =============================================================================
-- The D2 `generate` proxy needs a PER-SUBSCRIBER CONCURRENCY CAP of 1 in flight.
-- That cap is not just an anti-abuse knob — it is what makes the credit ordering
-- correct. `generate` uses CHECK-THEN-CONSUME-ON-SUCCESS: it confirms a credit is
-- available, calls OpenAI, then spends the credit atomically via consume_credit()
-- only on success. The one race that ordering can't see is two near-simultaneous
-- "last credit" requests both passing the availability check and both paying
-- OpenAI before either consumes. consume_credit() lets only ONE of them commit,
-- so the other has paid OpenAI without a credit. Bounding a single subscriber to
-- ONE in-flight generation removes that race for that subscriber (see the
-- handler's credit-ordering note). consume_credit() remains the hard
-- double-spend guard regardless.
--
-- WHY A TABLE AND NOT a fixed-window counter: rate_limits / check_rate_limit is a
-- COUNT per window — "N calls per 60s", which would wrongly reject legitimate
-- sequential generations. A concurrency cap is "N IN FLIGHT AT ONCE": acquired at
-- request start, released at request end. That needs a claim row, not a counter.
--
-- WHY A TABLE AND NOT a pg advisory lock: a transaction-scoped advisory lock
-- (pg_try_advisory_xact_lock) is released at the end of the SQL transaction, but
-- a `generate` request spans MULTIPLE round-trips (the OpenAI calls happen in the
-- Edge Function between DB calls), so no single DB transaction wraps it. A
-- session-scoped lock would leak across PostgREST's pooled, reused connections.
-- A claim row with a stale-reclaim timestamp is the reliable primitive here.
--
-- STALENESS RECLAIM: if a request crashes / times out before releasing its slot
-- (function eviction, an OpenAI hang past our timeout), the row would otherwise
-- lock the subscriber out forever. acquire_generation_slot() therefore RECLAIMS a
-- slot whose acquired_at is older than p_stale_seconds. Set that window LONGER
-- than the worst-case OpenAI round-trip (handler default GENERATE_SLOT_STALE_*),
-- so a slow-but-live request is never stolen out from under itself.
-- =============================================================================

create table public.generation_slots (
  subscription_id uuid primary key references public.subscriptions(id) on delete cascade,
  acquired_at     timestamptz not null default now()
);

comment on table public.generation_slots is
  'In-flight generation marker: at most one row per subscription = concurrency cap 1. Stale rows are reclaimed by acquire_generation_slot. Written only by the service role inside the D2 generate proxy.';

-- RLS deny-by-default, matching every other billing table (*_billing_rls.sql).
-- Only the service role (inside the Edge Function) ever touches this table.
alter table public.generation_slots enable row level security;
alter table public.generation_slots force  row level security;
-- INTENTIONALLY NO POLICIES. Deny-by-default is the design.

-- =============================================================================
-- acquire_generation_slot — atomically claim the (single) in-flight slot for a
-- subscription, RECLAIMING a stale one. Returns TRUE if the caller now holds the
-- slot, FALSE if a fresh (non-stale) slot is already held (request in flight).
-- =============================================================================
-- Atomicity: the INSERT … ON CONFLICT runs as one statement under the primary
-- key's row lock.
--   * no row yet           → INSERT, RETURNING yields a row → TRUE (acquired).
--   * row exists & STALE   → the ON CONFLICT UPDATE's WHERE matches → updates
--                            acquired_at, RETURNING yields a row → TRUE (reclaimed).
--   * row exists & FRESH   → the WHERE is false → zero rows updated, RETURNING
--                            yields NOTHING → v_acquired stays NULL → FALSE (busy).
-- Two concurrent acquires serialize on the pk lock: the first inserts, the second
-- conflicts onto a now-fresh row and gets FALSE. Exactly one holder.
-- =============================================================================
create or replace function public.acquire_generation_slot(
  p_subscription_id uuid,
  p_stale_seconds   integer
)
returns boolean
language plpgsql
as $$
declare
  v_acquired boolean;
begin
  insert into public.generation_slots (subscription_id, acquired_at)
  values (p_subscription_id, now())
  on conflict (subscription_id) do update
    set acquired_at = now()
    where public.generation_slots.acquired_at
            < now() - make_interval(secs => p_stale_seconds)
  returning true into v_acquired;

  return coalesce(v_acquired, false);
end;
$$;

comment on function public.acquire_generation_slot(uuid, integer) is
  'Atomically claim the single in-flight generation slot for a subscription (reclaiming a slot older than p_stale_seconds). TRUE = acquired, FALSE = a live request already holds it.';

-- =============================================================================
-- release_generation_slot — drop the slot at the end of a generation (success OR
-- failure). Idempotent: deleting an absent / already-reclaimed row is a no-op.
-- =============================================================================
create or replace function public.release_generation_slot(p_subscription_id uuid)
returns void
language plpgsql
as $$
begin
  delete from public.generation_slots where subscription_id = p_subscription_id;
end;
$$;

comment on function public.release_generation_slot(uuid) is
  'Release a subscription''s in-flight generation slot. Idempotent.';

-- The functions are SECURITY INVOKER and called by service_role; grant table +
-- EXECUTE privileges explicitly (RLS bypass still requires table-level grants;
-- see *_billing_grants.sql for the rationale).
grant select, insert, update, delete on public.generation_slots to service_role;
grant execute on function public.acquire_generation_slot(uuid, integer) to service_role;
grant execute on function public.release_generation_slot(uuid) to service_role;
