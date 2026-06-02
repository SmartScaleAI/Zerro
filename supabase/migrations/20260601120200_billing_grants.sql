-- =============================================================================
-- Zerro billing — privilege grants (Phase D1)
-- =============================================================================
-- RLS deny-by-default (in *_billing_rls.sql) controls WHICH ROWS a role may
-- touch. This migration controls WHICH ROLES may touch the tables at all —
-- a separate, prior gate. The Edge Functions connect as `service_role`, which
-- BYPASSES RLS, but a role still needs table-level privileges before RLS is
-- even consulted. Without these grants every service-role query fails with
-- "permission denied for table …" (→ 500 from the functions).
--
-- We grant ONLY to `service_role`. `anon` and `authenticated` are deliberately
-- left with NO privileges — combined with deny-by-default RLS, that is the
-- control that stops any user from reading/editing credit counts (§6.2/§14.3).
-- Do NOT add anon/authenticated grants here.
-- =============================================================================

grant usage on schema public to service_role;

grant select, insert, update, delete on
  public.subscriptions,
  public.usage_periods,
  public.trial_grants,
  public.webhook_events,
  public.pending_license_keys,
  public.generation_log,
  public.rate_limits
to service_role;

-- The functions are SECURITY INVOKER and called by service_role; grant EXECUTE
-- explicitly (don't rely on the PUBLIC default).
grant execute on function public.consume_credit(uuid) to service_role;
grant execute on function public.check_rate_limit(text, integer, integer) to service_role;
