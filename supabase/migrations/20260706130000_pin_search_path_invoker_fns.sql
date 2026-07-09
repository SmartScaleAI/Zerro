-- D-02: pin search_path on the 10 legacy SECURITY INVOKER functions (advisor 0011).
-- Verified against live definitions: every one fully schema-qualifies its table
-- references (public.<table>) and uses only pg_catalog builtins, and pg_catalog is
-- always implicitly searched even with an empty search_path — so `SET search_path
-- = ''` is BEHAVIOR-PRESERVING (nothing resolves via the caller's mutable path
-- today). Matches the already-hardened 2-arg consume_credit / consume_trial_credit
-- overloads (which already SET search_path TO '').
--
-- NOTE: consume_credit(uuid) and consume_trial_credit(uuid) are the dead 1-arg
-- overloads slated for removal in A-10; pinning them now clears the advisor in the
-- meantime and is harmless if they're later dropped.
--
-- Idempotent + replay-safe: ALTER FUNCTION ... SET search_path is a no-op when
-- already set; on a fresh replay these functions exist (created by earlier
-- migrations) before this runs.

alter function public.acquire_generation_slot(uuid, integer)  set search_path to '';
alter function public.acquire_trial_slot(uuid, integer)        set search_path to '';
alter function public.check_rate_limit(text, integer, integer) set search_path to '';
alter function public.consume_credit(uuid)                     set search_path to '';
alter function public.consume_trial_credit(uuid)               set search_path to '';
alter function public.prune_idempotency_cache(integer)         set search_path to '';
alter function public.release_generation_slot(uuid)            set search_path to '';
alter function public.release_trial_slot(uuid)                 set search_path to '';
alter function public.set_updated_at()                         set search_path to '';
alter function public.verify_trial_grant(text, integer, text)  set search_path to '';
