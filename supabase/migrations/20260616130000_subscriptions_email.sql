-- =============================================================================
-- Zerro billing — subscriptions.email_normalized (human-readable identifier)
-- =============================================================================
-- Adds a human-readable identifier to the subscription mirror so a row can be
-- recognized by email instead of only the opaque LemonSqueezy customer id.
-- Mirrors the existing trial_grants.email_normalized convention.
--
-- DESIGN:
--   * Denormalized convenience field, NOT a key. ls_subscription_id stays the
--     unique identity; email is mutable in LemonSqueezy and rides alongside.
--   * NULLABLE: pre-migration rows (and any sub whose webhook predates this
--     column) stay NULL until the next subscription_created/_updated refreshes.
--   * NON-UNIQUE: one person may hold multiple subscriptions; a duplicate or
--     stale email must never block an upsert.
--   * Stored lowercased + trimmed (the webhook normalizes on write). Unlike
--     trial_grants this does NOT collapse Gmail dots/+tags — that aggressive
--     form exists to defeat trial farming; here the goal is recognizing the
--     real address a customer used.
--   * PII: this is the one new place email lives for paid subs. The existing
--     per-customer delete flow removes it for free (it lives on the sub row).
--     Never sent to analytics (§14.5) — the webhook only forwards tier to PostHog.
--
-- REPO ↔ LIVE RECONCILIATION: applied live via the Supabase MCP migration
-- `subscriptions_email_normalized`; this file is the repo record of that change.

alter table public.subscriptions
  add column if not exists email_normalized text;

comment on column public.subscriptions.email_normalized is
  'Denormalized buyer email (lowercased+trimmed) for human identification. Mutable, non-key, nullable. Written by the lemonsqueezy-webhook on subscription_created/_updated from attributes.user_email. Never sent to analytics (§14.5).';
