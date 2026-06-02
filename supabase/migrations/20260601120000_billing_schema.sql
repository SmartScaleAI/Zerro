-- =============================================================================
-- Zerro billing — schema (Phase D1)
-- =============================================================================
-- The server-side mirror of subscription state. LemonSqueezy is the system of
-- record for who paid; this Postgres schema is a fast local mirror kept current
-- by LemonSqueezy webhooks so the runtime (the D2 `generate` proxy) can
-- authorize a generation without calling LemonSqueezy on every request.
--
-- Authoritative design: Documents/zerro-billing-plan.md §6.2 (components),
-- §9 / §9.1 (lifecycle / past-due), §14 (security).
--
-- Conventions:
--   * Tier identifiers ('starter','pro') match the Swift `ManagedTier` enum
--     (Zerro/Services/Billing/EntitlementState.swift) so the mirror and the app
--     speak the same vocabulary.
--   * We store a SHA-256 HASH of the license key, NEVER the raw key (§14.3).
--   * RLS is enabled in the companion migration *_billing_rls.sql and is
--     deny-by-default; only the service role (inside Edge Functions) touches
--     these tables.
-- =============================================================================

-- gen_random_uuid() lives in pgcrypto. Supabase ships it; ensure it's present.
create extension if not exists pgcrypto;

-- Keep updated_at honest on mutable rows.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- subscriptions — one row per LemonSqueezy subscription (the stable identity).
-- -----------------------------------------------------------------------------
create table public.subscriptions (
  id                  uuid primary key default gen_random_uuid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  -- LemonSqueezy linkage.
  ls_subscription_id  text not null unique,
  ls_customer_id      text,
  ls_order_id         text,            -- used to attach the license key, which
                                       -- LS delivers via a SEPARATE
                                       -- `license_key_created` event (see the
                                       -- webhook function + pending_license_keys).

  -- Credential: a SHA-256 hash (hex) of the license key. Never the raw key.
  -- Nullable because `subscription_created` may arrive before
  -- `license_key_created`; the webhook backfills it. Unique so a key maps to at
  -- most one subscription (multiple NULLs are allowed by Postgres).
  license_key_hash    text unique,

  tier                text not null check (tier in ('starter','pro')),
  status              text not null check (status in ('active','past_due','cancelled','expired')),

  -- The credit-reset anchor (LemonSqueezy `renews_at`). Display + reset bookkeeping.
  current_period_end  timestamptz,

  -- Denormalized from tier so the per-tier allowance can be tuned without a
  -- code change; the credit-remaining math reads this column.
  credits_limit       integer not null check (credits_limit >= 0),

  -- The LemonSqueezy-side last-update time of the event we last applied. Used to
  -- drop stale / out-of-order webhook deliveries (only apply newer events).
  ls_updated_at       timestamptz
);

create index subscriptions_ls_customer_id_idx on public.subscriptions (ls_customer_id);
create index subscriptions_ls_order_id_idx    on public.subscriptions (ls_order_id);
-- license_key_hash already has a unique index from the UNIQUE constraint.

create trigger subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

comment on table public.subscriptions is
  'Local mirror of LemonSqueezy subscriptions. License keys stored only as a SHA-256 hash.';

-- -----------------------------------------------------------------------------
-- usage_periods — the credit ledger. One row per billing period; credits_used
-- is incremented atomically by consume_credit() (called by the D2 proxy).
-- -----------------------------------------------------------------------------
create table public.usage_periods (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  period_start    timestamptz not null,
  period_end      timestamptz not null,
  credits_used    integer not null default 0 check (credits_used >= 0),
  created_at      timestamptz not null default now(),

  -- A renewal must not be able to double-open a period for the same start.
  -- This is the idempotency guard for `subscription_payment_success`.
  unique (subscription_id, period_start)
);

create index usage_periods_subscription_id_idx on public.usage_periods (subscription_id);

comment on table public.usage_periods is
  'Per-period credit ledger. The (subscription_id, period_start) unique key stops a redelivered renewal from rolling a second period.';

-- -----------------------------------------------------------------------------
-- trial_grants — server-funded, email-keyed trial credits. Created now so the
-- schema is whole; written/enforced in D2 / Phase F.
-- -----------------------------------------------------------------------------
create table public.trial_grants (
  id                   uuid primary key default gen_random_uuid(),
  email_normalized     text not null unique,   -- one grant per verified email
  verified_at          timestamptz,
  trial_credits_limit  integer not null check (trial_credits_limit >= 0),
  trial_credits_used   integer not null default 0 check (trial_credits_used >= 0),
  created_at           timestamptz not null default now()
);

comment on table public.trial_grants is
  'Email-keyed trial allowance (Phase F). UNIQUE email defeats reinstall farming.';

-- -----------------------------------------------------------------------------
-- webhook_events — idempotency ledger. A fresh INSERT means "not yet processed".
-- -----------------------------------------------------------------------------
create table public.webhook_events (
  ls_event_id   text primary key,         -- see webhook fn: the X-Signature digest
  event_name    text not null,
  processed_at  timestamptz not null default now()
);

comment on table public.webhook_events is
  'Idempotency ledger. ls_event_id = the per-payload X-Signature HMAC (LemonSqueezy ships no stable event id); an exact redelivery shares it.';

