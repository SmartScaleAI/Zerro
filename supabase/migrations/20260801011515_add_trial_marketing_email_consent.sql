-- Record an explicit, verified marketing-email choice for managed-trial users.
-- The trial-start Edge Function writes this only after the user proves control
-- of the submitted address with the emailed verification code.

alter table public.trial_grants
  add column marketing_email_opt_in boolean not null default false,
  add column marketing_email_consent_updated_at timestamptz,
  add column marketing_email_consent_version text;

comment on column public.trial_grants.marketing_email_opt_in is
  'Explicit optional consent to receive Zerro marketing email. False by default.';
comment on column public.trial_grants.marketing_email_consent_updated_at is
  'When the verified user most recently confirmed or withdrew marketing email consent.';
comment on column public.trial_grants.marketing_email_consent_version is
  'Version of the onboarding consent copy presented for the recorded choice.';

-- Preserve the deployed three-argument function for older Edge Function
-- versions. The current trial-start function calls this five-argument overload,
-- which records consent in the same transaction as grant verification.
create or replace function public.verify_trial_grant(
  p_email text,
  p_limit integer,
  p_device_id_hash text,
  p_marketing_email_opt_in boolean,
  p_marketing_email_consent_version text
)
returns table(grant_id uuid, credits_remaining integer)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_grant_id uuid;
  v_credits_remaining integer;
begin
  select verified.grant_id, verified.credits_remaining
    into v_grant_id, v_credits_remaining
    from public.verify_trial_grant(
      p_email,
      p_limit,
      p_device_id_hash
    ) as verified;

  if v_grant_id is not null then
    update public.trial_grants
       set marketing_email_opt_in = case
             when p_marketing_email_opt_in is null
               then public.trial_grants.marketing_email_opt_in
             else p_marketing_email_opt_in
           end,
           marketing_email_consent_updated_at = case
             when p_marketing_email_opt_in is null
               then public.trial_grants.marketing_email_consent_updated_at
             else now()
           end,
           marketing_email_consent_version = case
             when p_marketing_email_opt_in is null
               then public.trial_grants.marketing_email_consent_version
             else nullif(
               pg_catalog.btrim(p_marketing_email_consent_version),
               ''
             )
           end
     where id = v_grant_id;
  end if;

  grant_id := v_grant_id;
  credits_remaining := v_credits_remaining;
  return next;
end;
$$;

revoke all on function public.verify_trial_grant(text, integer, text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.verify_trial_grant(text, integer, text, boolean, text)
  to service_role;
