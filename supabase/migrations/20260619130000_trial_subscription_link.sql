-- =============================================================================
-- Zerro billing — trial↔subscription link + cross-ledger combined spend
-- =============================================================================
-- Fixes the "stranded trial credits" bug: when a trial user converts to a paid
-- subscription, the subscription-token spend path (consume_credit) never touches
-- trial_grants, so any leftover trial credits sit unspent forever AND every
-- generation bills the full metered cost to the paid plan. This migration lets a
-- single /generate request spend the trial remainder FIRST, then bill only the
-- difference to plan + top-ups — atomically, in one transaction.
--
-- Two parts:
--   1. subscriptions.trial_grant_id — a nullable FK to the trial_grants row a
--      converting user came from. Set ONCE, at conversion, by the
--      lemonsqueezy-webhook (preferring an explicit checkout custom_data id,
--      falling back to an aggressive-email-normalization match). A best-effort
--      one-time backfill links already-converted subscriptions here.
--      Deliberately NOT unique: one person may hold several subscriptions but
--      only ever one trial grant, so many subs → one grant is legal.
--   2. consume_combined_credit(uuid, uuid, integer) — a NEW function (the
--      existing consume_credit / consume_trial_credit signatures are left
--      untouched, per the money-safety rule that their semantics never shift
--      under deployed callers). Atomic, all-or-nothing across BOTH ledgers.
--
-- WHY A SINGLE NEW RPC (not two orchestrated from the handler): two RPCs = two
-- transactions = a window where the trial spend commits but the plan spend fails
-- (or vice-versa), leaving a partial cross-ledger charge. One function = one
-- transaction = no such window.
--
-- ATOMICITY / DEADLOCK ARGUMENT (the money-safety heart):
--   * ONE function = ONE transaction; nothing observes state between check and
--     spend.
--   * TOTAL LOCK ORDER, respected by every multi-row spender:
--         trial_grants(grant) → usage_periods(latest period) → topup_credits(FIFO)
--     - consume_trial_credit locks only the grant (a prefix of the order).
--     - consume_credit locks period → top-ups (a suffix; never the grant).
--     - consume_combined_credit locks grant → period → top-ups (the full order).
--     For any two transactions, the locks they BOTH take are acquired in the same
--     relative order, so no lock cycle — hence no deadlock. The grant lock is
--     held only by the combined function and by consume_trial_credit (which takes
--     nothing else), so it can never be the second edge of a cycle.
--   * The combined-availability gate (trial + plan + top-up >= p_credits) runs
--     BEFORE any UPDATE: an insufficient balance returns NULL having taken locks
--     but written nothing — no partial charge, nothing to roll back.
--   * Under READ COMMITTED a caller that blocked on the grant or period lock
--     re-reads the newly committed row (EvalPlanQual), so its availability math
--     starts from fresh *_used values — the lost-update race cannot happen. This
--     is what makes the cross-token race safe: if a racing trial-token spend
--     drained the grant between this caller's affordability read (in the handler)
--     and this consume, the combined function simply spends LESS from trial and
--     MORE from plan, still all-or-nothing, never double-spending the grant.
--   * now() is transaction-stable, so the top-up expiry filter is consistent
--     between the availability sum and the spend loop.
--
-- Conventions: append-only migration; RLS deny-by-default is inherited (no new
-- table); explicit service_role EXECUTE grant on the new overload (Postgres
-- treats it as a distinct function — existing grants do NOT cover it). Mirrors
-- 20260609120000_multi_model_credits.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. subscriptions.trial_grant_id — the explicit conversion link.
-- -----------------------------------------------------------------------------
-- ON DELETE SET NULL: a trial_grants row is only ever removed by a per-customer
-- privacy delete; if that happens, the subscription simply loses its (already
-- exhausted-or-irrelevant) trial link rather than cascading the paid sub away.
alter table public.subscriptions
  add column if not exists trial_grant_id uuid
    references public.trial_grants(id) on delete set null;

create index if not exists subscriptions_trial_grant_id_idx
  on public.subscriptions (trial_grant_id)
  where trial_grant_id is not null;

comment on column public.subscriptions.trial_grant_id is
  'The trial_grants row this subscriber converted from, or NULL. Set once at conversion by the lemonsqueezy-webhook (custom_data.trial_grant_id, else aggressive-email-normalization match). Lets /generate drain the trial remainder before billing the paid plan (consume_combined_credit). Non-unique: many subs may map to one grant.';

-- -----------------------------------------------------------------------------
-- 2. One-time backfill — link already-converted subscriptions.
-- -----------------------------------------------------------------------------
-- trial_grants.email_normalized is AGGRESSIVELY normalized (Gmail dots/+tags
-- collapsed to defeat farming); subscriptions.email_normalized is only
-- lowercased + trimmed. So we apply the SAME aggressive transform to the sub's
-- email here and match against the grant. Best-effort: only verified grants, and
-- only subs not already linked. Anything that doesn't match stays NULL and is
-- handled live by the webhook on the next subscription event.
with norm as (
  select
    s.id as sub_id,
    case
      when split_part(lower(trim(s.email_normalized)), '@', 2) in ('gmail.com', 'googlemail.com')
        then replace(
               split_part(split_part(lower(trim(s.email_normalized)), '@', 1), '+', 1),
               '.', ''
             ) || '@gmail.com'
      else
        split_part(split_part(lower(trim(s.email_normalized)), '@', 1), '+', 1)
        || '@' || split_part(lower(trim(s.email_normalized)), '@', 2)
    end as norm_email
  from public.subscriptions s
  where s.email_normalized is not null
    and s.email_normalized <> ''
    and s.trial_grant_id is null
)
update public.subscriptions s
set trial_grant_id = tg.id
from norm
join public.trial_grants tg
  on tg.email_normalized = norm.norm_email
 and tg.verified_at is not null
