-- =============================================================================
-- Zerro billing — server-funded trial credits (Phase F)
-- =============================================================================
-- Layer 2 of the two-layer trial (§3.3): the local 7-day clock (Phase B) gates
-- reaching the area selector; this layer authorizes the actual server-funded
-- generation. A trial user with no OpenAI key of their own verifies an EMAIL
-- (6-digit code) once and receives a capped grant of server-funded credits
-- (default 15). Their generations then route through the SAME D2 `generate`
-- proxy, decrementing the trial grant instead of a subscription period.
--
-- ABUSE BOUNDING (§14.2 / §14.7): the cap is keyed to the VERIFIED EMAIL
-- (`trial_grants.email_normalized` UNIQUE — created in D1), NOT a local/install
-- id. Delete + reinstall resets the local clock but NOT the email-keyed grant,
-- so credits can't be farmed by reinstalling. `verify_trial_grant` is the single
-- writer and never resets an existing grant's credits.
--
-- The `trial_grants` table itself already exists (D1 schema migration). This
-- migration adds the Phase F machinery:
--   * trial_codes            — short-lived, HASHED 6-digit verification codes.
--   * verify_trial_grant()   — atomic "create-once / never-reset" grant upsert.
--   * consume_trial_credit() — the atomic single-credit spend (mirrors
--                              consume_credit; the double-spend guard).
--   * trial_generation_slots — per-grant concurrency cap of 1 (mirrors
--                              generation_slots), which makes the proxy's
--                              check-then-consume-on-success ordering safe for
--                              the trial path exactly as it does for subscriptions.
--
-- Same conventions as the rest of the billing schema: RLS deny-by-default
-- (service-role-only), explicit table + EXECUTE grants, never store a secret raw
-- (the code is SHA-256 hashed like the license key).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- trial_codes — pending email-verification codes. One row per normalized email
-- (the PK), overwritten on a re-request. The code is stored ONLY as a SHA-256
-- hash (hex) — never plaintext, mirroring how license keys are stored. Short
-- TTL (`expires_at`) + an `attempts` counter bound brute force.
-- -----------------------------------------------------------------------------
create table public.trial_codes (
  email_normalized text primary key,        -- canonicalized email (one pending code each)
  code_hash        text not null,           -- SHA-256(code) — never the raw code
  expires_at       timestamptz not null,    -- short TTL (default 10 min, set by the function)
  attempts         integer not null default 0 check (attempts >= 0),
  created_at       timestamptz not null default now()
);

create index trial_codes_expires_at_idx on public.trial_codes (expires_at);

comment on table public.trial_codes is
  'Pending email-verification codes (Phase F). One row per email; code stored only as a SHA-256 hash with a short TTL + attempt counter. Drained on successful verify.';

-- -----------------------------------------------------------------------------
-- trial_generation_slots — the trial-path twin of generation_slots: at most one
-- in-flight generation per trial grant. This concurrency cap is what makes the
-- proxy's CHECK-THEN-CONSUME-ON-SUCCESS credit ordering safe for trial credits
-- (a single grant can't have two generations both passing the availability
-- check and both paying OpenAI before either consumes). See the generation_slots
-- migration header for the full rationale (table-not-counter, stale reclaim).
-- -----------------------------------------------------------------------------
create table public.trial_generation_slots (
  grant_id    uuid primary key references public.trial_grants(id) on delete cascade,
  acquired_at timestamptz not null default now()
);

comment on table public.trial_generation_slots is
  'In-flight generation marker per trial grant = concurrency cap 1 (Phase F). Stale rows reclaimed by acquire_trial_slot. Service-role only.';

-- =============================================================================
-- RLS — deny-by-default on the two new tables, matching every other billing
-- table. Only the service role (inside the Edge Functions) ever touches them.
-- =============================================================================
alter table public.trial_codes enable row level security;
alter table public.trial_codes force  row level security;
-- INTENTIONALLY NO POLICIES. Deny-by-default is the design.

alter table public.trial_generation_slots enable row level security;
alter table public.trial_generation_slots force  row level security;
-- INTENTIONALLY NO POLICIES.

-- =============================================================================
-- verify_trial_grant — the SINGLE writer of trial_grants on a successful code
-- verification. Creates the grant the FIRST time an email verifies (with the
-- env-configured credit limit) and is a NO-OP on the credit ledger for an email
-- that already has a grant — it only backfills verified_at if somehow unset. It
-- NEVER resets trial_credits_used, so re-verifying (e.g. after a reinstall lost
-- the in-memory token) resumes the SAME remaining balance rather than handing
-- out a fresh allowance. Returns the grant id + credits remaining so the caller
-- can mint a trial session token and tell the app how many credits are left.
--
-- ATOMICITY: a single INSERT … ON CONFLICT under the email_normalized unique
-- index, so two concurrent verifications of the same email can't double-grant.
-- =============================================================================
create or replace function public.verify_trial_grant(
  p_email text,
  p_limit integer
)
returns table(grant_id uuid, credits_remaining integer)
language plpgsql
as $$
declare
  v_id    uuid;
  v_used  integer;
  v_limit integer;
