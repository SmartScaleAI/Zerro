-- =============================================================================
-- Zerro billing — credits_charged in the idempotency cache (Plan Appendix D, D2)
-- =============================================================================
-- The generate 200 response now reports `credits_charged` explicitly so the
-- app's "−N credits" toast is exact (variable per-model pricing + the rare
-- circuit-breaker metered charge make deriving it client-side wrong). A
-- replayed idempotent result must report the SAME charge as the original, so
-- the cached shape carries it too.
--
-- Nullable for rows written before this migration; the reader coalesces NULL
-- to 0. That window is bounded by IDEMPOTENCY_TTL_SECONDS (minutes) — every
-- row is pruned/ignored past the TTL, so no long-lived NULLs exist.
-- =============================================================================

alter table public.idempotency_cache
  add column credits_charged integer;

comment on column public.idempotency_cache.credits_charged is
  'Credits charged for the original generation (D2): replayed verbatim so a retry reports the same charge. 0 for the uncharged-race path; NULL only for pre-migration rows (read as 0, gone within the TTL).';
