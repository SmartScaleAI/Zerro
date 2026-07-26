# Deploy runbook — multi-model credits launch

The ordered steps to ship the multi-model credit system (Phases 0–6 + the
yearly-refresh job) to production. Sources: implementation-plan Appendix D
(rollout decisions) + Appendix E (tracked items) + the LS dashboard work in
`LEMONSQUEEZY-SETUP-CHECKLIST.md`. Generic deploy reference:
`README-backend.md` → "Deploy".

**Why this order:** the backend is backward-compatible with the shipped app (a
request without `model` runs the recommended default), so backend-first is
safe; the app build goes last and the window between them should be short (D1
below).

---

## 1. Apply migrations to prod

> If the hosted project restricts extension creation to the dashboard, enable
> **pg_cron** first (Dashboard → Database → Extensions) — migration
> `20260611120000` runs `create extension if not exists pg_cron`, which then
> no-ops.

```bash
supabase link --project-ref <prod-project-ref>
supabase db push
```

New since the last prod push (idempotent to re-list; `db push` applies only
what's missing):

- `20260609120000_multi_model_credits.sql` — model/provider columns, two-bucket
  variable `consume_credit`/`consume_trial_credit`, `topup_credits`,
  `billing_interval`
- `20260610120000_idempotency_credits_charged.sql` — `credits_charged` in the
  idempotency cache
- `20260611120000_yearly_credit_refresh.sql` — `refresh_yearly_credit_periods()`
  + hourly pg_cron job

## 2. Deploy the edge functions

```bash
supabase functions deploy lemonsqueezy-webhook --no-verify-jwt
supabase functions deploy session              --no-verify-jwt
supabase functions deploy entitlement          --no-verify-jwt
supabase functions deploy generate             --no-verify-jwt
supabase functions deploy trial-start          --no-verify-jwt
supabase functions deploy convert              --no-verify-jwt
supabase functions deploy feedback             --no-verify-jwt
supabase functions deploy refresh-agent-models --no-verify-jwt
supabase functions deploy agent-models         --no-verify-jwt
supabase functions deploy affiliate            --no-verify-jwt
```

`--no-verify-jwt` is REQUIRED on all ten (see README-backend.md → "Why
`--no-verify-jwt`"). The full current function set is the ten in
`supabase/config.toml` — deploy them all so a runbook-driven redeploy can't
leave a function on stale code.

## 3. Set / confirm prod secrets

New or changing for this launch (the full table is in README-backend.md):

```bash
supabase secrets set \
  ANTHROPIC_API_KEY="<live Anthropic key>" \
  LS_VARIANT_PRO="<live monthly id>,<live yearly id>" \
  LS_VARIANT_YEARLY="<live yearly id>" \
  LS_VARIANT_TOPUP_BOOST="<live Boost variant id>" \
  LS_VARIANT_TOPUP_POWER="<live Power variant id>" \
  LEMONSQUEEZY_WEBHOOK_SECRET="<rotated LIVE webhook secret — step 5>"
```

Confirm already set: `OPENAI_API_KEY` (always required — Whisper),
`GEMINI_API_KEY` (**required** — the recommended default `gemini-3.5-flash` is
Gemini, so default-model requests fail without it), `SESSION_JWT_SECRET`,
`RESEND_API_KEY`, `LEMONSQUEEZY_API_KEY`. The variant IDs above must be **live
mode** IDs — test-mode IDs differ.

### 3a. API-key separation — prod vs dev (rate-limit hygiene)

Provider rate limits are enforced at the **account/organization** level, so a
development or test burst on a key that shares prod's pool can degrade live
users. (Anthropic specifically enforces an **acceleration limit** — 429s on a
sharp usage spike even under the steady ITPM/RPM ceilings — which a burst eval
run trips easily.) A separate key alone does **not** always isolate the limit; a
separate **project/workspace with its own rate cap** does. This applies to all
three providers.

Production keys belong **only** in the deployed Supabase secrets (step 3) and
are never exported into a local shell. Mint a **separate, rate-capped dev key**
per provider:

- **Anthropic** — create a second **workspace** in the Console, set a
  per-workspace rate limit (org limits are shared, so a bare second key in the
  default workspace does *not* isolate them), and mint the key inside it.
- **OpenAI** — mint the dev key in a separate **project** with its own limits.
  (OpenAI is also used in prod for Whisper STT, so this protects transcription
  too.)
- **Gemini** — mint the dev key in a separate **Google Cloud project**, which
  carries its own quota.

Each dev key is used in two places:

- **Local backend** — in `supabase/.env.local` as `OPENAI_API_KEY` /
  `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` (gitignored; only the deployed secrets
  serve real users).
- **Eval harness** — exported as `OPENAI_API_KEY_DEV` / `GEMINI_API_KEY_DEV` /
  `ANTHROPIC_API_KEY_DEV`. `eval-models.mjs` **requires** the relevant `*_DEV`
  var and hard-stops if it is unset; it never falls back to a production key. The
  harness also ramps gently (default `--concurrency 2`, exponential backoff
  honoring `Retry-After`) so even the dev keys don't trip acceleration limits.

## 4. Verify pg_cron landed

After `db push`:

```sql
select jobname, schedule, active from cron.job
where jobname = 'refresh-yearly-credits';
-- expect: refresh-yearly-credits | 0 * * * * | t
```

If the row is missing, pg_cron wasn't enabled when the migration ran — enable
the extension and re-run the `cron.schedule` statement from
`20260611120000_yearly_credit_refresh.sql`. **Without this job, yearly
subscribers get credits at signup and then nothing for 12 months** — do not
sell yearly until the row exists.

## 5. LemonSqueezy dashboard (live mode)

Full detail in `LEMONSQUEEZY-SETUP-CHECKLIST.md`; the launch actions:

1. **Live webhook events** — the live webhook must subscribe to **all 11**
   events the code handles, including `order_created` + `order_refunded`.
   `order_created` was missing on the test webhook and top-ups silently didn't
   credit — verify it on LIVE or real top-ups won't credit.
2. **Rotate the live webhook signing secret** and set the rotated value as
   `LEMONSQUEEZY_WEBHOOK_SECRET` (step 3).
3. **Reprice BYOK to $69** one-time, "includes 1 year of updates" terms.
4. **Create the yearly Managed variant** ($144/yr) → its id goes into BOTH
   `LS_VARIANT_PRO` (comma-separated with monthly) and `LS_VARIANT_YEARLY`.
5. **Create Boost ($10/200) + Power ($22/500)** one-time products → ids into
   the `LS_VARIANT_TOPUP_*` secrets, checkout URLs into the app's
   `BillingLinks.swift` (ships with the app build, step 6).
6. **Update the app's paywall price literals if LemonSqueezy prices changed**
   (E-05) — the app renders hardcoded DISPLAY prices; LemonSqueezy is the
   source of truth for the actual charge, and nothing keeps the labels in
   sync. Any LS price change (now or later) must update, in the same app
   release:
   - `apps/desktop/Zerro/Surfaces/Paywall/PaywallView.swift` — the `Price`
     enum ($69 one-time / $15/mo / $144/yr) and the Managed card subtitle's
     "$12/mo if you choose yearly billing".
   - `apps/desktop/Zerro/Surfaces/Settings/Sections/BillingSection.swift` —
     the two "$15/month, or $12/month …" subtitle strings.
   `grep -rn '\$1[25]/mo\|\$69\|\$144' apps/desktop/Zerro` finds them all.

## 6. Ship the app build (Phase 6)

Release the multi-model app build via Sparkle (appcast). Keep the
backend-to-app window short — most users auto-update.

**Every app release:** add the new version's entry to the TOP of
`apps/desktop/Zerro/WhatsNew/Changelog.swift` in the same PR that bumps
`VERSION` / `CFBundleShortVersionString`. The in-app "What's New" window
auto-pops once per version update, but ONLY when the current version has an
entry — a release without one silently skips the pop (defensive guard in
`WhatsNewPolicy`), so forgetting this means users never see that version's
notes. And because `ZerroApp` advances the last-seen marker even when the pop
is suppressed, a forgotten entry can NOT be fixed retroactively for users who
already updated — the notes have to ride the next version bump (this is
exactly how 1.4.24–1.4.28 shipped silent).

**This step is now CI-enforced** by
`apps/desktop/Scripts/check_changelog_entry.py` (it reuses the Slack script's
entry parser, so the gate and the notification always agree):

- `auto-release.yml` runs it before creating the `app-v*` tag — a VERSION bump
  merged to `main` without a matching `Changelog.swift` entry fails there and
  no release starts.
- `release-app.yml` runs it again before the Xcode build, covering hand-pushed
  tags and `workflow_dispatch` re-runs.
- `Scripts/cut-release.sh` and `Scripts/release.sh` run it as a local
  preflight.

**Intentional internal-only release** (no user-facing changes, no entry
wanted): put `[no-changelog]` in the promotion PR title (it lands in the merge
commit message CI checks), or set `ZERRO_ALLOW_NO_CHANGELOG=1` when running
the local scripts. The Slack post's ⚠️ flag line still appears for such
releases — that's now the confirmation of an intentional skip, not the only
detection.

**Release-note callouts (required):**

- **D1 — Managed users on an old app build:** an un-updated app sends no
  `model`, so generations default to Gemini 3.5 Flash at **4 credits** (was 1
  credit/generation). Accepted decision — no grandfather rule; updating
  restores their model choice.
- **E5 — Existing BYOK users move off gpt-4o:** the registry has no gpt-4o, so
  an updated BYOK install runs `gpt-5.4-mini` (fallback) or whatever the user
  picks. Same 6 models everywhere by design — call out the behavior change.

**Slack release notification:** every production release (`release-app.yml`)
posts to Slack as its final step, and the post always fires. The message lists
**all app changes** in the release (every `apps/desktop/` commit since the
previous `app-v*` tag, from the git log — internal and user-facing alike, so
the team sees everything that shipped) plus the user-facing **What's New**
highlights on top when the version has one, sourced from the SAME
`apps/desktop/Zerro/WhatsNew/Changelog.swift` entry the in-app What's New
window shows (parsed at release time by
`apps/desktop/Scripts/changelog_to_slack.py` — no second copy of the notes).
A release with no `Changelog.swift` entry still posts, with a visible ⚠️ flag
line in the What's New section instead — no build failure; internal-only
releases are expected, and a forgotten entry gets noticed rather than
swallowed. The in-app What's New window is unaffected (still user-facing
only). Requires the `SLACK_RELEASE_WEBHOOK_URL` GitHub Actions repository
secret; when it's unset the step skips silently. The step is best-effort by
design — a Slack hiccup warns but never fails the release.

---

## Pre-launch verification checklist

- [x] LS **test mode**: monthly subscription purchase → `pro`/300 mapping
      confirmed (2026-06-11).
- [x] LS **test mode**: Boost top-up `order_created` → `topup_boost_credited_200`
      confirmed (2026-06-11).
- [ ] LS **test mode**: yearly variant purchase → `billing_interval='yearly'`
      recorded + first 300-credit period opens; after ≥1 month (or with a
      backdated `period_start`), `refresh_yearly_credit_periods()` rolls the
      next period.
- [ ] LS **test mode**: Power top-up purchase → `topup_power_credited_500`.
- [ ] BYOK checkout shows $69 + license key still arrives
      (`license_key_created`).
- [ ] For each test purchase, confirm credits land: `usage_periods` /
      `topup_credits` rows, and `entitlement` returns the expected
      `credits_remaining` / `topup_credits_remaining`.
- [ ] Post-deploy: run `supabase/test/run-curl-tests.sh` against prod.
- [ ] Post-deploy: one real generation on each provider (e.g. `gpt-5.4-mini`,
      `gemini-3.5-flash`, `claude-sonnet-4-6`) → 200 with the right
      `credits_charged`, `generation_log` rows carry model/provider + non-null
      `est_cost_usd`.
- [ ] `cron.job` row verified (step 4).

## Post-launch

- **Price recalibration (plan §2):** after a few hundred multi-model
  generations, query `generation_log` grouped by `model` for real p75
  `est_cost_usd` and retune `creditPrice` in `generate/models.ts` (edit +
  redeploy; no migration). `gpt-5.4-mini` is the likely first retune.
- **Tracked items not in this launch:** E6 (onboarding copy for
  Gemini/Anthropic BYOK keys), E7 (BYOK 1-year update-window enforcement —
  design item; the generation gate does NOT depend on it) — see
  implementation-plan Appendix E. (E1 top-up refund revocation is already in
  the webhook: `order_refunded` zeroes a refunded pack's remaining credits.)