-- -----------------------------------------------------------------------------
-- pending_license_keys — reconciliation buffer for LemonSqueezy''s SEPARATE
-- `license_key_created` event. LS does NOT include the license key in the
-- subscription payload; it arrives in its own event, possibly BEFORE the
-- matching `subscription_created`. When that happens we stash the hash keyed by
-- order id and adopt it once the subscription row appears.
-- -----------------------------------------------------------------------------
create table public.pending_license_keys (
  ls_order_id       text primary key,
  license_key_hash  text not null,
  ls_customer_id    text,
  created_at        timestamptz not null default now()
);

comment on table public.pending_license_keys is
  'Holds a license_key_hash whose subscription_created has not arrived yet (out-of-order webhooks). Drained on subscription_created.';

-- -----------------------------------------------------------------------------
-- generation_log — cost / abuse analytics. NEVER user content (§14.5).
-- Written by the D2 proxy; created now so the schema is whole.
-- -----------------------------------------------------------------------------
create table public.generation_log (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid references public.subscriptions(id) on delete set null,
  created_at      timestamptz not null default now(),
  tokens_in       integer,
  tokens_out      integer,
  est_cost_usd    numeric(10,6),
  success         boolean not null
);

create index generation_log_subscription_id_idx on public.generation_log (subscription_id);
create index generation_log_created_at_idx       on public.generation_log (created_at);

comment on table public.generation_log is
  'Token counts + cost only. Never transcript, audio, or frames (§14.5).';

-- -----------------------------------------------------------------------------
-- rate_limits — durable fixed-window counter backing the basic limiter on
-- `session` (and future `generate`/`trial-start`). Documented as the v1 basic
-- control; Phase G tightens it (sliding window / dedicated store + cleanup).
-- -----------------------------------------------------------------------------
create table public.rate_limits (
  key           text not null,         -- bucket, e.g. 'session:keyhash:<hash>' or 'session:ip:<ip>'
  window_start  timestamptz not null,  -- floor(now / window) — the fixed window anchor
  count         integer not null default 0,
  primary key (key, window_start)
);

create index rate_limits_window_start_idx on public.rate_limits (window_start);

comment on table public.rate_limits is
  'Basic durable fixed-window rate limiter (Phase D1). Phase G replaces with a tighter scheme + window cleanup.';

-- =============================================================================
-- consume_credit — the atomic credit-usage primitive used by the D2 proxy.
-- =============================================================================
-- Spends exactly one credit against a subscription's CURRENT period and returns
-- the credits remaining afterwards, or NULL if no credit could be spent
-- (at limit, or no spendable subscription/period).
--
-- ATOMICITY / DOUBLE-SPEND GUARD: this is a SINGLE conditional UPDATE. The
-- `credits_used < credits_limit` predicate is evaluated under a row-level lock
-- on the matched usage_periods row. Two concurrent calls at "1 credit left"
-- serialize on that lock; after the first commits (credits_used = limit), the
-- second re-checks the predicate (Postgres EvalPlanQual under READ COMMITTED),
-- finds it false, updates zero rows, and returns NULL. Exactly one succeeds.
--
-- "CURRENT period" = the subscription's LATEST usage_period (greatest
-- period_start), NOT "the period whose [start,end) covers now()". This is a
-- deliberate refinement of the §6.2 sketch to honor §9.1: a `past_due`
-- subscriber keeps spending the *remaining* credits of the last paid period
-- even though now() may already be past that period's end (no fresh allowance
-- is granted until a `subscription_payment_success` rolls a new period). Gating
-- on now()<period_end would zero a past-due user out the instant renewal fails,
-- which §9.1 explicitly forbids. The spend gate is therefore: status in
-- (active|past_due) AND credits_used < credits_limit on the latest period.
-- =============================================================================
create or replace function public.consume_credit(p_subscription_id uuid)
returns integer
language plpgsql
as $$
declare
  v_remaining integer;
begin
  update public.usage_periods up
  set credits_used = up.credits_used + 1
  from public.subscriptions s
  where up.id = (
          select up2.id
          from public.usage_periods up2
          where up2.subscription_id = p_subscription_id
          order by up2.period_start desc
          limit 1
        )
    and s.id = up.subscription_id
    and s.status in ('active', 'past_due')
    and up.credits_used < s.credits_limit
  returning s.credits_limit - up.credits_used into v_remaining;

  -- v_remaining is NULL when no row was updated: at limit, cancelled/expired,
  -- or no period exists. The caller MUST treat NULL as "no credit spent".
  return v_remaining;
end;
$$;

comment on function public.consume_credit(uuid) is
  'Atomically spend 1 credit on the subscription''s latest period; returns credits remaining, or NULL if none could be spent. Single conditional UPDATE = double-spend guard.';

-- =============================================================================
-- check_rate_limit — atomic fixed-window counter. Returns TRUE if the call is
-- within the limit for the current window, FALSE if it exceeds it.
-- =============================================================================
create or replace function public.check_rate_limit(
  p_key            text,
  p_max            integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
as $$
declare
  v_window timestamptz;
  v_count  integer;
begin
  -- Anchor to the start of the current fixed window.
  v_window := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds
  );

  insert into public.rate_limits (key, window_start, count)
  values (p_key, v_window, 1)
  on conflict (key, window_start)
    do update set count = public.rate_limits.count + 1
  returning count into v_count;

  return v_count <= p_max;
end;
$$;

comment on function public.check_rate_limit(text, integer, integer) is
  'Atomic fixed-window rate limiter. TRUE if within p_max for the current p_window_seconds window.';
