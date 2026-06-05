-- =============================================================================
-- Zerro billing — generation idempotency cache (M1)
-- =============================================================================
-- Closes the "charged-but-dropped response" double-charge: `generate` completes,
-- consumes a credit, returns 200 — but the 200 is LOST (network drop, or the
-- client's 180s timeout fires while the server finishes at ~179s). The client
-- sees a retryable error and re-issues the SAME recording. Without dedup that
-- retry charges a SECOND credit for work already paid for; on a flaky link a
-- trial user could burn 2–3 of 15 credits on one recording.
--
-- The fix is standard payments idempotency. The client mints ONE key per
-- recording (a UUID, reused across every retry of that recording) and sends it
-- as the `Idempotency-Key` header. The first request with a key processes
-- normally, charges, and caches { key → prompt, usage, credits_remaining }. A
-- repeat with the SAME key returns the cached result and the ALREADY-charged
-- balance — no second decrement, no second OpenAI call.
--
-- PRIVACY CARVE-OUT TO §14.5. The rest of the proxy persists NO content: audio,
-- frames, transcript, and the composed prompt live in memory only;
-- generation_log holds token counts + cost + success ONLY. This table is the one
-- deliberate, documented exception: it caches the GENERATED PROMPT (the user's
-- own result, already bound for their clipboard) for the SHORTEST window that
-- reliably covers the retry path — minutes, not days (IDEMPOTENCY_TTL_SECONDS,
-- default 15 min). Reads ignore rows older than the TTL and writes prune expired
-- rows opportunistically, so a generated prompt never lingers past the window.
-- Same content is NEVER written anywhere else.
--
-- SCOPED PER IDENTITY. `identity_key` is the handler's per-identity slot/rate key
-- ("generate:sub:<id>" or "generate:trial:<id>"), so one user's idempotency key
-- can never collide with another's — the PK is (identity_key, idempotency_key).
--
-- Service-role only, like every other billing table (RLS deny-by-default, no
-- policies). Written + read exclusively by the M1 generate handler.
-- =============================================================================

create table public.idempotency_cache (
  identity_key      text        not null,
  idempotency_key   text        not null,
  prompt            text        not null,
  usage             jsonb       not null,
  credits_remaining integer     not null,
  created_at        timestamptz not null default now(),
  primary key (identity_key, idempotency_key)
);

comment on table public.idempotency_cache is
  'M1 generation idempotency: caches { (identity_key, idempotency_key) -> prompt, usage, credits_remaining } so a charged-but-dropped /generate response is replayed on retry WITHOUT a second charge. Documented §14.5 carve-out — holds the generated prompt for a short TTL (IDEMPOTENCY_TTL_SECONDS) only; reads filter on created_at and writes prune expired rows. Service-role only.';

-- Drives both the TTL freshness filter on read and the opportunistic
-- prune-by-age on write.
create index idempotency_cache_created_at_idx on public.idempotency_cache (created_at);

-- RLS deny-by-default, matching every other billing table (*_billing_rls.sql).
-- Only the service role (inside the generate Edge Function) ever touches it.
alter table public.idempotency_cache enable row level security;
alter table public.idempotency_cache force  row level security;
-- INTENTIONALLY NO POLICIES. Deny-by-default is the design.

-- Service-role table grants (RLS bypass still requires table-level privileges;
-- see *_billing_grants.sql for the rationale). anon/authenticated get NOTHING.
grant select, insert, update, delete on public.idempotency_cache to service_role;

-- =============================================================================
-- prune_idempotency_cache — delete rows older than p_ttl_seconds. The handler
-- already prunes opportunistically on each write (and ignores stale rows on
-- read), so correctness + the privacy window do NOT depend on a scheduler. This
-- function exists so a periodic sweep CAN be scheduled if desired, e.g. with
-- pg_cron:
--   select cron.schedule('prune-idempotency-cache', '*/15 * * * *',
--                         $$select public.prune_idempotency_cache(900)$$);
-- (pg_cron is not assumed here — scheduling is left to the operator.)
-- =============================================================================
create or replace function public.prune_idempotency_cache(p_ttl_seconds integer)
returns void
language sql
as $$
  delete from public.idempotency_cache
  where created_at < now() - make_interval(secs => p_ttl_seconds);
$$;

comment on function public.prune_idempotency_cache(integer) is
  'Delete idempotency_cache rows older than p_ttl_seconds. Optional periodic sweep; the handler also prunes on write and filters stale rows on read.';

grant execute on function public.prune_idempotency_cache(integer) to service_role;
