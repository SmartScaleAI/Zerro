-- =============================================================================
-- Anonymous BYOK trial: ten successful generations, one trial kind per Mac.
-- =============================================================================
-- The Mac sends only its existing client-hashed device id. Prompt content,
-- recordings, transcripts, provider choices, and API keys never enter this
-- ledger. `trial_device_claims` is shared with the email-funded trial so a
-- device can claim exactly one free-trial kind, even under concurrent requests.

create table public.trial_device_claims (
  device_id_hash text primary key
    check (device_id_hash ~ '^[0-9a-f]{64}$'),
  trial_kind text not null
    check (trial_kind in ('managed', 'byok')),
  claimed_at timestamptz not null default now()
);

comment on table public.trial_device_claims is
  'One free-trial kind per client-hashed Mac. Contains no email or generation content.';

insert into public.trial_device_claims (device_id_hash, trial_kind, claimed_at)
select tg.device_id_hash, 'managed', coalesce(tg.verified_at, now())
from public.trial_grants tg
where tg.device_id_hash is not null
on conflict (device_id_hash) do nothing;

create table public.byok_trial_grants (
  id uuid primary key default gen_random_uuid(),
  device_id_hash text not null unique
    references public.trial_device_claims(device_id_hash) on delete restrict,
  generations_limit integer not null default 10
    check (generations_limit > 0),
  generations_used integer not null default 0
    check (generations_used >= 0 and generations_used <= generations_limit),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.byok_trial_grants is
  'Anonymous BYOK trial allowance. Generations run directly with user-owned provider keys.';

create table public.byok_trial_usage_events (
  grant_id uuid not null
    references public.byok_trial_grants(id) on delete cascade,
  generation_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (grant_id, generation_id)
);

comment on table public.byok_trial_usage_events is
  'Idempotency ledger for successful BYOK trial recording sessions. Stores identifiers only.';

create index byok_trial_usage_events_created_at_idx
  on public.byok_trial_usage_events (created_at);

alter table public.trial_device_claims enable row level security;
alter table public.trial_device_claims force row level security;
alter table public.byok_trial_grants enable row level security;
alter table public.byok_trial_grants force row level security;
alter table public.byok_trial_usage_events enable row level security;
alter table public.byok_trial_usage_events force row level security;
-- Intentionally no policies: these ledgers are Edge-Function/service-role only.

grant select, insert, update, delete on
  public.trial_device_claims,
  public.byok_trial_grants,
  public.byok_trial_usage_events
to service_role;

revoke all on
  public.trial_device_claims,
  public.byok_trial_grants,
  public.byok_trial_usage_events
from anon, authenticated;

-- Read-only eligibility/resume lookup. The Edge Function shapes the public
-- response and rate-limits callers; this RPC is service-role only.
create or replace function public.check_byok_trial_eligibility(
  p_device_id_hash text
)
returns table(
  status text,
  grant_id uuid,
  generations_remaining integer
)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_kind text;
  v_grant_id uuid;
  v_limit integer;
  v_used integer;
begin
  if p_device_id_hash is null
     or p_device_id_hash !~ '^[0-9a-f]{64}$' then
    status := 'invalid_device';
    grant_id := null;
    generations_remaining := 0;
    return next;
    return;
  end if;

  select c.trial_kind
    into v_kind
    from public.trial_device_claims c
   where c.device_id_hash = p_device_id_hash;

  if v_kind is null then
    status := 'eligible';
    grant_id := null;
    generations_remaining := 10;
    return next;
    return;
  end if;

  if v_kind <> 'byok' then
    status := 'managed_trial_used';
    grant_id := null;
    generations_remaining := 0;
    return next;
    return;
  end if;

  select g.id, g.generations_limit, g.generations_used
    into v_grant_id, v_limit, v_used
    from public.byok_trial_grants g
   where g.device_id_hash = p_device_id_hash;

  if v_grant_id is null then
    -- Defensive repair signal: a BYOK claim and grant are created atomically.
    status := 'server_error';
    grant_id := null;
    generations_remaining := 0;
    return next;
    return;
  end if;

  status := case when v_used >= v_limit then 'exhausted' else 'active' end;
  grant_id := v_grant_id;
  generations_remaining := greatest(0, v_limit - v_used);
  return next;
end;
$$;

-- Atomically claim the BYOK trial on its first successful generation and record
-- exactly one use per recording id. The advisory lock shares the device hash
-- with verify_trial_grant below, closing the email-vs-BYOK first-claim race.
create or replace function public.consume_byok_trial_generation(
  p_device_id_hash text,
  p_generation_id uuid,
  p_limit integer default 10
)
returns table(
  status text,
  grant_id uuid,
  generations_remaining integer,
  counted boolean
)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_kind text;
  v_grant_id uuid;
  v_limit integer;
  v_used integer;
begin
  if p_device_id_hash is null
     or p_device_id_hash !~ '^[0-9a-f]{64}$'
     or p_generation_id is null
     or p_limit <= 0 then
    status := 'invalid_request';
    grant_id := null;
    generations_remaining := 0;
    counted := false;
    return next;
    return;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_device_id_hash, 0)
  );

  insert into public.trial_device_claims (device_id_hash, trial_kind)
  values (p_device_id_hash, 'byok')
  on conflict (device_id_hash) do nothing;

  select c.trial_kind
    into v_kind
    from public.trial_device_claims c
   where c.device_id_hash = p_device_id_hash;

  if v_kind <> 'byok' then
    status := 'managed_trial_used';
    grant_id := null;
    generations_remaining := 0;
    counted := false;
    return next;
    return;
  end if;

  insert into public.byok_trial_grants
    (device_id_hash, generations_limit, generations_used)
  values (p_device_id_hash, p_limit, 0)
  on conflict (device_id_hash) do nothing;

  select g.id, g.generations_limit, g.generations_used
    into v_grant_id, v_limit, v_used
    from public.byok_trial_grants g
   where g.device_id_hash = p_device_id_hash
   for update;

  if exists (
    select 1
      from public.byok_trial_usage_events e
     where e.grant_id = v_grant_id
       and e.generation_id = p_generation_id
  ) then
    status := case when v_used >= v_limit then 'exhausted' else 'active' end;
    grant_id := v_grant_id;
    generations_remaining := greatest(0, v_limit - v_used);
    counted := false;
    return next;
    return;
  end if;

  if v_used >= v_limit then
    status := 'exhausted';
    grant_id := v_grant_id;
    generations_remaining := 0;
    counted := false;
    return next;
    return;
  end if;

  insert into public.byok_trial_usage_events (grant_id, generation_id)
  values (v_grant_id, p_generation_id);

  update public.byok_trial_grants g
     set generations_used = g.generations_used + 1,
         updated_at = now()
   where g.id = v_grant_id
  returning g.generations_limit, g.generations_used
       into v_limit, v_used;

  status := case when v_used >= v_limit then 'exhausted' else 'active' end;
  grant_id := v_grant_id;
  generations_remaining := greatest(0, v_limit - v_used);
  counted := true;
  return next;