where s.id = norm.sub_id;

-- =============================================================================
-- 3. consume_combined_credit(uuid, uuid, integer) — cross-ledger atomic spend.
-- =============================================================================
-- Spends p_credits across the trial grant + the subscription, in the product
-- order trial → plan period → top-ups (FIFO by expiry). Returns a jsonb object
--   { remaining, trial_spent, plan_spent, topup_spent }
-- (remaining = COMBINED balance after the spend) or NULL with NOTHING spent if
-- the combined balance can't cover p_credits.
--
-- p_grant_id may be NULL — the function then behaves like consume_credit (pure
-- subscription spend) — but the handler only routes here when a linked, verified
-- grant with remainder actually exists, so the trial leg normally contributes.
-- =============================================================================
create or replace function public.consume_combined_credit(
  p_grant_id        uuid,
  p_subscription_id uuid,
  p_credits         integer
)
returns jsonb
language plpgsql
-- Pinned search_path (advisor 0011): every relation reference below is
-- schema-qualified, so '' is safe. Mirrors consume_credit(uuid, integer).
set search_path = ''
as $$
declare
  v_trial_avail integer;
  v_period_id   uuid;
  v_limit       integer;
  v_used        integer;
  v_plan_avail  integer;
  v_topup_avail integer;
  v_trial_spend integer := 0;
  v_plan_spend  integer := 0;
  v_topup_spend integer := 0;
  v_needed      integer;
  v_spend       integer;
  r             record;
begin
  -- A zero/negative/null spend is a caller bug; spend nothing.
  if p_credits is null or p_credits <= 0 then
    return null;
  end if;

  -- LOCK 1 (lowest in the total order): the trial grant row, if any. Only a
  -- VERIFIED grant contributes. SELECT … INTO leaves v_trial_avail NULL when no
  -- row matches (missing/unverified grant), so coalesce to 0.
  if p_grant_id is not null then
    select greatest(0, tg.trial_credits_limit - tg.trial_credits_used)
      into v_trial_avail
    from public.trial_grants tg
    where tg.id = p_grant_id
      and tg.verified_at is not null
    for update;
  end if;
  v_trial_avail := coalesce(v_trial_avail, 0);

  -- LOCK 2: the subscription's LATEST usage_period = the per-subscription mutex
  -- (identical to consume_credit). A non-spendable subscription (cancelled /
  -- expired / no period) returns NULL — the handler reaches here only for a
  -- subscription identity, so "no period" means not-entitled.
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
    return null;
  end if;

  v_plan_avail := greatest(0, v_limit - v_used);

  -- LOCK 3: spendable top-up rows in FIFO order; sum their availability.
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

  -- ALL-OR-NOTHING across BOTH ledgers: if the combined balance can't cover the
  -- charge, spend nothing (handler surfaces NULL as 402 out_of_credits).
  if v_trial_avail + v_plan_avail + v_topup_avail < p_credits then
    return null;
  end if;

  -- Spend order (product invariant): the perishable, promotional trial bucket
  -- FIRST, then the monthly plan period, then 12-month top-ups FIFO.
  v_trial_spend := least(p_credits, v_trial_avail);
  if v_trial_spend > 0 then
    update public.trial_grants
    set trial_credits_used = trial_credits_used + v_trial_spend
    where id = p_grant_id;
  end if;

  v_needed := p_credits - v_trial_spend;

  v_plan_spend := least(v_needed, v_plan_avail);
  if v_plan_spend > 0 then
    update public.usage_periods
    set credits_used = credits_used + v_plan_spend
    where id = v_period_id;
  end if;

  v_needed := v_needed - v_plan_spend;
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
      v_topup_spend := v_topup_spend + v_spend;
      v_needed := v_needed - v_spend;
    end loop;
  end if;

  return jsonb_build_object(
    'remaining',   (v_trial_avail + v_plan_avail + v_topup_avail) - p_credits,
    'trial_spent', v_trial_spend,
    'plan_spent',  v_plan_spend,
    'topup_spent', v_topup_spend
  );
end;
$$;

comment on function public.consume_combined_credit(uuid, uuid, integer) is
  'Atomically spend p_credits across a trial grant + subscription: trial remainder first, then plan period, then non-expired top-ups FIFO. All-or-nothing across both ledgers — returns jsonb {remaining, trial_spent, plan_spent, topup_spent}, or NULL with nothing spent if the combined balance is insufficient. Lock order grant→period→top-ups (deadlock-free vs consume_credit / consume_trial_credit).';

-- =============================================================================
-- Grant — service_role only (RLS bypass still requires the EXECUTE privilege;
-- this overload is a distinct function, so existing grants do NOT cover it).
-- =============================================================================
grant execute on function public.consume_combined_credit(uuid, uuid, integer) to service_role;
