-- =============================================================================
-- Zerro billing — trial device binding (trial-abuse hardening)
-- =============================================================================
-- Closes the "different emails, same Mac" trial-farming hole. Until now a trial
-- was a pool of server-funded credits keyed ONLY to a verified email
-- (`trial_grants.email_normalized` UNIQUE). A real person on one Mac could
-- create a genuinely different real address, verify it, and collect another
-- grant indefinitely — every farmed grant is server-funded OpenAI spend.
--
-- The fix: bind each grant to ONE physical Mac, identified by a CLIENT-HASHED
-- hardware UUID (SHA-256(platformUUID + app salt)). The raw UUID never leaves
-- the device; the DB only ever holds `device_id_hash`. A second grant from a
-- device that already trialed is HARD-BLOCKED regardless of which email is
-- presented. The email cap, disposable block, and rate limits stay as a second
-- layer — a new grant now needs BOTH a new email AND a new physical machine.
--
-- This migration:
--   * adds trial_grants.device_id_hash (nullable — old rows and rare
--     unreadable-UUID clients stay NULL and fall back to the email-only cap),
--   * adds a PARTIAL unique index so the one-grant-per-device cap is race-safe
--     at the DB level while many NULLs never collide,
--   * replaces verify_trial_grant with a device-aware version that is the single
--     atomic enforcement point.
--
-- Pre-launch note: trial_grants holds only test data, so no backfill is needed.
-- =============================================================================

alter table public.trial_grants
  add column if not exists device_id_hash text;

comment on column public.trial_grants.device_id_hash is
  'SHA-256(hardware UUID + app salt) of the Mac that created this trial. One grant per device (partial unique index below). Nullable: old rows and rare unreadable-UUID clients stay NULL and fall back to the email-only cap.';

-- The hard one-grant-per-device cap, race-safe at the DB level. Partial so the
-- many NULLs (unreadable-UUID clients) never collide with each other.
create unique index if not exists trial_grants_device_id_hash_key
  on public.trial_grants (device_id_hash)
  where device_id_hash is not null;

-- =============================================================================
-- verify_trial_grant — now device-aware. Still the SINGLE writer of trial_grants
-- and still create-once / never-reset by email. The new behavior:
--
--   1. If p_device_id_hash is non-null AND a grant already exists for that
--      device under a DIFFERENT email → return a "device used" sentinel
--      (grant_id = NULL, credits_remaining = 0), creating nothing.
--   2. Otherwise upsert by email_normalized exactly as before (create-once,
--      never reset credits), stamping device_id_hash on first create.
--   3. The partial unique index is the race backstop: two concurrent verifies
--      with the same device + different emails → one wins, the other raises
--      unique_violation, caught here and mapped to the SAME "device used"
--      sentinel.
--
-- The old 2-arg signature is DROPPED first: keeping it alongside a 3-arg version
-- with a defaulted third param would make a 2-arg call ambiguous. The new
-- function defaults p_device_id_hash to null so any 2-arg-style caller (none
-- today besides the updated store) keeps the email-only behavior.
-- =============================================================================
drop function if exists public.verify_trial_grant(text, integer);

create or replace function public.verify_trial_grant(
  p_email          text,
  p_limit          integer,
  p_device_id_hash text default null
)
returns table(grant_id uuid, credits_remaining integer)
language plpgsql
as $$
declare
  v_id    uuid;
  v_used  integer;
  v_limit integer;
begin
  -- (1) Device already burned by a DIFFERENT email → hard block, create nothing.
  if p_device_id_hash is not null then
    perform 1
      from public.trial_grants
     where device_id_hash = p_device_id_hash
       and email_normalized <> p_email;
    if found then
      grant_id := null;
      credits_remaining := 0;
      return next;
      return;
    end if;
  end if;

  -- (2) Create-once / never-reset by email (unchanged), stamping the device on
  -- first create. ON CONFLICT touches ONLY verified_at (if null) and backfills
  -- device_id_hash if it was somehow unset — never the limit or used count.
  begin
    insert into public.trial_grants
      (email_normalized, verified_at, trial_credits_limit, trial_credits_used, device_id_hash)
    values (p_email, now(), p_limit, 0, p_device_id_hash)
    on conflict (email_normalized) do update
      set verified_at    = coalesce(public.trial_grants.verified_at, now()),
          device_id_hash = coalesce(public.trial_grants.device_id_hash, excluded.device_id_hash)
    returning id, trial_credits_used, trial_credits_limit
      into v_id, v_used, v_limit;
  exception when unique_violation then
    -- (3) Race: the partial device index lost the insert to a concurrent verify
    -- under a different email → same hard block.
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

comment on function public.verify_trial_grant(text, integer, text) is
  'Create-once / never-reset trial grant upsert keyed on email_normalized, bound to a hashed device id. Returns (grant_id, credits_remaining); grant_id = NULL is the "device already used (different email)" sentinel. The only writer that establishes a grant.';

grant execute on function public.verify_trial_grant(text, integer, text) to service_role;