end;
$$;

-- Replace the existing email-trial writer so it participates in the shared
-- per-device claim. Its signature and sentinel behavior remain compatible with
-- the deployed trial-start function and older app builds.
create or replace function public.verify_trial_grant(
  p_email text,
  p_limit integer,
  p_device_id_hash text default null
)
returns table(grant_id uuid, credits_remaining integer)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_id uuid;
  v_used integer;
  v_limit integer;
  v_kind text;
begin
  if p_device_id_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(p_device_id_hash, 0)
    );

    insert into public.trial_device_claims (device_id_hash, trial_kind)
    values (p_device_id_hash, 'managed')
    on conflict (device_id_hash) do nothing;

    select c.trial_kind
      into v_kind
      from public.trial_device_claims c
     where c.device_id_hash = p_device_id_hash;

    if v_kind <> 'managed' then
      grant_id := null;
      credits_remaining := 0;
      return next;
      return;
    end if;

    perform 1
      from public.trial_grants tg
     where tg.device_id_hash = p_device_id_hash
       and tg.email_normalized <> p_email;
    if found then
      grant_id := null;
      credits_remaining := 0;
      return next;
      return;
    end if;
  end if;

  begin
    insert into public.trial_grants
      (email_normalized, verified_at, trial_credits_limit, trial_credits_used, device_id_hash)
    values (p_email, now(), p_limit, 0, p_device_id_hash)
    on conflict (email_normalized) do update
      set verified_at = coalesce(public.trial_grants.verified_at, now()),
          device_id_hash = coalesce(public.trial_grants.device_id_hash, excluded.device_id_hash)
    returning id, trial_credits_used, trial_credits_limit
      into v_id, v_used, v_limit;
  exception when unique_violation then
    grant_id := null;
    credits_remaining := 0;
    return next;
    return;
  end;

  grant_id := v_id;
  credits_remaining := greatest(0, v_limit - v_used);
  return next;
end;
$$;

revoke all on function public.check_byok_trial_eligibility(text)
  from public, anon, authenticated;
revoke all on function public.consume_byok_trial_generation(text, uuid, integer)
  from public, anon, authenticated;
revoke all on function public.verify_trial_grant(text, integer, text)
  from public, anon, authenticated;

grant execute on function public.check_byok_trial_eligibility(text)
  to service_role;
grant execute on function public.consume_byok_trial_generation(text, uuid, integer)
  to service_role;
grant execute on function public.verify_trial_grant(text, integer, text)
  to service_role;