begin
  insert into public.trial_grants (email_normalized, verified_at, trial_credits_limit, trial_credits_used)
  values (p_email, now(), p_limit, 0)
  on conflict (email_normalized) do update
    -- Touch ONLY verified_at (and only if it was somehow null). Do NOT reset
    -- the limit or used count — one grant per email, ever.
    set verified_at = coalesce(public.trial_grants.verified_at, now())
  returning id, trial_credits_used, trial_credits_limit
    into v_id, v_used, v_limit;

  grant_id := v_id;
  credits_remaining := greatest(0, v_limit - v_used);
  return next;
end;
$$;

comment on function public.verify_trial_grant(text, integer) is
  'Create-once / never-reset trial grant upsert keyed on email_normalized. Returns (grant_id, credits_remaining). The only writer that establishes a grant.';

-- =============================================================================
-- consume_trial_credit — atomically spend one trial credit against a grant and
-- return the credits remaining afterward, or NULL if none could be spent (at
-- limit, or grant missing/unverified). Mirrors consume_credit exactly: a SINGLE
-- conditional UPDATE whose `trial_credits_used < trial_credits_limit` predicate
-- is evaluated under the grant row's lock, so two concurrent "last credit" calls
-- serialize and exactly one succeeds — the double-spend guard.
-- =============================================================================
create or replace function public.consume_trial_credit(p_grant_id uuid)
returns integer
language plpgsql
as $$
declare
  v_remaining integer;
begin
  update public.trial_grants tg
  set trial_credits_used = tg.trial_credits_used + 1
  where tg.id = p_grant_id
    and tg.verified_at is not null
    and tg.trial_credits_used < tg.trial_credits_limit
  returning tg.trial_credits_limit - tg.trial_credits_used into v_remaining;

  -- NULL when no row was updated: at limit, unverified, or no such grant. The
  -- caller MUST treat NULL as "no credit spent".
  return v_remaining;
end;
$$;

comment on function public.consume_trial_credit(uuid) is
  'Atomically spend 1 trial credit on a grant; returns credits remaining, or NULL if none could be spent. Single conditional UPDATE = double-spend guard.';

-- =============================================================================
-- acquire_trial_slot / release_trial_slot — the trial twins of
-- acquire_generation_slot / release_generation_slot. Identical semantics
-- (atomic INSERT … ON CONFLICT with stale reclaim; idempotent release), keyed on
-- grant_id instead of subscription_id. See the generation_slots migration for
-- the line-by-line atomicity argument.
-- =============================================================================
create or replace function public.acquire_trial_slot(
  p_grant_id      uuid,
  p_stale_seconds integer
)
returns boolean
language plpgsql
as $$
declare
  v_acquired boolean;
begin
  insert into public.trial_generation_slots (grant_id, acquired_at)
  values (p_grant_id, now())
  on conflict (grant_id) do update
    set acquired_at = now()
    where public.trial_generation_slots.acquired_at
            < now() - make_interval(secs => p_stale_seconds)
  returning true into v_acquired;

  return coalesce(v_acquired, false);
end;
$$;

comment on function public.acquire_trial_slot(uuid, integer) is
  'Atomically claim the single in-flight generation slot for a trial grant (reclaiming a slot older than p_stale_seconds). TRUE = acquired, FALSE = busy.';

create or replace function public.release_trial_slot(p_grant_id uuid)
returns void
language plpgsql
as $$
begin
  delete from public.trial_generation_slots where grant_id = p_grant_id;
end;
$$;

comment on function public.release_trial_slot(uuid) is
  'Release a trial grant''s in-flight generation slot. Idempotent.';

-- =============================================================================
-- Grants — service_role only (RLS bypass still needs table-level privileges;
-- see *_billing_grants.sql for the rationale). anon/authenticated get NOTHING.
-- =============================================================================
grant select, insert, update, delete on
  public.trial_codes,
  public.trial_generation_slots
to service_role;

grant execute on function public.verify_trial_grant(text, integer)   to service_role;
grant execute on function public.consume_trial_credit(uuid)          to service_role;
grant execute on function public.acquire_trial_slot(uuid, integer)   to service_role;
grant execute on function public.release_trial_slot(uuid)            to service_role;
