-- =============================================================================
-- Zerro billing — multi-model variable credits (Plan Phase 1)
-- =============================================================================
-- Schema groundwork for the 6-model selector + variable per-model credit
-- system (docs/IMPLEMENTATION-PLAN-multi-model-credits.md §1, Phase 1):
--
--   1. generation_log gains model/provider columns (non-content metadata) so
--      post-launch per-model p75 cost calibration is possible (§2 caveat).
--   2. subscriptions gains billing_interval ('monthly'|'yearly') — both map to
--      the SAME pro tier / 300 credits / 30-day cadence (F1); webhook sets it
--      in Phase 5.
--   3. topup_credits — the second credit bucket. Survives the monthly reset BY
--      CONSTRUCTION (the reset only rolls usage_periods; nothing here is ever
--      touched by it), expires 12 months after purchase (expires_at set by the
--      Phase 5 webhook), idempotent per LemonSqueezy order via ls_order_id.
--   4. consume_credit(uuid, integer) — variable, two-bucket, all-or-nothing
--      atomic spend (plan first, then top-ups FIFO by expiry). The money-safety
--      heart of the feature; full atomicity argument at the function.
--   5. consume_trial_credit(uuid, integer) — variable spend for trials (single
--      bucket; trials cannot buy top-ups).
--
-- The existing 1-arg consume_credit(uuid) / consume_trial_credit(uuid) are
-- DELIBERATELY LEFT UNTOUCHED: redirecting them to the 2-arg versions would
-- silently change their return semantics (plan-only remaining → combined
-- remaining) under the deployed handler before Phase 4 migrates and audits the
-- callers. Postgres treats the overloads as distinct functions; the old
-- signatures keep working byte-for-byte until Phase 4 moves callers over.
--
-- Conventions: append-only migration; RLS deny-by-default with FORCE and no
-- policies (mirror *_billing_rls.sql); explicit service_role table + EXECUTE
-- grants (mirror *_billing_grants.sql — overloads need their OWN grant).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. generation_log: which model/provider produced each generation.
--    Non-content metadata only — consistent with §14.5 (still never transcript,
--    audio, frames, or prompt text). Nullable: rows from before this migration
--    have no model attribution.
-- -----------------------------------------------------------------------------
alter table public.generation_log
  add column model    text,
  add column provider text;

comment on table public.generation_log is
  'Token counts + cost + model/provider metadata only. Never transcript, audio, or frames (§14.5). model/provider are non-content attribution for per-model cost calibration.';

-- -----------------------------------------------------------------------------
-- 2. subscriptions.billing_interval — monthly ($15) vs yearly ($12/mo, billed
--    annually). BOTH map to the same pro tier with the same 300-credit grant
--    and 30-day reset cadence (F1); this column is display/analytics metadata,
--    not a gate. Nullable: set by the LemonSqueezy webhook from Phase 5 on;
--    pre-existing rows backfill naturally on their next subscription event.
-- -----------------------------------------------------------------------------
alter table public.subscriptions
  add column billing_interval text
    check (billing_interval in ('monthly', 'yearly'));

-- -----------------------------------------------------------------------------
-- 3. topup_credits — purchased credit packs (Boost 200 / Power 500), the second
--    spend bucket. Key properties, each enforced structurally:
--      * SURVIVES the monthly reset: the reset path only rolls usage_periods —
--        no code path ever updates this table on renewal.
--      * 12-month expiry: expires_at (= purchased_at + 12 months, computed by
--        the Phase 5 webhook); spend + balance queries filter expires_at>now().
--      * Webhook idempotency: ls_order_id UNIQUE — a redelivered purchase event
--        conflicts instead of double-crediting.
--      * A row can never overspend: credits_used <= credits_total CHECK.
-- -----------------------------------------------------------------------------
create table public.topup_credits (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  credits_total   integer not null check (credits_total > 0),
  credits_used    integer not null default 0 check (credits_used >= 0),
  purchased_at    timestamptz not null default now(),
  expires_at      timestamptz not null,   -- purchased_at + interval '12 months' (set by the Phase 5 webhook)
  ls_order_id     text unique,            -- idempotency key for the purchase webhook
  created_at      timestamptz not null default now(),

  check (credits_used <= credits_total)
);

-- Serves both the balance sum and the FIFO spend scan (filter by subscription,
-- order/filter by expiry).
create index topup_credits_sub_expiry_idx
  on public.topup_credits (subscription_id, expires_at);

