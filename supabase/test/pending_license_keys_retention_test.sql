-- =============================================================================
-- A-07 retention wiring test (20260709120000_pending_license_keys_retention).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/pending_license_keys_retention_test.sql
--
-- Read-only assertions (RAISE EXCEPTION on violation; ON_ERROR_STOP makes psql
-- exit non-zero): the prune job is registered with the intended schedule +
-- retention. No index assertion — the table is a near-empty transient buffer,
-- so the daily delete deliberately seq-scans (see the migration header).
-- =============================================================================

begin;

do $$
declare
  job record;
begin
  -- pending-license-keys-prune: daily 04:45, 30-day retention on created_at.
  select schedule, command into job from cron.job where jobname = 'pending-license-keys-prune';
  if job is null then
    raise exception 'cron job pending-license-keys-prune is not registered';
  end if;
  if job.schedule <> '45 4 * * *' then
    raise exception 'pending-license-keys-prune schedule unexpected: %', job.schedule;
  end if;
  if job.command not like '%public.pending_license_keys%'
    or job.command not like '%created_at%'
    or job.command not like '%30 days%' then
    raise exception 'pending-license-keys-prune command unexpected: %', job.command;
  end if;

  raise notice 'A-07 retention wiring OK: prune job registered';
end $$;

rollback;
