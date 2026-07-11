-- =============================================================================
-- X-02 — Dev-Mode combined billing via deposit-and-settle (authorization hold).
-- =============================================================================
-- Dev Mode is TWO calls sharing one recording: call 1 (`dev_transcribe`) is a
-- Whisper transcription that used to be entirely free/unmetered (X-01 reverted
-- the trial metering on that leg), and call 2 (the normal generate) meters the
-- REAL combined STT+chat cost. The gap: call 1 with no call 2 is free, bounded
-- only by the rate limit + the audio byte cap + the global spend cap.
--
-- This migration adds the payments-standard fix: an AUTHORIZATION HOLD.
--   * call 1 places a temporary hold (default 1 credit — the same floor the
--     paired generation is gated on) keyed by the recording's Idempotency-Key;
--   * call 2 SETTLES: consumes the real metered cost AND releases the hold in
--     ONE transaction;
--   * every affordability gate now checks the SPENDABLE balance
--     (real credits − SUM(active, unexpired holds)), so a held credit can never
--     be double-spent by a concurrent generation;
--   * an abandoned hold (call 1, no call 2) expires after a short TTL — a
--     pg_cron sweep prunes the rows, and the active-holds SUM already ignores
--     expired rows, so correctness never depends on the sweep's cadence.
--
-- A HOLD IS NEVER A CHARGE. Money moves ONLY through the existing consume_*
-- family; a hold is a reservation row that reduces the spendable figure while
-- it is active. That is what makes the failure modes safe by construction:
-- an orphaned hold self-releases at TTL (the user "gets their credit back"
-- automatically), and settle can never double-charge because the hold never
-- charged anything — settle consumes the real cost exactly once.
--
-- ATOMICITY / LOCK ORDER. hold_credit and settle_credit_hold respect the SAME
-- global lock order every spender uses (20260622130000_overspend_allow_negative):
--     trial_grants(grant) → usage_periods(latest period) → topup_credits(FIFO)
-- hold_credit acquires the account row lock(s) FIRST, then touches its
-- credit_holds row — and settle_credit_hold does the same by running the
-- consume (which takes the account locks) BEFORE deleting the hold row. Both
-- therefore order (account rows) → (hold row); the sweep and release take only
-- the hold row. No path takes the locks in the opposite order → deadlock-free
-- with each other and with the whole consume_* family.
--
-- OWNERSHIP. Each hold is owned by exactly ONE identity column — subscription_id
-- for a subscription token (including a converted user, whose combined trial
-- remainder still participates in the SPENDABLE math via the function args),
-- trial_grant_id for a trial token — enforced by a CHECK. The functions verify
-- the owner on every idempotent-replay / settle / release so one user's key can
-- never touch another's hold (the key is the PK; a cross-account collision on a
-- client-minted UUID is adversarial, and fails closed with an exception).
--
-- Conventions: append-only migration; RLS deny-by-default with NO policies +
-- explicit service_role table grants (billing_grants rationale); functions are
-- SECURITY INVOKER with a pinned empty search_path (advisor 0011) and explicit
-- service_role EXECUTE grants; pg_cron sweep mirrors A-14's prune jobs.
-- =============================================================================

