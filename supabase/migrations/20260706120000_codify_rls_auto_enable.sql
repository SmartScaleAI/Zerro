-- C-03: codify the live-only rls_auto_enable() + ensure_rls trigger (schema drift).
-- Both already exist in production (pulled verbatim from pg_get_functiondef /
-- pg_event_trigger); this is a no-op on live and only fixes from-scratch replays
-- (db reset / shadow / preview branch) where the RLS-auto-enable net was missing.
-- Idempotent + replay-safe: CREATE OR REPLACE (no-op on live), a D-01-mirroring
-- hygiene REVOKE (so the function is created already-hardened even on a fresh
-- replay where D-01 ran before this file and its existence-guard skipped), and a
-- create-only-if-absent event trigger.

create or replace function public.rls_auto_enable()
 returns event_trigger
 language plpgsql
 security definer
 set search_path to 'pg_catalog'
as $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

-- D-01 hygiene: SECURITY DEFINER fn — strip default PUBLIC execute (no-op on live,
-- where D-01 already did this). rls_auto_enable returns event_trigger so it isn't
-- RPC-callable anyway; this keeps the codified state identical to production.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- Wire the ddl_command_end trigger (create only if absent — no-op on live).
do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls
      on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.rls_auto_enable();
  end if;
end
$$;
