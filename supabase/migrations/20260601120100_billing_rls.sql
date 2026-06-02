-- =============================================================================
-- Zerro billing — Row Level Security (Phase D1)
-- =============================================================================
-- POSTURE: deny-by-default on EVERY billing table. We enable RLS and add NO
-- permissive policies, so the `anon` and `authenticated` roles can read/write
-- NOTHING. The ONLY access path is the service role used inside Edge Functions
-- (the service role bypasses RLS entirely).
--
-- WHY THIS IS THE CONTROL (billing-plan §6.2 / §14.3): the Mac app never
-- receives a Supabase anon/publishable key and never queries these tables
-- directly — it only calls Edge Functions. With no anon/authenticated policy,
-- even a leaked anon key cannot read or edit credit counts, subscription
-- status, or trial grants. This is what stops a user from forging entitlement
-- or zeroing their own credits_used. Do not add a permissive policy here
-- without re-deriving the threat model — an `anon`/`authenticated` policy on
-- any of these tables would punch a hole straight through the money guard.
--
-- FORCE RLS: we also FORCE row security so that even the table owner is subject
-- to it; the service role is exempt (it has BYPASSRLS), which is exactly the
-- only role we want touching these tables.
-- =============================================================================

alter table public.subscriptions        enable row level security;
alter table public.subscriptions        force  row level security;

alter table public.usage_periods         enable row level security;
alter table public.usage_periods         force  row level security;

alter table public.trial_grants          enable row level security;
alter table public.trial_grants          force  row level security;

alter table public.webhook_events        enable row level security;
alter table public.webhook_events        force  row level security;

alter table public.pending_license_keys  enable row level security;
alter table public.pending_license_keys  force  row level security;

alter table public.generation_log        enable row level security;
alter table public.generation_log        force  row level security;

alter table public.rate_limits           enable row level security;
alter table public.rate_limits           force  row level security;

-- INTENTIONALLY NO POLICIES BELOW THIS LINE.
-- Deny-by-default is the design. Service-role Edge Functions are the only
-- writers/readers. See header for rationale.