-- =============================================================================
-- 1. The holds table.
-- =============================================================================
create table public.credit_holds (
  -- The client-minted per-recording Idempotency-Key (one per recording, reused
  -- across retries AND across the recording's call 1 + call 2 — that shared key
  -- is what lets call 2 find and settle call 1's hold).
  idempotency_key text primary key,
  -- Exactly ONE owner column is set (CHECK below). ON DELETE CASCADE: a deleted
  -- account must never leave a dangling reservation against nothing.
  subscription_id uuid references public.subscriptions(id) on delete cascade,
  trial_grant_id  uuid references public.trial_grants(id)  on delete cascade,
  -- The reserved amount. Always ≥ 1 (a zero/negative hold is a caller bug).
  credits_held    integer     not null check (credits_held > 0),
  -- The client-DECLARED audio seconds at hold time (observability only — the
  -- true measured duration isn't known until Whisper returns; the hold amount
  -- is a flat floor regardless).
  measured_seconds numeric,
  created_at      timestamptz not null default now(),
  -- Past this instant the hold no longer reduces the spendable balance (the
  -- active-holds SUM filters on it) and the sweep deletes the row.
  expires_at      timestamptz not null,
  constraint credit_holds_one_owner
    check ((subscription_id is null) <> (trial_grant_id is null))
);

comment on table public.credit_holds is
  'X-02 deposit-and-settle: temporary authorization holds placed by the Dev Mode dev_transcribe call (call 1) and released by the paired generation''s settle (call 2) or by TTL expiry. A hold is a RESERVATION, never a charge — it reduces the spendable balance (real credits − active holds) while active; money moves only through the consume_* family. Keyed by the client''s per-recording Idempotency-Key; owned by exactly one of subscription_id / trial_grant_id. Service-role only.';

-- The sweep's driving index (prune by expiry) — also serves the active-holds
-- SUM's expires_at filter as a secondary condition.
create index credit_holds_expires_at_idx on public.credit_holds (expires_at);
-- The active-holds SUM per account (one of these is null on every row, so two
-- partial-ish plain indexes beat one composite).
create index credit_holds_subscription_id_idx on public.credit_holds (subscription_id)
  where subscription_id is not null;
create index credit_holds_trial_grant_id_idx on public.credit_holds (trial_grant_id)
  where trial_grant_id is not null;

-- RLS deny-by-default, matching every other billing table (*_billing_rls.sql):
-- enabled + forced, INTENTIONALLY NO POLICIES. Only the service role (inside
-- the generate Edge Function) ever touches it.
alter table public.credit_holds enable row level security;
alter table public.credit_holds force  row level security;

-- Service-role table grants — required explicitly: this project's default ACL
-- gives service_role no DML on postgres-created tables (C-10 lesson).
grant select, insert, update, delete on public.credit_holds to service_role;

-- =============================================================================
-- 2. active_hold_credits — the spendable-balance subtrahend (invariant 2).
-- =============================================================================
-- SUM of active (unexpired) held credits for an account, excluding p_exclude_key.
-- The exclusion is what lets a request settle ITS OWN hold: the call-2 floor
-- gate excludes the recording's key, so the credit call 1 reserved is spendable
-- by the settle it was reserved FOR — while every OTHER request still sees it
-- as unavailable. Pass p_exclude_key = null to count everything (e.g. display).
--
-- READ-ONLY and deliberately lock-free: the gates it feeds are advisory
-- (check-then-consume); the hard guards remain hold_credit's locked insert and
-- the consume_* row locks.
--
-- CONVERSION LINK: a combined account's hold is OWNED by the subscription, but
-- its spendable math included the linked grant's trial remainder — so a
-- grant-side query (a converted user's still-live trial token, or a sibling
-- subscription sharing the grant) must see subscription-owned holds of every
-- subscription LINKED to that grant, or the reservation would be bypassable
-- from the trial side. Deliberately over-conservative in the rare
-- multi-sub-per-grant shape (a sibling's plan-funded hold also counts against
-- the grant): undercounting spendable is the fail-SAFE direction.
-- =============================================================================
create or replace function public.active_hold_credits(
  p_subscription_id uuid,
  p_trial_grant_id  uuid,
  p_exclude_key     text
)
returns integer
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(ch.credits_held), 0)::integer
  from public.credit_holds ch
  where ch.expires_at > now()
    and (p_exclude_key is null or ch.idempotency_key <> p_exclude_key)
    and (
      (p_subscription_id is not null and ch.subscription_id = p_subscription_id)
      or
      (p_trial_grant_id is not null and (
        ch.trial_grant_id = p_trial_grant_id
        or ch.subscription_id in (
          select s.id from public.subscriptions s where s.trial_grant_id = p_trial_grant_id
        )
      ))
    );
$$;

comment on function public.active_hold_credits(uuid, uuid, text) is
  'X-02: SUM of active (unexpired) credit_holds for an account (either/both id columns), excluding p_exclude_key so a request can settle its own hold. Spendable balance = real credits − this. Read-only; the locked hold_credit insert and the consume_* row locks remain the hard guards.';

grant execute on function public.active_hold_credits(uuid, uuid, text) to service_role;

