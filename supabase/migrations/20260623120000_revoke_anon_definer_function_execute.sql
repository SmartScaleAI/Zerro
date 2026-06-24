-- =============================================================================
-- Pre-launch hardening D-01 — revoke PUBLIC execute on two SECURITY DEFINER fns
-- =============================================================================
-- (PRE_RELEASE_REVIEW_LOG.md D-01 / C-02 / C-03; advisor lints 0028 + 0029.)
--
-- Two `SECURITY DEFINER` functions ship with the Postgres default ACL (EXECUTE
-- granted to PUBLIC), which PostgREST exposes — so the `anon` and `authenticated`
-- roles can invoke them unauthenticated over `/rest/v1/rpc/<fn>`:
--
--   * public.refresh_agent_models_cron()  (C-02, confirmed live & exploitable) —
--     forces a Vault read + provider model-list fetch + idempotent DB writes + a
--     pg_net POST. Bounded resource-abuse (no secret leak, writes are idempotent,
--     the provider `/v1/models` call is unbilled), but it must NOT be publicly
--     triggerable. It is only ever meant to run from the daily pg_cron job.
--   * public.rls_auto_enable()  (C-03) — the `ensure_rls` event-trigger function.
--     It returns `event_trigger`, so it is not actually callable as an RPC and is
--     NOT exploitable; we revoke purely for hygiene so the advisor stops flagging
--     it. (Its body is live-only schema drift, tracked separately under C-03;
--     this migration only fixes the grant.)
--
-- WHY THE DAILY CRON IS UNAFFECTED — verified, not assumed:
--   Both functions are owned by `postgres` (verified: pg_proc.proowner = postgres).
--   The pg_cron job `refresh-agent-models` runs `select public.refresh_agent_models_cron();`
--   as username `postgres` (verified: cron.job.username = postgres; the role that
--   called cron.schedule in 20260618120100_agent_models_cron.sql, whose own comment
--   states "The job runs as the migration role (postgres)"). A REVOKE that names
--   only PUBLIC / anon / authenticated never strips the OWNER's implicit EXECUTE —
--   `postgres` retains it — so the cron keeps executing the function exactly as
--   before. Only the anonymous REST surface loses access.
--
-- POST-DEPLOY CHECK: security advisor lints 0028 (anon_security_definer_function_
-- executable) and 0029 (authenticated_security_definer_function_executable) clear
-- for both functions, and tomorrow's `refresh-agent-models` cron run still fires.
--
-- IDEMPOTENT: REVOKE is a no-op when the privilege is already absent, so this is
-- safe to re-apply. The refresh_agent_models_cron() revoke is plain — that
-- function is created by an earlier migration, so it always exists on replay.
-- The rls_auto_enable() revoke is guarded by an existence check because that
-- function is live-only schema drift (C-03): it is absent on a from-scratch
-- replay (`supabase db reset` / shadow DB), where a bare REVOKE would error.
-- =============================================================================

revoke execute on function public.refresh_agent_models_cron() from public, anon, authenticated;

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  else
    raise notice 'rls_auto_enable() not present (schema drift, C-03); skipping revoke';
  end if;
end
$$;