comment on table public.topup_credits is
  'Purchased top-up credit packs (plan §1.4). Never touched by the monthly reset (only usage_periods rolls); expires 12 months from purchase; spent FIFO by expires_at after plan credits. ls_order_id dedupes webhook redelivery.';

-- RLS: deny-by-default, FORCE, no policies — service-role Edge Functions are
-- the only readers/writers, exactly like every other billing table.
alter table public.topup_credits enable row level security;
alter table public.topup_credits force  row level security;
-- INTENTIONALLY NO POLICIES.

-- =============================================================================
-- 4. consume_credit(uuid, integer) — variable two-bucket atomic spend.
-- =============================================================================
-- Spends p_credits against the subscription: plan period first, remainder from
-- non-expired top-up rows FIFO by expires_at (nearest expiry first). Returns
-- the COMBINED remaining balance (plan + non-expired top-up) after the spend,
-- or NULL with NOTHING spent if the combined balance can't cover p_credits
-- (all-or-nothing — a generation is never partially charged).
--
-- ATOMICITY / DOUBLE-SPEND GUARD (the money-safety heart):
--   * ONE function = ONE transaction. There is no state between "check" and
--     "spend" that another caller can observe or interleave with.
--   * The subscription's LATEST usage_period row is locked FIRST with
--     SELECT … FOR UPDATE. That row lock is the per-subscription mutex for the
--     entire two-bucket operation: every concurrent consume_credit for the same
--     subscription serializes on it before reading ANY balance. (This is also
--     why the function requires a period row to exist even for a hypothetical
--     top-up-only spend — the period row is the serialization anchor. In
--     practice a paid subscription always has one: the payment webhook opens it
--     before the first generation can run.)
--   * Spendable top-up rows are then locked with FOR UPDATE (inside the
--     availability sum) in the same FIFO order the spend loop uses. Lock order
--     is therefore identical across callers (period → top-ups by expiry), so
--     two spenders cannot deadlock.
--   * Under READ COMMITTED, a caller that blocked on the period lock re-reads
--     the row's NEWLY COMMITTED version once the lock releases (EvalPlanQual),
--     so its availability math starts from fresh credits_used values — the
--     classic lost-update race cannot happen.
--   * The all-or-nothing gate runs BEFORE any UPDATE: an insufficient balance
--     returns NULL having taken locks but written nothing, so there is nothing
--     to roll back and no partial charge to compensate.
--   * Benign races, accepted deliberately (same exposure as the existing 1-arg
--     function): a period INSERT racing this call (renewal mid-generation) may
--     land the spend on the just-superseded period — harmless bookkeeping, the
--     user got a fresh allowance anyway. A top-up INSERT racing this call may
--     be visible to the spend loop but not the sum — also harmless (more
--     availability than counted; we still spend exactly p_credits).
--   * now() is transaction-stable, so the expiry filter is consistent between
--     the availability sum and the spend loop.
--
-- The status gate (active|past_due) and "latest period, not now()-covered
-- period" semantics are inherited verbatim from the 1-arg version — see the
-- §9.1 rationale on consume_credit(uuid) in 20260601120000_billing_schema.sql.
-- =============================================================================
create or replace function public.consume_credit(
  p_subscription_id uuid,
  p_credits         integer
)
returns integer
language plpgsql
-- Pinned search_path (advisor 0011): safe because every relation reference in
-- the body is schema-qualified. The pre-existing billing functions predate this
-- convention; hardening them is a separate migration.
set search_path = ''
as $$
declare
  v_period_id   uuid;
  v_limit       integer;
  v_used        integer;
  v_plan_avail  integer;
  v_topup_avail integer;
  v_plan_spend  integer;
  v_needed      integer;
  v_spend       integer;
  r             record;
