-- =============================================================================
-- Zerro Dev Mode — daily cron to refresh the agent_models manifest
-- =============================================================================
-- Schedules a daily pg_cron job that POSTs the `refresh-agent-models` Edge
-- Function (via pg_net) with the shared REFRESH_CRON_SECRET. The function fetches
-- the live provider model lists and upserts them (idempotent), so daily is the
-- natural cadence: new model versions appear within ~a day with no app release.
--
-- SECRET-SAFE: the function URL and the cron secret are NOT hardcoded in this
-- migration (it is committed to git). They are read at run time from Supabase
-- Vault. A thin SECURITY DEFINER wrapper reads the two secrets and only POSTs
-- when both are present — so applying this migration before the operator seeds
-- Vault is harmless (the job logs a skip notice instead of erroring).
--
-- OPERATOR SETUP (run ONCE, out of band — values are secrets, never committed):
--   select vault.create_secret(
--     'https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<REFRESH_CRON_SECRET value>', 'refresh_cron_secret');
--   -- and set the matching Edge secret:  supabase secrets set REFRESH_CRON_SECRET=<same value>
-- Re-seeding (rotate): select vault.update_secret(
--   (select id from vault.secrets where name='refresh_cron_secret'), '<new value>');
--
-- IDEMPOTENT: `create extension if not exists`, `create or replace function`,
-- and `cron.schedule` UPSERTS by job name (pg_cron >= 1.4), so a re-apply can't
-- duplicate the job. pg_cron was already enabled by the yearly-credit migration;
-- it is re-enabled here defensively. pg_net is enabled here for net.http_post.
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- Wrapper: reads the function URL + cron secret from Vault and fires the POST.
-- SECURITY DEFINER so it can read vault.decrypted_secrets; search_path pinned to
-- '' with every relation/function fully qualified (advisor 0011). If either
-- secret is missing it logs and returns — never POSTs to a null URL.
-- ---------------------------------------------------------------------------
create or replace function public.refresh_agent_models_cron()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base   text;
  v_secret text;
begin
  select decrypted_secret into v_base
    from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'refresh_cron_secret';

  if v_base is null or v_secret is null then
    raise notice
      'refresh_agent_models_cron: vault secret project_url and/or refresh_cron_secret missing; skipping POST';
    return;
  end if;

  perform net.http_post(
    url     := rtrim(v_base, '/') || '/functions/v1/refresh-agent-models',
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      'x-refresh-secret', v_secret
    ),
    body    := '{}'::jsonb
  );
end;
$$;

comment on function public.refresh_agent_models_cron() is
  'Daily pg_cron entrypoint: reads project_url + refresh_cron_secret from Vault and POSTs the refresh-agent-models Edge Function via pg_net. No-ops (logs) if either secret is unseeded. Idempotent on the server side.';

-- The job runs as the migration role (postgres), which can execute the wrapper
-- and read Vault. No service_role grant needed.

-- ---------------------------------------------------------------------------
-- Schedule: daily at 06:00 UTC. The refresh is idempotent and cheap; daily just
-- bounds how stale the manifest can get (≤ ~1 day) — a same-day re-run is a
-- no-op upsert. cron.schedule upserts by name, so re-applying is safe.
-- ---------------------------------------------------------------------------
select cron.schedule(
  'refresh-agent-models',
  '0 6 * * *',
  $$ select public.refresh_agent_models_cron(); $$
);
