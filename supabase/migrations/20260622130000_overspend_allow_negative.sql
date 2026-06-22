-- =============================================================================
-- Zerro billing — overspend-capable consume RPCs (allow one final uncapped
-- generation into the negative).
-- =============================================================================
-- Fixes the "free generation on a low balance" money-safety bug. The all-or-
-- nothing consume_credit / consume_combined_credit / consume_trial_credit return
-- NULL (spending NOTHING) whenever the real metered cost exceeds the balance, so
-- the /generate handler returned the prompt UNCHARGED and the user could repeat
-- indefinitely. Product decision: a user with any spendable balance (>= 1 credit)
-- may run exactly ONE generation of any cost; it is charged IN FULL and the
-- balance goes NEGATIVE; every further generation is then blocked (the handler's
-- `remaining < 1` floor gate) until the monthly period renews or a top-up is
-- bought.
--
-- WHY NEW FUNCTIONS (not editing the existing ones): per the repo's money-safety
-- convention (see 20260609120000_multi_model_credits.sql and
-- 20260619130000_trial_subscription_link.sql) the semantics of the deployed
-- consume_* functions must never shift under live callers. These overspend
-- variants are near-copies that ADD the negative-balance behavior; the handler's
-- store layer (supabase/functions/generate/store.ts) repoints to them. Postgres
-- treats them as distinct functions, so each needs its OWN service_role EXECUTE
-- grant — the existing grants do NOT cover them.
--
-- WHAT CHANGES vs the all-or-nothing siblings (everything else is byte-identical):
--   * The early `if <combined avail> < p_credits then return null` gate is GONE:
--     these overloads ALWAYS spend p_credits in full.
--   * The funded portion drains REAL availability in the existing product order
--     (combined: trial → plan period → top-ups FIFO; single: plan → top-ups
--     FIFO). Any UNFUNDED remainder overflows onto the latest
--     usage_periods.credits_used (subscription paths) or trial_grants
--     .trial_credits_used (pure-trial path). Those columns have only a `>= 0`
--     CHECK (no upper bound), so they may exceed their limit → the balance goes
--     negative. The overflow NEVER lands on a topup_credits row, which carries a
--     `credits_used <= credits_total` CHECK; top-ups are spent only up to their
--     real availability.
--   * The return value is the TRUE remaining (possibly NEGATIVE):
--     single/trial return integer; combined returns the same jsonb shape
--     { remaining, trial_spent, plan_spent, topup_spent } with `remaining`
--     possibly < 0 and trial_spent + plan_spent + topup_spent = p_credits (the
--     overspend remainder is folded into plan_spent).
--   * NULL survives for ONE case only: a genuinely NON-spendable account — no
--     spendable usage_periods row for an active/past_due subscription, or a
--     missing/unverified trial grant. The handler treats that NULL strictly as
--     out_of_credits (it never returns an uncharged prompt).
--
-- ATOMICITY / DEADLOCK: unchanged from the siblings. ONE function = ONE
-- transaction; the SAME total lock order is respected
--   trial_grants(grant) → usage_periods(latest period) → topup_credits(FIFO)
-- so these compose deadlock-free with consume_credit / consume_trial_credit /
-- consume_combined_credit and with each other. `set search_path = ''` (every
-- relation schema-qualified), the `p_credits <= 0` guard, the FOR UPDATE lock
-- acquisition order, and now()-transaction-stability are all preserved. There is
-- no all-or-nothing affordability window to reason about because there is no
-- early gate; the per-identity concurrency cap (=1) in the handler still bounds a
-- single overspend to one in-flight generation.
--
-- Conventions: append-only migration; RLS deny-by-default inherited (no new
-- table); explicit service_role EXECUTE grant per new overload. Mirrors
-- 20260609120000_multi_model_credits.sql / 20260619130000_trial_subscription_link.sql.
-- =============================================================================