begin
  -- A zero/negative/null spend is a caller bug; spend nothing.
  if p_credits is null or p_credits <= 0 then
    return null;
  end if;

  -- Per-subscription mutex: lock the latest period row (see header).
  select up.id, s.credits_limit, up.credits_used
    into v_period_id, v_limit, v_used
  from public.usage_periods up
  join public.subscriptions s on s.id = up.subscription_id
  where up.subscription_id = p_subscription_id
    and s.status in ('active', 'past_due')
  order by up.period_start desc
  limit 1
  for update of up;

  if v_period_id is null then
    return null;  -- no spendable subscription/period (cancelled, expired, none)
  end if;

  v_plan_avail := greatest(0, v_limit - v_used);

  -- Lock spendable top-up rows in FIFO order and sum their availability.
  -- (FOR UPDATE sits inside the subquery because it can't accompany an
  -- aggregate directly.)
  select coalesce(sum(t.credits_total - t.credits_used), 0)
    into v_topup_avail
  from (
    select tc.credits_total, tc.credits_used
    from public.topup_credits tc
    where tc.subscription_id = p_subscription_id
      and tc.expires_at > now()
      and tc.credits_used < tc.credits_total
    order by tc.expires_at asc, tc.id asc
    for update
  ) t;

  -- ALL-OR-NOTHING: if the combined balance can't cover the charge, spend
  -- nothing. (The Phase 4 handler surfaces this NULL as 402 out_of_credits →
  -- the app's top-up prompt.)
  if v_plan_avail + v_topup_avail < p_credits then
    return null;
  end if;

  -- Spend order is a product invariant (plan first, then top-ups): plan
  -- credits expire at reset, top-ups live 12 months — drain the perishable
  -- bucket first.
  v_plan_spend := least(p_credits, v_plan_avail);
  if v_plan_spend > 0 then
    update public.usage_periods
    set credits_used = credits_used + v_plan_spend
    where id = v_period_id;
  end if;

  -- Remainder from top-ups, nearest expiry first. Rows are already locked.
  v_needed := p_credits - v_plan_spend;
  if v_needed > 0 then
    for r in
      select tc.id, tc.credits_total - tc.credits_used as avail
      from public.topup_credits tc
      where tc.subscription_id = p_subscription_id
        and tc.expires_at > now()
        and tc.credits_used < tc.credits_total
      order by tc.expires_at asc, tc.id asc
      for update
    loop
      exit when v_needed <= 0;
      v_spend := least(r.avail, v_needed);
      update public.topup_credits
      set credits_used = credits_used + v_spend
      where id = r.id;
      v_needed := v_needed - v_spend;
    end loop;
  end if;

  -- Combined remaining balance after this spend.
  return (v_plan_avail + v_topup_avail) - p_credits;
end;
$$;

comment on function public.consume_credit(uuid, integer) is
  'Atomically spend p_credits: plan period first, then non-expired top-ups FIFO by expiry. All-or-nothing — returns combined remaining (plan + top-up), or NULL with nothing spent if the combined balance is insufficient. Period-row lock = per-subscription mutex.';

-- =============================================================================
-- 5. consume_trial_credit(uuid, integer) — variable spend for trial grants.
-- =============================================================================
-- Trials have a single bucket (no top-ups), so this stays the same shape as the
-- 1-arg original: ONE conditional UPDATE whose gate
-- (trial_credits_used + p_credits <= trial_credits_limit) is evaluated under
-- the grant row's lock — all-or-nothing falls out of the single-statement form,
-- and two concurrent "last credits" calls serialize with exactly one winning.
-- =============================================================================
create or replace function public.consume_trial_credit(
  p_grant_id uuid,
  p_credits  integer
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_remaining integer;
begin
  if p_credits is null or p_credits <= 0 then
    return null;
  end if;

  update public.trial_grants tg
  set trial_credits_used = tg.trial_credits_used + p_credits
  where tg.id = p_grant_id
    and tg.verified_at is not null
    and tg.trial_credits_used + p_credits <= tg.trial_credits_limit
  returning tg.trial_credits_limit - tg.trial_credits_used into v_remaining;

  -- NULL when no row updated: insufficient remaining, unverified, or no grant.
  return v_remaining;
end;
$$;

comment on function public.consume_trial_credit(uuid, integer) is
  'Atomically spend p_credits from a trial grant (single bucket). All-or-nothing: returns credits remaining, or NULL with nothing spent if the grant can''t cover it. Single conditional UPDATE = double-spend guard.';

-- =============================================================================
-- Grants — service_role only (RLS bypass still requires table privileges; see
-- *_billing_grants.sql). Overloads are distinct functions in Postgres: the
-- existing grants on the (uuid) signatures do NOT cover (uuid, integer).
-- =============================================================================
grant select, insert, update, delete on public.topup_credits to service_role;

grant execute on function public.consume_credit(uuid, integer)       to service_role;
grant execute on function public.consume_trial_credit(uuid, integer) to service_role;
