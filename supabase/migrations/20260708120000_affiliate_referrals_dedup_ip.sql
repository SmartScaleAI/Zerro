-- =============================================================================
-- Pre-launch hardening C-08 — dedup affiliate_referrals to one row per ip_hash
-- =============================================================================
-- The `affiliate` Edge Function's POST was a plain INSERT on an UNAUTHENTICATED
-- endpoint: every landing-page hit (or a curl loop) appended a row, making the
-- table an unbounded insert amplifier until the 30-day prune. But only the
-- LATEST row per ip_hash is ever read (latestCode: max created_at within the
-- window), so the table needs exactly ONE row per ip_hash — latest code +
-- timestamp win.
--
--   1. De-duplicate existing rows: keep the newest per ip_hash (max created_at,
--      id as the tiebreaker for equal timestamps). Safe: this is a transient
--      matching buffer, and the deleted rows are precisely the ones latestCode
--      could never return.
--   2. UNIQUE index on (ip_hash) — the structural fix. The function's record()
--      switches to upsert(..., onConflict: "ip_hash"), so table growth is
--      bounded by the number of distinct visitor IPs, not by request volume.
--
-- The (ip_hash, created_at desc) lookup index and the 30-day prune cron stay:
-- the prune still ages out stale rows (now one per IP), and the composite index
-- still serves the windowed GET.
--
-- IDEMPOTENT: the DELETE is a no-op once deduped (and vacuous under the unique
-- index), and `create unique index if not exists` is a no-op on re-apply.
-- =============================================================================

-- 1) Keep only the newest row per ip_hash — a row is deleted iff a strictly
--    greater (created_at, id) twin exists, so exactly the tuple-max survives
--    (id breaks exact created_at ties deterministically).
delete from public.affiliate_referrals a
using public.affiliate_referrals b
where a.ip_hash = b.ip_hash
  and (a.created_at, a.id) < (b.created_at, b.id);

-- 2) One row per ip_hash from here on. A UNIQUE INDEX (not a table constraint)
--    is all the upsert's ON CONFLICT (ip_hash) inference needs.
create unique index if not exists affiliate_referrals_ip_hash_unique
  on public.affiliate_referrals (ip_hash);