-- =============================================================================
-- 1. consume_credit_overspend(uuid, integer) — single-identity overspend.
-- =============================================================================
-- The overspend twin of consume_credit(uuid, integer): plan period first, then
-- non-expired top-ups FIFO, then any remainder overflows onto the plan period.
-- Returns the combined remaining (plan + non-expired top-up) AFTER the spend,
-- possibly NEGATIVE; NULL only when there is no spendable subscription/period.
-- =============================================================================
create or replace function public.consume_credit_overspend(
  p_subscription_id uuid,
  p_credits         integer
)
returns integer
language plpgsql
-- Pinned search_path (advisor 0011): safe because every relation reference in
-- the body is schema-qualified. Mirrors consume_credit(uuid, integer).
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

  -- Per-subscription mutex: lock the latest period row (identical to consume_credit).
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
    return null;  -- non-spendable subscription/period (the only surviving NULL)
  end if;

  v_plan_avail := greatest(0, v_limit - v_used);

  -- Lock spendable top-up rows in FIFO order and sum their availability.
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

  -- NO all-or-nothing gate (the one line that distinguishes this from
  -- consume_credit): this overload ALWAYS spends p_credits in full.

  -- Spend order is the product invariant: plan period first, then top-ups FIFO.
  v_plan_spend := least(p_credits, v_plan_avail);
  if v_plan_spend > 0 then
    update public.usage_periods
    set credits_used = credits_used + v_plan_spend
    where id = v_period_id;
  end if;

  v_needed := p_credits - v_plan_spend;

  -- Top-ups, nearest expiry first — each spent ONLY up to its real availability
  -- (least(avail, needed)), so credits_used <= credits_total always holds. The
  -- overspend remainder must never land on a top-up row.
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

  -- OVERSPEND OVERFLOW: any remainder the buckets couldn't fund lands on the
  -- plan period. usage_periods.credits_used has only a `>= 0` CHECK (no upper
  -- bound), so it may exceed credits_limit — this is what drives the balance
  -- negative. Never a top-up row (its `<= credits_total` CHECK).
  if v_needed > 0 then
    update public.usage_periods
    set credits_used = credits_used + v_needed
    where id = v_period_id;
  end if;

  -- True combined remaining after the spend — may be NEGATIVE.
  return (v_plan_avail + v_topup_avail) - p_credits;
end;
$$;

comment on function public.consume_credit_overspend(uuid, integer) is
  'Overspend twin of consume_credit: ALWAYS spends p_credits (plan first, then non-expired top-ups FIFO, remainder overflowing onto the plan period so the balance can go negative). Returns combined remaining after the spend (possibly negative), or NULL only for a non-spendable subscription/period. Top-up rows are never overspent (their <= credits_total CHECK). Period-row lock = per-subscription mutex; lock order identical to consume_credit.';

