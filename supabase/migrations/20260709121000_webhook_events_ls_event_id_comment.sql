-- =============================================================================
-- A-09 (comment-only) — fix the stale description of webhook_events.ls_event_id
-- =============================================================================
-- The original billing schema described ls_event_id as "= the per-payload
-- X-Signature HMAC", but the deployed webhook has long keyed idempotency on the
-- composite eventName:resourceId:updatedAt — and as of A-09 it appends the
-- verified X-Signature as a discriminator, so the key is now
-- eventName:resourceId:updatedAt:signature (the signature ALONE only as the
-- fallback when the resource id is missing). Update the table comment to match
-- reality. No schema change; text PK comfortably fits the composite.
-- =============================================================================

comment on table public.webhook_events is
  'Idempotency ledger. ls_event_id = eventName:resourceId:updatedAt:signature (LemonSqueezy ships no stable event id; the verified X-Signature HMAC over the raw body discriminates same-key forgeries). An exact redelivery shares it. Fallback when the resource id is missing: the signature alone.';
