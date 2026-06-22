-- =============================================================================
-- Affiliate attribution — IP-matched referral capture
-- =============================================================================
-- Backs the `affiliate` Edge Function. Purchasing happens only inside the Mac
-- app, which can't read the affiliate referral the visitor picked up in their
-- browser. So we match server-side on the device's public IP:
--
--   1. The website POSTs `?aff=CODE` to `affiliate` when a visitor lands. The
--      function stores the code keyed to a HASH of the caller's public IP.
--   2. At checkout the app GETs `affiliate`; the function looks up the most
--      recent code for the caller's IP hash (within a window) and returns it.
--      The app appends it to the LemonSqueezy checkout as `aff_ref`.
--
-- PRIVACY: the raw IP is never stored. We keep `sha256(AFFILIATE_IP_SALT || ip)`
-- only — enough to match the same network egress IP, not enough to recover it —
-- and prune rows on a short retention so this stays a transient matching buffer,
-- not a log. The salt lives in the Edge secret `AFFILIATE_IP_SALT` (never here).
--
-- IDEMPOTENT: `create table/index if not exists`, `create extension if not
-- exists`, and `cron.schedule` upserts by job name, so a re-apply is a no-op.
-- =============================================================================

create table if not exists public.affiliate_referrals (
  id         bigint generated always as identity primary key,
  -- sha256(salt || public_ip), lowercase hex. NOT the raw IP (see header).
  ip_hash    text        not null,
  -- The affiliate's code — the value after `?aff=` and what rides back as
  -- `aff_ref` on the checkout URL.
  aff_code   text        not null,
  created_at timestamptz not null default now()
);

comment on table public.affiliate_referrals is
  'Transient IP-hash → affiliate-code matching buffer for in-app-purchase attribution. Raw IPs are never stored; rows are pruned on a short retention.';

-- Lookup is always "latest row for this ip_hash within the window", so a
-- descending composite index serves it directly.
create index if not exists affiliate_referrals_ip_recent
  on public.affiliate_referrals (ip_hash, created_at desc);

-- RLS on, no policies: only the service role (which BYPASSES RLS, used by the
-- Edge Function) can touch it. Belt-and-suspenders revoke of the default
-- public-schema grants so anon/authenticated can't reach it via PostgREST.
alter table public.affiliate_referrals enable row level security;
revoke all on public.affiliate_referrals from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention: prune match rows older than 30 days, daily at 04:00 UTC. This is
-- a matching buffer, not analytics — a click that hasn't converted in 30 days
-- won't be matched anyway, and short retention keeps the privacy surface small.
-- Pure SQL (no secrets), so it's safe to schedule straight from the migration.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'affiliate-referrals-prune',
  '0 4 * * *',
  $$ delete from public.affiliate_referrals where created_at < now() - interval '30 days'; $$
);
