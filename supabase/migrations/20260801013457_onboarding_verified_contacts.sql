-- Verified onboarding contacts are intentionally separate from trial grants.
-- Email verification happens before the user chooses Zerro Cloud or Local +
-- Own API Keys, so proving mailbox ownership must not claim either mutually
-- exclusive free-trial type.

create table public.onboarding_contacts (
  id uuid primary key default gen_random_uuid(),
  email_normalized text not null unique,
  verified_at timestamptz not null default now(),
  marketing_email_opt_in boolean not null default false,
  marketing_email_consent_updated_at timestamptz,
  marketing_email_consent_version text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.onboarding_contacts is
  'Mailbox-verified onboarding contacts recorded before a user selects Managed or BYOK. Does not grant or claim a trial.';
comment on column public.onboarding_contacts.marketing_email_opt_in is
  'Explicit optional consent to receive Zerro marketing email. False by default.';
comment on column public.onboarding_contacts.marketing_email_consent_updated_at is
  'When the verified user most recently confirmed or withdrew marketing email consent.';
comment on column public.onboarding_contacts.marketing_email_consent_version is
  'Version of the onboarding marketing-consent copy presented for the recorded choice.';

alter table public.onboarding_contacts enable row level security;
alter table public.onboarding_contacts force row level security;

-- Only the trial-start Edge Function's service-role client reads or writes
-- these rows. No direct Data API access is needed by the desktop app.
revoke all on table public.onboarding_contacts from public, anon, authenticated;
grant select, insert, update on table public.onboarding_contacts to service_role;
