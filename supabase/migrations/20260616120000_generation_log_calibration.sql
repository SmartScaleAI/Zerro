-- =============================================================================
-- Zerro billing — generation_log calibration metadata (metered-credits Phase 3)
-- =============================================================================
-- Adds three nullable, NON-CONTENT calibration columns to generation_log so the
-- metered-credit estimator (cost.ts estimateGenerationCredits / the FRAME_TOKENS
-- + OUTPUT_TOKENS_ESTIMATE tunables) can be retuned post-launch from real
-- (frames, duration, charge) data — the §2 calibration caveat, A2 hook:
--
--   * credits_used     — the credits ACTUALLY charged for the generation, so
--                        metered charge can be reconciled against est_cost_usd.
--   * duration_seconds — the recording length (Whisper-measured), the audio
--                        cost driver and the FRAME_TOKENS denominator.
--   * frame_count      — keyframes sent, to retune FRAME_TOKENS from real
--                        (frames, tokens_in) pairs.
--
-- All three are non-content metadata, consistent with §14.5 (still never
-- transcript, audio, frames, or prompt text). Nullable: rows from before this
-- migration — and every failure row — stay NULL.
--
-- REPO ↔ LIVE RECONCILIATION (important): credits_used and duration_seconds were
-- already added to the LIVE database out-of-band (not via a repo migration);
-- frame_count is new. This migration is written to be a NO-OP for the two
-- pre-existing columns and to add only what's missing:
--   * ADD COLUMN IF NOT EXISTS — re-adding an existing column is skipped.
--   * Each CHECK is added inside a DO block guarded on pg_constraint, since
--     Postgres has no ADD CONSTRAINT IF NOT EXISTS — so a constraint the live DB
--     may already carry is not duplicated, and a fresh DB gets it once.
-- The whole file is therefore idempotent: safe to apply to the live DB (where it
-- only adds frame_count + any missing checks) and to a clean DB (where it adds
-- all three).
-- =============================================================================

alter table public.generation_log
  add column if not exists credits_used     integer,
  add column if not exists duration_seconds numeric,
  add column if not exists frame_count      integer;

-- Non-negative guards. ADD CONSTRAINT is not IF-NOT-EXISTS-able, so each is
-- wrapped in a pg_constraint existence check — a no-op if the live DB already
-- carries it, added once on a clean DB.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'generation_log_credits_used_nonneg'
  ) then
    alter table public.generation_log
      add constraint generation_log_credits_used_nonneg check (credits_used >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'generation_log_duration_seconds_nonneg'
  ) then
    alter table public.generation_log
      add constraint generation_log_duration_seconds_nonneg check (duration_seconds >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'generation_log_frame_count_nonneg'
  ) then
    alter table public.generation_log
      add constraint generation_log_frame_count_nonneg check (frame_count >= 0);
  end if;
end
$$;

-- Column-level documentation — non-content calibration metadata (§14.5).
comment on column public.generation_log.credits_used is
  'Calibration metadata (§14.5-compatible, non-content): credits actually charged for this generation. NULL on failure rows / pre-Phase-3 rows.';
comment on column public.generation_log.duration_seconds is
  'Calibration metadata (§14.5-compatible, non-content): recording length in seconds (Whisper-measured). NULL when unmeasured.';
comment on column public.generation_log.frame_count is
  'Calibration metadata (§14.5-compatible, non-content): number of keyframes sent. NULL on pre-Phase-3 rows.';
