-- =============================================================================
-- Zerro Dev Mode — agent_models manifest (server-fetched, app-consumed)
-- =============================================================================
-- Backs the Dev Mode "Model" picker: the model id the coding agent is launched
-- with (`--model <id>`). The `refresh-agent-models` Edge Function fetches the
-- live model lists from the provider APIs (Anthropic, OpenAI) on a daily cron
-- and upserts them here; the public `agent-models` read function serves the
-- active rows to the app. New provider model versions appear automatically on
-- the next refresh with NO app release (the curation surface is a pair of
-- stable regexes in the refresh function, not this schema).
--
-- NON-SENSITIVE: every column is a public model id / display string — there is
-- no credential or user data here. The read path is therefore unauthenticated
-- (served by the `agent-models` function). RLS is still ON with NO permissive
-- policies (deny-by-default, like the billing tables): the ONLY writer is the
-- refresh job via the service role (which BYPASSES RLS), and the ONLY reader is
-- the `agent-models` function, also via the service role. The app never touches
-- this table directly.
--
-- Cursor is deliberately NOT modeled here — its list has no server API we can
-- call, so the app fetches it client-side from the `cursor-agent models` CLI
-- (see the app integration, Part 5).
--
-- IDEMPOTENT — safe to re-run: `create table if not exists`, `enable row level
-- security` is a no-op when already enabled, and the grants are additive.
-- =============================================================================

create table if not exists public.agent_models (
  id           uuid primary key default gen_random_uuid(),
  provider     text not null check (provider in ('anthropic', 'openai')),
  model_id     text not null,                 -- exact string passed to --model
  display_name text not null,
  -- 0 = newest within the provider = the default pick. Reassigned on every
  -- refresh from the provider's created/created_at ordering.
  rank         int  not null default 0,
  -- false marks a model that vanished from the provider's list on a later
  -- refresh. Inactive rows are retained (history / a remembered pick can detect
  -- it is gone) but never served by `agent-models`.
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  -- Stamped explicitly by the refresh job to the per-run sync timestamp; the
  -- vanished->inactive sweep keys off it (rows whose updated_at predates the
  -- current sync were not in this fetch). No trigger — the writer owns it.
  updated_at   timestamptz not null default now(),
  unique (provider, model_id)
);

-- Read path: `agent-models` selects active rows ordered by (provider, rank).
create index if not exists agent_models_provider_rank_active_idx
  on public.agent_models (provider, rank)
  where active;

-- ---------------------------------------------------------------------------
-- RLS: deny-by-default. No anon/authenticated policies — same posture as the
-- billing tables. Both the refresh writer and the read function use the service
-- role, which bypasses RLS; with no permissive policy, a leaked anon key reads
-- and writes NOTHING here. (The data is public, but the WRITE path must stay
-- service-role-only so a user can't poison the manifest.)
-- ---------------------------------------------------------------------------
alter table public.agent_models enable row level security;
alter table public.agent_models force  row level security;

-- ---------------------------------------------------------------------------
-- Grants: service_role only (the Edge Functions' principal). anon/authenticated
-- get nothing. select is needed by the read function; insert/update by refresh.
-- delete is granted for completeness (manual cleanup of stale inactive rows).
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.agent_models to service_role;

comment on table public.agent_models is
  'Server-fetched coding-agent model manifest for Dev Mode. Written by the refresh-agent-models Edge Function (daily cron), read by the public agent-models function. Non-sensitive (public model ids); RLS deny-by-default keeps the WRITE path service-role-only. Cursor is NOT here (client-side CLI).';