-- =============================================================================
-- 2. consume_combined_credit_overspend(uuid, uuid, integer) — cross-ledger.
-- =============================================================================
-- The overspend twin of consume_combined_credit: trial remainder first, then
-- plan period, then top-ups FIFO, then any remainder overflows onto the plan
-- period. Returns jsonb { remaining, trial_spent, plan_spent, topup_spent } with
-- `remaining` possibly NEGATIVE (and trial_spent + plan_spent + topup_spent =
-- p_credits, the overflow folded into plan_spent), or NULL only for a
-- non-spendable subscription.
-- =============================================================================
create or replace function public.consume_combined_credit_overspend(
  p_grant_id        uuid,
  p_subscription_id uuid,
  p_credits         integer
)
returns jsonb
language plpgsql
-- Pinned search_path; mirrors consume_combined_credit(uuid, uuid, integer).
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
  if p_credits is null or p_credits <= 0 then
    return null;
  end if;

  -- LOCK 1 (lowest in the total order): the trial grant row, if verified.
  if p_grant_id is not null then
    select greatest(0, tg.trial_credits_limit - tg.trial_credits_used)
      into v_trial_avail
    from public.trial_grants tg
    where tg.id = p_grant_id
      and tg.verified_at is not null
    for update;
  end if;
  v_trial_avail := coalesce(v_trial_avail, 0);

  -- LOCK 2: the subscription's latest usage_period = per-subscription mutex.
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
    return null;  -- non-spendable subscription (the only surviving NULL)
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

  -- NO all-or-nothing gate: ALWAYS spends p_credits in full, in the product
  -- order trial → plan period → top-ups FIFO, remainder overflowing onto plan.

  -- Trial bucket first (perishable, promotional).
  v_trial_spend := least(p_credits, v_trial_avail);
  if v_trial_spend > 0 then
    update public.trial_grants
    set trial_credits_used = trial_credits_used + v_trial_spend
    where id = p_grant_id;
  end if;

  v_needed := p_credits - v_trial_spend;

  -- Plan period next.
  v_plan_spend := least(v_needed, v_plan_avail);
  if v_plan_spend > 0 then
    update public.usage_periods
    set credits_used = credits_used + v_plan_spend
    where id = v_period_id;
  end if;

  v_needed := v_needed - v_plan_spend;

  -- Top-ups FIFO — each spent ONLY up to its real availability (never overspent).
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

  -- OVERSPEND OVERFLOW onto the plan period (never trial or top-up rows). Folded
  -- into plan_spent so trial_spent + plan_spent + topup_spent = p_credits.
  if v_needed > 0 then
    update public.usage_periods
    set credits_used = credits_used + v_needed
    where id = v_period_id;
    v_plan_spend := v_plan_spend + v_needed;
    v_needed := 0;
  end if;

  return jsonb_build_object(
    'remaining',   (v_trial_avail + v_plan_avail + v_topup_avail) - p_credits,
    'trial_spent', v_trial_spend,
    'plan_spent',  v_plan_spend,
    'topup_spent', v_topup_spend
  );
end;
$$;

comment on function public.consume_combined_credit_overspend(uuid, uuid, integer) is
  'Overspend twin of consume_combined_credit: ALWAYS spends p_credits across a trial grant + subscription (trial remainder first, then plan period, then non-expired top-ups FIFO, remainder overflowing onto the plan period so the combined balance can go negative). Returns jsonb {remaining (possibly negative), trial_spent, plan_spent, topup_spent} (sum = p_credits), or NULL only for a non-spendable subscription. Lock order grant→period→top-ups (deadlock-free vs the all-or-nothing consume_* family).';

-- =============================================================================
-- 3. consume_trial_credit_overspend(uuid, integer) — pure-trial overspend.
-- =============================================================================
-- The overspend twin of consume_trial_credit: a single conditional UPDATE that
-- ALWAYS adds the full charge to the grant's trial_credits_used (no
-- `<= trial_credits_limit` gate). trial_credits_used has only a `>= 0` CHECK, so
-- it may exceed the limit → remaining goes negative. Returns the remaining
-- (possibly negative), or NULL only when no verified grant row matches.
-- =============================================================================
create or replace function public.consume_trial_credit_overspend(
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

  -- No `<= trial_credits_limit` gate (the one difference from
  -- consume_trial_credit): the single trial bucket ALWAYS absorbs the full
  -- charge. The conditional UPDATE locks the grant row, so two concurrent "last
  -- credits" calls still serialize. NULL only when no verified grant matched.
  update public.trial_grants tg
  set trial_credits_used = tg.trial_credits_used + p_credits
  where tg.id = p_grant_id
    and tg.verified_at is not null
  returning tg.trial_credits_limit - tg.trial_credits_used into v_remaining;

  return v_remaining;
end;
$$;

comment on function public.consume_trial_credit_overspend(uuid, integer) is
  'Overspend twin of consume_trial_credit (single bucket): ALWAYS spends p_credits, putting the full charge on trial_credits_used (no <= limit gate) so remaining may go negative. Returns remaining after (possibly negative), or NULL only for a missing/unverified grant. Single conditional UPDATE = double-spend guard.';

-- =============================================================================
-- Grants — service_role only. These overloads are distinct functions in
-- Postgres: existing grants on the all-or-nothing signatures do NOT cover them.
-- =============================================================================
grant execute on function public.consume_credit_overspend(uuid, integer)               to service_role;
grant execute on function public.consume_combined_credit_overspend(uuid, uuid, integer) to service_role;
grant execute on function public.consume_trial_credit_overspend(uuid, integer)          to service_role;
