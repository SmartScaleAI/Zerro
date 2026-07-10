-- =============================================================================
-- A-10 — drop the dead 1-arg consume_credit / consume_trial_credit overloads
-- =============================================================================
-- The original single-credit spend primitives (billing_schema /
-- billing_trial_credits) were superseded by the 2-arg (uuid, integer) versions
-- (multi_model_credits) and then by the *_overspend variants the generate /
-- convert proxies actually call. Verified dead before dropping (2026-07-09):
--   * no edge function calls rpc("consume_credit") / rpc("consume_trial_credit")
--     — the live spend paths are consume_credit_overspend,
--       consume_trial_credit_overspend and consume_combined_credit_overspend;
--   * no SQL function, view, trigger, seed, or test invokes the 1-arg form
--     (the yearly-refresh test calls the 2-arg consume_credit(uuid, integer));
--   * 20260706130000_pin_search_path_invoker_fns.sql already documented them as
--     "the dead 1-arg overloads slated for removal in A-10".
--
-- Their grants (billing_grants / billing_trial_credits) drop with the
-- functions, and the D-02 search_path pin on them becomes moot. The 2-arg
-- versions and every other spend primitive are untouched. Fresh-replay order is
-- safe: create → grant → pin (all in earlier migrations) → this drop.
--
-- IDEMPOTENT: `drop function if exists` — a re-apply is a no-op.
-- =============================================================================

drop function if exists public.consume_credit(uuid);
drop function if exists public.consume_trial_credit(uuid);
