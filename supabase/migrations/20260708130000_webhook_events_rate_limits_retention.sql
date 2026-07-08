-- =============================================================================
-- Pre-launch hardening A-14 — retention for webhook_events + rate_limits
-- =============================================================================
-- Both tables grow unbounded: every LemonSqueezy delivery inserts a
-- webhook_events idempotency row forever, and every rate-limited request
-- upserts a rate_limits (key, window_start) bucket that is never read again
-- once its window passes (check_rate_limit only consults the CURRENT window).
-- Neither is analytics — they are transient operational ledgers — so sweep them
-- daily with pg_cron, exactly like affiliate-referrals-prune.
--
-- Retention choices:
--   * webhook_events: 30 days. The idempotency ledger exists to absorb
--     LemonSqueezy redeliveries/retries, which play out over minutes-to-days;
--     30 days comfortably exceeds LS's redelivery/retry window, so pruning can
--     never resurrect a duplicate in practice. And even a hypothetical
--     >30-day-late redelivery re-processing is harmless: the handlers are
--     idempotent and the strictly-older stale-drop (ls_updated_at) discards
--     out-of-date mutations.
--   * rate_limits: 3 days. check_rate_limit only ever reads the CURRENT
--     window's row; the largest window configured anywhere in the codebase is
--     TRIAL_SEND_WINDOW_SECONDS = 1 day (C-05), so 3 days is a safe margin.
--     If a future limiter window ever exceeds this, bump the interval with it.
--
-- The daily deletes are index-driven, not seq scans:
--   * webhook_events(processed_at) gets a NEW index — its only index was the
--     ls_event_id primary key;
--   * rate_limits(window_start) is ALREADY covered by
--     rate_limits_window_start_idx (20260601120000_billing_schema.sql): the
--     (key, window_start) pk can't serve a window_start-only predicate, which
--     is exactly why that index exists. No second index is created here — a
--     duplicate under a new name would just tax every limiter write.
--
-- The jobs are staggered off the existing 04:00 affiliate-referrals-prune so
-- the daily sweeps don't pile up. Pure SQL (no secrets, no pg_net), so it's
-- safe to schedule straight from the migration.
--
-- IDEMPOTENT: `create extension/index if not exists`, and `cron.schedule`
-- UPSERTS by job name (pg_cron >= 1.4), so a re-apply is a no-op.
-- =============================================================================

-- Already enabled by earlier migrations; the guard keeps this one
-- self-contained and re-appliable on a fresh database.
create extension if not exists pg_cron;

-- The webhook prune's driving index (the ls_event_id pk can't serve a
-- processed_at range scan).
create index if not exists webhook_events_processed_at
  on public.webhook_events (processed_at);

select cron.schedule(
  'webhook-events-prune',
  '15 4 * * *',
  $$ delete from public.webhook_events where processed_at < now() - interval '30 days'; $$
);

select cron.schedule(
  'rate-limits-prune',
  '30 4 * * *',
  $$ delete from public.rate_limits where window_start < now() - interval '3 days'; $$
);
