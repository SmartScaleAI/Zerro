-- =============================================================================
-- C-09 — atomic attempt counter for pending trial codes
-- =============================================================================
-- trial-start's incrementCodeAttempts was a read-then-write from the edge
-- function (select attempts → update attempts = n + 1): two concurrent failed
-- verifies could lose an increment. Not exploitable in practice (the per-email
-- rate limit bounds verify attempts, and the TTL + 6-digit space are the real
-- brute-force bound), but the counter backs the CODE_MAX_ATTEMPTS cutoff, so
-- make it a single atomic UPDATE via RPC. A missing row is a no-op — matching
-- the old behavior when the code had already been consumed/expired.
--
-- SECURITY INVOKER + pinned empty search_path (schema-qualified body, so ''
-- is safe — same posture as the other trial RPCs, and re-pinned here because
-- CREATE OR REPLACE resets function options; see A-15). Executable by
-- service_role, the only caller (the trial-start function's client).
--
-- IDEMPOTENT: `create or replace` + re-grant — a re-apply is a no-op.
-- =============================================================================

create or replace function public.increment_trial_code_attempts(p_email text)
returns void
language sql
security invoker
set search_path = ''
as $$
  update public.trial_codes
     set attempts = attempts + 1
   where email_normalized = p_email;
$$;

comment on function public.increment_trial_code_attempts(text) is
  'Atomically bump the failed-verify attempt counter on a pending trial code (C-09). Missing row = no-op. Called by trial-start on every failed code verify.';

grant execute on function public.increment_trial_code_attempts(text) to service_role;
