-- =============================================================================
-- Pre-launch hardening A-07 — retention sweep for pending_license_keys
-- =============================================================================
-- pending_license_keys is a reconciliation buffer: license_key_created stashes
-- a key hash by order id when it arrives before its subscription_created, and
-- adoption on subscription_created drains the row. A subscription event that
-- lacks order_id can never adopt (the webhook handler warn-logs
-- `no_order_id_pending_key_unadopted`), so such a row orphans — safe (nothing
-- spends off it) but with no sweep it would accumulate forever.
--
-- Sweep rows older than 30 days, mirroring A-14's webhook_events prune: the
-- out-of-order window between license_key_created and subscription_created
-- plays out over seconds-to-minutes, and even LemonSqueezy's redelivery/retry
-- tail sits comfortably inside 30 days — a row that old is one whose
-- subscription_created is never coming (or could never adopt it).
--
-- No driving index: unlike webhook_events (one row per delivery, forever),
-- this table only ever holds the transient out-of-order buffer plus rare
-- orphans — near-zero rows — so the daily delete's seq scan costs less than
-- taxing every insert with an index it doesn't need.
--
-- Staggered off the existing 04:00/04:15/04:30 daily sweeps. Pure SQL (no
-- secrets, no pg_net), so it's safe to schedule straight from the migration.
--
-- IDEMPOTENT: `create extension if not exists`, and `cron.schedule` UPSERTS by
-- job name (pg_cron >= 1.4), so a re-apply is a no-op.
-- =============================================================================

-- Already enabled by earlier migrations; the guard keeps this one
-- self-contained and re-appliable on a fresh database.
create extension if not exists pg_cron;

select cron.schedule(
  'pending-license-keys-prune',
  '45 4 * * *',
  $$ delete from public.pending_license_keys where created_at < now() - interval '30 days'; $$
);
