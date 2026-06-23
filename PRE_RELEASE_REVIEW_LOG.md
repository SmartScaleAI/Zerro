# Zerro — Pre-Release Review Log

Running log of every bug, improvement, and issue found during the pre-launch
codebase review. Each section of the codebase is reviewed by Claude Code against
a dedicated handoff prompt; findings are triaged here so we can prioritize
before releasing to users.

**Started:** 2026-06-22 · **Status:** in progress

---

## How to use this log

1. Run the handoff prompt for a section in Claude Code (against this repo).
2. Paste the returned report back into the orchestrating chat.
3. The orchestrator reviews the report, de-duplicates, and appends confirmed
   findings to the **Master findings table** below with a stable ID.
4. We re-triage `Priority` as a batch once all sections are in.

## Legend

**Priority**
- 🔴 **Launch-blocker** — must be fixed (or consciously accepted) before release.
- 🟡 **Post-launch** — should fix, but does not block the first release.
- ⚪ **Watch / confirm** — needs investigation to decide; may be intentional.

**Type:** `Security` · `Payments` · `Cost` · `Functionality` · `Performance` ·
`Privacy` · `Reliability` · `Distribution` · `UX` · `Code quality`

**Severity:** `High` / `Medium` / `Low` (impact × likelihood)

**Status:** `Open` · `Confirmed` · `In progress` · `Fixed` · `Won't fix` · `Accepted`

---

## Section index

| ID | Section | Status | Findings |
|----|---------|--------|----------|
| A | Payments & billing backend (LemonSqueezy webhook, session, entitlement) | Not started | – |
| B | Generation proxy — the money path (`generate`, `convert`) | Not started | – |
| C | Trial system, affiliate & anti-abuse (`trial-start`, `affiliate`, agent-models, `feedback`) | Not started | – |
| D | Database: schema, RLS, migrations & advisors | Seeded | 7 |
| E | Desktop billing & entitlement (client) | Not started | – |
| F | Capture & processing pipeline (core + perf + secret redaction) | Not started | – |
| G | Dev Mode / agent runner & git checkpoint | Not started | – |
| H | UI surfaces, onboarding, permissions & accessibility | Not started | – |
| I | App lifecycle, Sparkle updates, observability & Keychain | Not started | – |
| J | Provider adapters & BYOK (Anthropic / OpenAI / Gemini) | Not started | – |
| K | Web app — marketing, auth, checkout & privacy (Next.js) | Not started | – |
| L | Build, release, signing & CI/CD | Not started | – |

---

## Master findings table

| ID | Sec | Title | Type | Sev | Priority | Status | Source | Notes |
|----|-----|-------|------|-----|----------|--------|--------|-------|
| D-01 | D | `refresh_agent_models_cron()` and `rls_auto_enable()` are `SECURITY DEFINER` and executable by `anon`/`authenticated` via `/rest/v1/rpc/...` | Security | High | ⚪ confirm → likely 🔴 | Open | Supabase security advisor | Anyone unauthenticated can invoke these over REST. `refresh_agent_models_cron` could trigger provider/cron work (cost/abuse); `rls_auto_enable` mutating RLS from anon is dangerous. Revoke `EXECUTE` from `anon`/`authenticated` or switch to `SECURITY INVOKER`. Verify intent. |
| D-02 | D | 11 functions have a mutable `search_path` | Security | Low | 🟡 | Open | Supabase security advisor | `set_updated_at`, `consume_credit`, `check_rate_limit`, `acquire/release_generation_slot`, `consume_trial_credit`, `acquire/release_trial_slot`, `verify_trial_grant`, `prune_idempotency_cache`. Set `search_path = ''` (or pin schema) to prevent search-path hijack. Low risk since service-role-only, but cheap hardening. |
| D-03 | D | Extension `pg_net` installed in `public` schema | Security | Low | 🟡 | Open | Supabase security advisor | Move to a dedicated schema. |
| D-04 | D | 14 tables have RLS enabled but no policies | Security | Low | ⚪ confirm | Open | Supabase security advisor | Appears intentional (deny-by-default; all access is service-role which bypasses RLS). Confirm no table is meant to be read by `anon`/`authenticated`, then accept. Tables: affiliate_referrals, agent_models, generation_log, generation_slots, idempotency_cache, pending_license_keys, rate_limits, subscriptions, topup_credits, trial_codes, trial_generation_slots, trial_grants, usage_periods, webhook_events. |
| D-05 | D | 4 unused indexes | Performance | Low | 🟡 | Open | Supabase performance advisor | `subscriptions_ls_customer_id_idx`, `subscriptions_trial_grant_id_idx`, `trial_codes_expires_at_idx`, `affiliate_referrals_ip_recent`. Likely just low traffic so far — re-check after launch before dropping. |
| A/B/C-00 | A,B,C | All edge functions deployed with `verify_jwt = false` | Security | – | ⚪ confirm | Open | Supabase edge function config | By design — each function self-authenticates (webhook signature, session JWT, trial token). Each section must confirm its function actually enforces auth and there is no unauthenticated bypass. |
| K-00 | K | `apps/web/.env.local` is untracked but absent from `.gitignore` | Security | Medium | 🟡 | Open | Orchestrator repo scan | Not currently committed, but a stray `git add -A` would commit web secrets. Add `.env*.local` (and review what keys live there) to `.gitignore`. |

> IDs use `<Section>-<NN>`. Add new rows as reports come in. Keep one row per
> distinct issue; note duplicates instead of re-adding.

---

## Per-section notes

Detailed report excerpts and orchestrator commentary per section go here as the
review progresses.

### Section D — Database, RLS, migrations & advisors
Seeded from live Supabase advisors (project `wjxqmurgwyxwkezncxke`, 2026-06-22).
Full file-level review still pending via the Section D handoff prompt.