-- =============================================================================
-- 3. hold_credit — place (or idempotently refresh) the call-1 hold.
-- =============================================================================
-- Returns 'held' | 'insufficient'.
--   * A hold already existing for p_key AND the same owner → 'held' (idempotent
--     no-op for a call-1 retry; the TTL is refreshed — the client is clearly
--     still working on the recording — but NO second reservation is created).
--   * Enough SPENDABLE balance (real − other active holds) → insert → 'held'.
--   * Otherwise → 'insufficient' (the handler maps it to out_of_credits and
--     never calls Whisper).
--   * Invalid arguments or a cross-account key collision RAISE (fail closed —
--     the handler refuses on any thrown error; it never proceeds unheld).
--
-- ATOMIC AGAINST CONCURRENT HOLDS/SPENDS: the account row lock(s) are taken
-- FIRST (grant → period, the global order), so two concurrent hold_credit
-- calls for one account serialize, and a hold can't interleave with an
-- in-flight consume_* for the same account. The spendable computation and the
-- insert happen entirely under that lock — two "last spendable credit" holds
-- can never both pass.
--
-- COMBINED ACCOUNTS: a converted subscriber passes BOTH ids. The hold row is
-- OWNED by the subscription (one owner column), but the verified grant's trial
-- remainder participates in the spendable figure — exactly mirroring how the
-- generate handler's combined creditsRemaining() and consume_combined_credit
-- see that account's balance. A missing/unverified grant contributes 0 and the
-- subscription side alone decides (same posture as the handler's combined
-- probe).
-- =============================================================================
create or replace function public.hold_credit(
  p_key              text,
  p_subscription_id  uuid,
  p_trial_grant_id   uuid,
  p_credits          integer,
  p_ttl_seconds      integer,
  p_measured_seconds numeric default null
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_owner_sub    uuid;
  v_owner_grant  uuid;
  v_existing     record;
  v_trial_avail  integer := 0;
  v_period_id    uuid;
  v_limit        integer;
  v_used         integer;
  v_plan_avail   integer := 0;
  v_topup_avail  integer := 0;
  v_holds        integer := 0;
begin
  -- Caller-bug guards: fail CLOSED (raise → the handler refuses), never a
  -- silent free pass and never a bogus reservation.
  if p_key is null or length(trim(p_key)) = 0 then
    raise exception 'hold_credit: p_key is required';
  end if;
  if p_credits is null or p_credits <= 0 then
    raise exception 'hold_credit: p_credits must be positive';
  end if;
  if p_ttl_seconds is null or p_ttl_seconds <= 0 then
    raise exception 'hold_credit: p_ttl_seconds must be positive';
  end if;
  if p_subscription_id is null and p_trial_grant_id is null then
    raise exception 'hold_credit: an account id is required';
  end if;

  -- The hold's single OWNER column: the subscription when present (a converted
  -- user holds against the subscription identity; the grant id below only
  -- feeds the combined spendable math), else the trial grant.
  if p_subscription_id is not null then
    v_owner_sub := p_subscription_id;
  else
    v_owner_grant := p_trial_grant_id;
  end if;

  -- LOCK 1 (lowest in the global order): the trial grant row, if provided and
  -- verified. Missing/unverified → contributes 0 to a COMBINED account (the
  -- subscription side alone decides, mirroring the handler's combined probe),
  -- and is outright non-spendable for a PURE-trial hold.
  if p_trial_grant_id is not null then
    select greatest(0, tg.trial_credits_limit - tg.trial_credits_used)
      into v_trial_avail
    from public.trial_grants tg
    where tg.id = p_trial_grant_id
      and tg.verified_at is not null
    for update;
    if not found then
      if p_subscription_id is null then
        return 'insufficient';
      end if;
      v_trial_avail := 0;
    end if;
  end if;

  -- LOCK 2: the subscription's latest usage_period = the per-subscription
  -- mutex (identical row + predicate to the consume_* family).
  if p_subscription_id is not null then
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
      -- Non-spendable subscription/period: nothing to reserve against.
      return 'insufficient';
    end if;
    v_plan_avail := greatest(0, v_limit - v_used);

    -- Non-expired top-up availability. Read-only (no FOR UPDATE): every writer
    -- of these rows (the consume_* family) holds the period lock first, which
    -- we hold — so the read can't interleave with a spend on this account.
    select coalesce(sum(tc.credits_total - tc.credits_used), 0)
      into v_topup_avail
    from public.topup_credits tc
    where tc.subscription_id = p_subscription_id
      and tc.expires_at > now()
      and tc.credits_used < tc.credits_total;
  end if;

  -- Idempotent replay — checked UNDER the account lock, so a concurrent
  -- same-key call serializes and then sees this row. Owner must match: the
  -- same client retrying gets 'held'; another account colliding on the key
  -- fails closed.
  select ch.subscription_id, ch.trial_grant_id
    into v_existing
  from public.credit_holds ch
  where ch.idempotency_key = p_key;

  if found then
    if v_existing.subscription_id is not distinct from v_owner_sub
       and v_existing.trial_grant_id is not distinct from v_owner_grant then
      -- Refresh the TTL (the client is still driving this recording); never a
      -- second reservation.
      update public.credit_holds
      set expires_at = now() + make_interval(secs => p_ttl_seconds)
      where idempotency_key = p_key;
      return 'held';
    end if;
    raise exception 'hold_credit: key is held by another account';
  end if;

  -- SPENDABLE gate: real availability minus every OTHER active hold on this
  -- account. (p_key is excluded defensively; a row for it would have returned
  -- above.)
  v_holds := public.active_hold_credits(p_subscription_id, p_trial_grant_id, p_key);
  if (v_trial_avail + v_plan_avail + v_topup_avail) - v_holds < p_credits then
    return 'insufficient';
  end if;

  insert into public.credit_holds
    (idempotency_key, subscription_id, trial_grant_id, credits_held, measured_seconds, expires_at)
  values
    (p_key, v_owner_sub, v_owner_grant, p_credits, p_measured_seconds,
     now() + make_interval(secs => p_ttl_seconds));
  return 'held';
end;
$$;

comment on function public.hold_credit(text, uuid, uuid, integer, integer, numeric) is
  'X-02 call-1 authorization hold: reserves p_credits for p_key iff the account''s SPENDABLE balance (real − other active holds) covers it, under the account row lock(s) in the global order grant→period so concurrent holds/spends serialize. Idempotent per key (retry → ''held'', TTL refreshed, no second reservation); cross-account key collision raises (fail closed). Returns ''held'' | ''insufficient''. A hold is a reservation, never a charge.';

grant execute on function public.hold_credit(text, uuid, uuid, integer, integer, numeric) to service_role;

-- =============================================================================
-- 4. settle_credit_hold — call 2: consume the REAL cost + release the hold,
--    in ONE transaction.
-- =============================================================================
-- Dispatches to the SAME consume path the normal generation uses (no forked
-- spend logic):
--   both ids       → consume_combined_credit_overspend  (converted user)
--   subscription   → consume_credit_overspend
--   trial grant    → consume_trial_credit_overspend
-- then deletes the hold row for p_key (owner-matched). Because this is one
-- function = one transaction, the charge and the release commit or roll back
-- TOGETHER: never both the hold and a separate charge surviving (the hold
-- never charged anything), never a consumed-but-still-held credit.
--
-- Lock order: the consume runs FIRST and takes the account locks in the global
-- order (grant → period → top-ups); only then is the hold row touched — the
-- same (account rows) → (hold row) order hold_credit uses, so the two can
-- never deadlock against each other.
--
-- No hold row for p_key (a plain non-dev generation, an already-expired-and-
-- swept hold, or a defensive call-2-without-call-1) → the consume still runs
-- normally and 'hold_released' reports false. NULL is returned ONLY when the
-- consume itself reports a non-spendable account (its own NULL contract) —
-- in that case NOTHING was spent and the hold is left untouched (it will
-- TTL-expire; the handler refuses the result).
--
-- Returns jsonb: { remaining, hold_released } for the single-ledger paths;
-- { remaining, trial_spent, plan_spent, topup_spent, hold_released } for the
-- combined path. `remaining` may be NEGATIVE (the overspend contract).
-- =============================================================================
create or replace function public.settle_credit_hold(
  p_key             text,
  p_subscription_id uuid,
  p_trial_grant_id  uuid,
  p_credits         integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_result   jsonb;
  v_int      integer;
  v_released integer := 0;
begin
  -- Mirror the consume_* posture: a zero/negative/null spend is a caller bug;
  -- spend nothing, release nothing.
  if p_credits is null or p_credits <= 0 then
    return null;
  end if;
  if p_subscription_id is null and p_trial_grant_id is null then
    return null;
  end if;

  -- 1. Consume the REAL metered cost via the exact spender the account class
  --    already uses (locks taken inside, in the global order).
  if p_subscription_id is not null and p_trial_grant_id is not null then
    v_result := public.consume_combined_credit_overspend(p_trial_grant_id, p_subscription_id, p_credits);
    if v_result is null then
      return null; -- non-spendable: nothing consumed, hold left to TTL
    end if;
  elsif p_subscription_id is not null then
    v_int := public.consume_credit_overspend(p_subscription_id, p_credits);
    if v_int is null then
      return null;
    end if;
    v_result := jsonb_build_object('remaining', v_int);
  else
    v_int := public.consume_trial_credit_overspend(p_trial_grant_id, p_credits);
    if v_int is null then
      return null;
    end if;
    v_result := jsonb_build_object('remaining', v_int);
  end if;

  -- 2. Release the hold — same transaction as the consume above, owner-matched
  --    so a foreign hold under a colliding key is never touched. Expired-but-
  --    unswept rows are deleted too (settling IS the cleanup). The third arm is
  --    the CONVERSION edge: a hold placed by the user's pre-conversion TRIAL
  --    identity (grant-owned) whose call 2 arrives on the subscription token
  --    with the grant since exhausted (the handler then passes no grant id) is
  --    still owner-matched through the subscription's conversion link, so it
  --    settles instead of stranding until TTL. Safe: a grant-owned hold can
  --    only have been placed by that grant's own trial identity — the same
  --    user this subscription converted from.
  delete from public.credit_holds ch
  where ch.idempotency_key = p_key
    and (
      (p_subscription_id is not null and ch.subscription_id = p_subscription_id)
      or
      (p_trial_grant_id is not null and ch.trial_grant_id = p_trial_grant_id)
      or
      (p_subscription_id is not null and ch.trial_grant_id is not null
        and ch.trial_grant_id = (
          select s.trial_grant_id from public.subscriptions s where s.id = p_subscription_id
        ))
    );
  get diagnostics v_released = row_count;

  return v_result || jsonb_build_object('hold_released', v_released > 0);
end;
$$;

comment on function public.settle_credit_hold(text, uuid, uuid, integer) is
  'X-02 call-2 settle: consumes the REAL metered p_credits via the account''s existing consume_*_overspend spender AND deletes the p_key hold (owner-matched) in ONE transaction — the charge and the release commit or roll back together. No hold row → consumes normally (hold_released=false). Returns the consume result as jsonb + hold_released, or NULL only when the consume reports a non-spendable account (nothing spent, hold left to TTL). Lock order: account rows (via the consume) then the hold row — deadlock-free vs hold_credit.';

grant execute on function public.settle_credit_hold(text, uuid, uuid, integer) to service_role;

-- =============================================================================
-- 5. release_credit_hold — drop an un-settled hold early (call-1 transcription
--    failure: a failed Whisper must not tie the credit up for the TTL).
-- =============================================================================
-- Owner-matched delete; true iff a row was released. Takes ONLY the hold row
-- lock (no account locks), so it composes with everything above. Best-effort
-- at the call site: if it fails, the TTL expiry is the backstop.
-- =============================================================================
create or replace function public.release_credit_hold(
  p_key             text,
  p_subscription_id uuid,
  p_trial_grant_id  uuid
)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_released integer := 0;
begin
  if p_key is null then
    return false;
  end if;
  delete from public.credit_holds ch
  where ch.idempotency_key = p_key
    and (
      (p_subscription_id is not null and ch.subscription_id = p_subscription_id)
      or
      (p_trial_grant_id is not null and ch.trial_grant_id = p_trial_grant_id)
    );
  get diagnostics v_released = row_count;
  return v_released > 0;
end;
$$;

comment on function public.release_credit_hold(text, uuid, uuid) is
  'X-02: early-release an un-settled hold (owner-matched delete) — used when call 1''s transcription fails so the reservation doesn''t outlive the failure. TTL expiry is the backstop when this isn''t reached.';

grant execute on function public.release_credit_hold(text, uuid, uuid) to service_role;

-- =============================================================================
-- 6. Orphan sweep — prune expired holds (invariant 6's hygiene half).
-- =============================================================================
-- CORRECTNESS DOES NOT DEPEND ON THIS JOB: active_hold_credits filters
-- `expires_at > now()`, so an expired row already frees the balance the
-- instant it expires. The sweep just keeps the table from accumulating
-- abandoned rows. Every 10 minutes (the TTL is minutes, unlike the daily
-- A-14 ledgers), index-driven via credit_holds_expires_at_idx. Pure SQL, no
-- secrets — safe to schedule straight from the migration; cron.schedule
-- UPSERTS by name so a re-apply is a no-op.
-- =============================================================================
create extension if not exists pg_cron;

select cron.schedule(
  'credit-holds-prune',
  '*/10 * * * *',
  $$ delete from public.credit_holds where expires_at < now(); $$
);
