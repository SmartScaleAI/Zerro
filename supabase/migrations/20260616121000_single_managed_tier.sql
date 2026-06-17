-- =============================================================================
-- Zerro billing — collapse starter/pro → a single "managed" tier (metered-credits
-- Phase 6)
-- =============================================================================
-- There is now ONE managed plan (300 credits / $15) plus credit packs; the
-- starter/pro split is gone. This migration retires the old two-value tier CHECK,
-- migrates every existing subscription row to 'managed', and installs a new
-- single-value CHECK.
--
-- IDEMPOTENT — safe to re-run (and to apply against a DB already partly migrated):
--   * drop constraint IF EXISTS (the old subscriptions_tier_check);
--   * the UPDATE only touches rows still on the legacy values;
--   * the new CHECK is added inside a pg_constraint existence DO block (Postgres
--     has no ADD CONSTRAINT IF NOT EXISTS), so a second run is a no-op.
-- =============================================================================

-- 1. Drop the old two-value CHECK so the rows can be rewritten.
alter table public.subscriptions drop constraint if exists subscriptions_tier_check;

-- 2. Migrate every legacy row to the single managed tier (numbers unchanged —
--    credits_limit is denormalized and already 300 for the managed plan).
update public.subscriptions set tier = 'managed' where tier in ('starter', 'pro');

-- 3. Install the single-value CHECK, guarded so a re-run is a no-op.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'subscriptions_tier_managed_check'
  ) then
    alter table public.subscriptions
      add constraint subscriptions_tier_managed_check check (tier in ('managed'));
  end if;
end
$$;
