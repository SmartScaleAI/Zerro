-- =============================================================================
-- A-14 retention wiring test (20260708130000_webhook_events_rate_limits_retention).
-- =============================================================================
-- Run against the LOCAL stack (after `supabase migration up`):
--   docker exec -i supabase_db_zerro psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f - < supabase/test/webhook_events_rate_limits_retention_test.sql
--
-- Read-only assertions (RAISE EXCEPTION on violation; ON_ERROR_STOP makes psql
-- exit non-zero): both prune jobs are registered with the intended schedule +
-- retention, and the deletes' driving indexes exist — the NEW
-- webhook_events(processed_at) and the PRE-EXISTING rate_limits window index
-- from the billing schema the prune relies on.
-- =============================================================================

begin;

do $$
declare
  job record;
begin
  -- webhook-events-prune: daily 04:15, 30-day retention on processed_at.
  select schedule, command into job from cron.job where jobname = 'webhook-events-prune';
  if job is null then
    raise exception 'cron job webhook-events-prune is not registered';
  end if;
  if job.schedule <> '15 4 * * *' then
    raise exception 'webhook-events-prune schedule unexpected: %', job.schedule;
  end if;
  if job.command not like '%public.webhook_events%'
    or job.command not like '%processed_at%'
    or job.command not like '%30 days%' then
    raise exception 'webhook-events-prune command unexpected: %', job.command;
  end if;

  -- rate-limits-prune: daily 04:30, 3-day retention on window_start.
  select schedule, command into job from cron.job where jobname = 'rate-limits-prune';
  if job is null then
    raise exception 'cron job rate-limits-prune is not registered';
  end if;
  if job.schedule <> '30 4 * * *' then
    raise exception 'rate-limits-prune schedule unexpected: %', job.schedule;
  end if;
  if job.command not like '%public.rate_limits%'
    or job.command not like '%window_start%'
    or job.command not like '%3 days%' then
    raise exception 'rate-limits-prune command unexpected: %', job.command;
  end if;

  -- Driving indexes for the daily deletes.
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'webhook_events'
      and indexname = 'webhook_events_processed_at'
  ) then
    raise exception 'index webhook_events_processed_at is missing';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'rate_limits'
      and indexname = 'rate_limits_window_start_idx'
  ) then
    raise exception 'index rate_limits_window_start_idx is missing';
  end if;

  raise notice 'A-14 retention wiring OK: both prune jobs registered, driving indexes present';
end $$;

rollback;
