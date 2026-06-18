# Zerro billing backend (Supabase) — deploy & operate

This `supabase/` directory is the **server-side mirror of subscription state** for
Zerro's Managed tier (Phase D1). LemonSqueezy is the system of record for who
paid; Postgres here is a fast local mirror kept current by LemonSqueezy
webhooks, so the runtime can authorize a generation without calling LemonSqueezy
on every request.

**Scope (D1 + D2 + F + multi-model):** D1 built the data layer + the
`lemonsqueezy-webhook` receiver + the `session` / `entitlement` read endpoints.
**D2 adds the `generate` proxy** — the server-side counterpart that holds the
provider API keys (OpenAI, Gemini, Anthropic), transcribes audio + composes the
prompt server-side, enforces input limits + credits, and returns the generated
prompt. `generate` is the only function that touches a model provider; it can
never be bypassed to spend money without a valid identity **and** an available
credit. **Phase F adds `trial-start`** — an email-gated, server-funded **trial**
path: a trial user (no API key of their own) verifies an email with a 6-digit
code and receives a capped credit grant (default 40) keyed to that email, then
their generations route through the SAME `generate` proxy on a `kind:"trial"`
token (decrementing `trial_grants` instead of a subscription period). The cap is
enforced server-side per verified email, so delete+reinstall can't farm fresh
credits. **The multi-model phases (0–6) add the model registry**: the app picks
one of 6 models per generation, each with a fixed credit price, plus one-time
top-up credit packs and a yearly billing interval — see "Model registry + credit
pricing" and "Yearly subscriptions" below.

Design of record: `Documents/zerro-billing-plan.md` (§6.2, §6.3, §9/§9.1, §14)
and `Documents/zerro-billing-implementation-plan.md` (Phase D).

---

## What got built

```
supabase/
  config.toml                         # verify_jwt=false for all 3 functions (see notes)
  migrations/
    20260601120000_billing_schema.sql        # tables + consume_credit() + check_rate_limit()
    20260601120100_billing_rls.sql           # RLS deny-by-default on every table
    20260601120200_billing_grants.sql        # explicit table + EXECUTE grants (service role only)
    20260601120300_billing_generate_slots.sql # D2: generation_slots + acquire/release (concurrency cap)
    20260601120400_billing_trial_credits.sql # F: trial_codes, verify_trial_grant(), consume_trial_credit(),
                                             #    trial_generation_slots (per-grant cap of 1)
    20260605120000_billing_idempotency.sql   # M1: idempotency_cache — one charge per recording across retries
    20260609120000_multi_model_credits.sql   # multi-model: generation_log model/provider cols; variable
                                             #    two-bucket consume_credit(uuid,int) + consume_trial_credit(uuid,int);
                                             #    topup_credits table; subscriptions.billing_interval
    20260610120000_idempotency_credits_charged.sql # D2: idempotency_cache.credits_charged (exact spend
                                             #    replayed in the app's "−N credits" toast on retry)
    20260611120000_yearly_credit_refresh.sql # E2: refresh_yearly_credit_periods() + hourly pg_cron job
    20260618120000_agent_models.sql          # Dev Mode: agent_models manifest table (RLS deny-by-default)
    20260618120100_agent_models_cron.sql     # Dev Mode: daily pg_cron → refresh-agent-models (pg_net + Vault)
    20260618130000_agent_models_retire_openai.sql # Dev Mode: delete openai rows (Codex sources its own list)
  functions/
    _shared/                          # env, config, crypto, ls-signature, jwt, db, types,
                                      # entitlement, http  (+ *_test.ts Deno tests)
    lemonsqueezy-webhook/             # signature-verified webhook receiver
    session/                          # license key → short-lived JWT
    entitlement/                      # token → display-only snapshot
    generate/                         # D2: session JWT → transcribe + prompt + chat (multi-provider proxy)
                                      #   handler.ts (flow + Phase F trial branch),
                                      #   models.ts (model registry — see "Model registry" below),
                                      #   providers/ (factory + openai/gemini/anthropic adapters),
                                      #   prompt.ts / interleave.ts (ported, KEEP IN SYNC),
                                      #   limits.ts, cost.ts, config.ts, store.ts (+ handler_test.ts)
    trial-start/                      # F: email + 6-digit code → trial grant + trial token
                                      #   handler.ts (request/verify), email.ts (normalize +
                                      #   disposable block + code gen), resend.ts, store.ts,
                                      #   config.ts (+ handler_test.ts, email_test.ts)
    convert/                          # typed-artifact Phase 6: chat text (+ context) →
                                      #   agent_prompt artifact block. FREE by design: token
                                      #   auth + per-identity rate limit ONLY — no credit
                                      #   check/consume, no slot, no idempotency cache, no
                                      #   generation_log. Imports generate/'s registry +
                                      #   provider adapters read-only. handler.ts, limits.ts,
                                      #   prompt.ts (byte-mirror of Scripts/artifact-eval/
                                      #   convert-prompt-v1.md, enforced by prompt_test.ts),
                                      #   config.ts (+ handler_test.ts)
    refresh-agent-models/             # Dev Mode manifest WRITER (daily cron + manual w/ secret):
                                      #   fetch live Anthropic model list → curate (regex) → rank
                                      #   newest-first → upsert → vanished→inactive sweep. Never
                                      #   wipes on a failed/empty fetch. OpenAI retired (Codex
                                      #   sources its own list). providers.ts, curate.ts, store.ts,
                                      #   refresh.ts, index.ts (+ curate/refresh tests)
    agent-models/                     # Dev Mode manifest READER: public GET, active rows grouped
                                      #   by provider, ordered by rank, 1h Cache-Control. No auth.
                                      #   group.ts, index.ts (+ group_test.ts)
  test/run-curl-tests.sh              # post-deploy verification battery
README-backend.md                     # this file
```

**Tables:** `subscriptions`, `usage_periods`, `topup_credits` (one-time credit
packs, 12-month expiry), `trial_grants` (Phase F grant), `trial_codes` (F:
hashed verification codes), `webhook_events` (idempotency),
`pending_license_keys` (reconciliation buffer for LS's separate license-key
event), `generation_log` (D2/F writes it; carries `model`/`provider` columns —
non-content metadata), `rate_limits` (basic limiter), `generation_slots` (D2
concurrency cap), `trial_generation_slots` (F trial concurrency cap),
`idempotency_cache` (M1: one charge per recording across retries, incl. the
exact `credits_charged`). License keys **and** verification codes are stored
only as a **SHA-256 hash** — never raw.

**Atomic credit primitive:** `consume_credit(subscription_id, credits)` —
spends the model's variable credit price atomically across the TWO buckets:
the subscription's latest plan period first, then non-expired top-up packs
(FIFO by expiry). The conditional updates under row locks are the double-spend
guard; the whole spend succeeds or charges nothing. `generate` calls it only on
a fully successful generation. (`consume_trial_credit(grant_id, credits)` is
the trial-ledger mirror.)

**Concurrency cap (D2):** `acquire_generation_slot` / `release_generation_slot`
+ the `generation_slots` table give each subscriber **at most one in-flight
generation**. That cap is what makes `generate`'s check-then-consume credit
ordering safe (see the `generate` section below). Stale slots (crashed/timed-out
requests) are auto-reclaimed after `GENERATE_SLOT_STALE_SECONDS`.

---

## Secrets

Set with `supabase secrets set NAME=value` (or the dashboard → Edge Functions →
Secrets). **`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by
the runtime — do NOT set them yourself.**

| Secret | Required | What it is |
|---|---|---|
| `SESSION_JWT_SECRET` | ✅ | HS256 signing secret for the short-lived session tokens. Generate a long random string (`openssl rand -hex 32`). |
| `LEMONSQUEEZY_WEBHOOK_SECRET` | ✅ | The signing secret you enter when creating the webhook in LemonSqueezy. The webhook verifies `X-Signature` against it. |
| `LEMONSQUEEZY_API_KEY` | ⚠️ **G** | A LemonSqueezy **API key** (Settings → API), distinct from the webhook secret. Powers the §14.6 **missed-webhook staleness re-check** in `session`: when the mirror is stale, `session` calls `GET /v1/subscriptions/{id}` to confirm the sub is still live before minting. **Unset → the guard is disabled and `session` fails OPEN** (logged); set it before launch so a dropped `cancelled` webhook can't keep minting tokens forever. |
| `SESSION_STALENESS_SECONDS` | optional | How stale the mirror may be before `session` does the live re-check (default = `SESSION_TOKEN_TTL_SECONDS`). |
| `LEMONSQUEEZY_API_BASE` | optional | Override of the LS API base URL (default `https://api.lemonsqueezy.com/v1`). Only for testing against a stub; never set in prod. |
| `LS_VARIANT_STARTER` | ⚠️ Phase E | **Comma-separated list** of LemonSqueezy variant ids → tier `starter`. Until set, an unmapped variant defaults to `starter` (logged). |
| `LS_VARIANT_PRO` | ⚠️ Phase E | Comma-separated variant ids → tier `pro`. **Put BOTH Managed variants here** — monthly ($15) AND yearly ($144/yr): both map to the same `pro` tier / `CREDITS_PRO` allowance, e.g. `LS_VARIANT_PRO="1735329,1735330"`. |
| `LS_VARIANT_YEARLY` | ⚠️ Phase 5 | Comma-separated ids of the **yearly** variants (any tier, one list). Sets `subscriptions.billing_interval` — metadata only; yearly subs still get the same 300-credit period every 30 days. A mapped variant not listed here records `monthly`; an unmapped variant records `NULL`. |
| `LS_VARIANT_TOPUP_BOOST` | ⚠️ Phase 5 | Comma-separated variant ids of the **Boost** top-up product (one-time order, `order_created`). A matching paid order inserts a `topup_credits` row (`TOPUP_BOOST_CREDITS`, 12-month expiry) for the buyer's active subscription. |
| `LS_VARIANT_TOPUP_POWER` | ⚠️ Phase 5 | Same for the **Power** pack (`TOPUP_POWER_CREDITS`). |
| `TOPUP_BOOST_CREDITS` / `TOPUP_POWER_CREDITS` | optional | Credits per pack (defaults `200` / `500`, plan §1.4). |
| `TOPUP_EXPIRY_MONTHS` | optional | Top-up shelf life from purchase (default `12`). |
| `CREDITS_STARTER` | optional | Starter monthly allowance (default `100`). |
| `CREDITS_PRO` | optional | Pro monthly allowance (default `300`). The Managed plan's "300 credits" = this value. |
| `SESSION_TOKEN_TTL_SECONDS` | optional | Session token lifetime (default `1800` = 30 min). |
| `SESSION_RATE_LIMIT_PER_KEY` / `_PER_IP` / `_WINDOW_SECONDS` | optional | Basic `session` rate limit (defaults `10` / `30` per `60`s). |
| `OPENAI_API_KEY` | ✅ **D2** | The OpenAI key for the `generate` proxy. **Always required** — Whisper STT stays on OpenAI even when chat runs on Gemini. **Lives ONLY here**, read from env in the function — never returned to the client, never logged. |
| `GEMINI_API_KEY` | ✅ multi-model | The Gemini key for the 2 Gemini registry models — **including the recommended default `gemini-3.5-flash`**, so in practice this is required: without it, any request that omits `model` (every pre-multi-model app) fails at the provider factory. Lives only here; never returned/logged. |
| `ANTHROPIC_API_KEY` | ✅ multi-model | The Anthropic key for the 2 Claude registry models. A request selecting a Claude model without it fails clearly at the provider factory (other models unaffected). STT still always needs `OPENAI_API_KEY` (Whisper). Lives only here; never returned/logged. |
| `STT_PROVIDER` | optional | Transcription provider (default `openai`). Only `openai` is supported this phase (the interleaver needs segment-level timestamps). |
| `STT_MODEL` | optional | Transcription model (default `whisper-1`). Swap server-side without an app update. |
| `CHAT_PROVIDER` | optional, legacy | Pre-multi-model default-provider knob (`openai` default / `gemini` / `anthropic`). Since the model registry (Phase 4), **the model is selected per request** and routing ignores this; its remaining effect is which chat key is hard-required at boot. Leave at the default. |
| `CHAT_MODEL` | optional, legacy | Pre-multi-model default model (default `gpt-4o`). **No longer routes Managed generations** — a request without `model` runs the registry's recommended entry (`gemini-3.5-flash`), see "Model registry" below. |
| `GEMINI_THINKING_LEVEL` | optional | Gemini thinking depth — `low` (default) or `high`. Applies to Gemini-model generations. `high` adds latency + billed thinking (output) tokens; the rewrite task rarely needs it. |
| `GENERATE_MAX_AUDIO_SECONDS` / `_MAX_AUDIO_BYTES` / `_MAX_FRAMES` / `_MAX_PAYLOAD_BYTES` | optional | Input fuse (defaults `300`s / `12`MB / `200` / `60`MB). Set generously above any real recording; lower against measured cost. |
| `GENERATE_MAX_OCR_TEXT_CHARS` / `_MAX_CLICKS` / `_MAX_CLICK_LABEL_CHARS` | optional | Phase 3 input fuse for the context channels: per-frame `ocr_text` cap (default `8192` chars) and click-event caps (defaults `200` clicks / `200` chars per label). Same posture as the other fuses — generous, reject only forged/bloated payloads. |
| `GENERATE_IDEMPOTENCY_TTL_SECONDS` | optional | How long a completed generation's response (incl. `credits_charged`) is replayable from `idempotency_cache` for the same idempotency key (default `900`). Covers app-side retries of an already-charged recording without double-charging. |
| `GENERATE_CIRCUIT_BREAKER_MULTIPLIER` | optional | Anti-abuse circuit breaker (default `3`): when a single generation's real estimated cost exceeds `multiplier × model price` (in dollars), the metered amount is charged instead of the fixed price. Normal users never trigger it. |
| `GENERATE_SLOT_STALE_SECONDS` | optional | Concurrency-slot stale-reclaim window (default `180`s; must exceed worst-case provider round-trip). |
| `GENERATE_RATE_LIMIT_PER_SUB` / `_WINDOW_SECONDS` | optional | Per-subscriber `generate` rate limit (defaults `20` per `60`s). |
| `GENERATE_PROVIDER_TIMEOUT_MS` | optional | Provider request timeout (default `120000`). Falls back to the legacy `GENERATE_OPENAI_TIMEOUT_MS` if the new var is unset, so a tuned deployment keeps its value. |
| `CONVERT_RATE_LIMIT_PER_IDENTITY` / `_WINDOW_SECONDS` | optional | `convert` per-identity rate limit (defaults `10` per `60`s) — the free endpoint's ONLY quantitative gate. Input caps are `CONVERT_MAX_{PAYLOAD_BYTES,SOURCE_CHARS,CONTEXT_CHARS}`. |
| `RESEND_API_KEY` | ✅ **F** | Resend API key for sending the trial verification code email. The new secret `trial-start` requires. Lives only here; never returned/logged. |
| `TRIAL_CREDITS` | optional | The per-email trial credit grant (default `40`, multi-model plan §1.3). Tunable without a logic change. |
| `TRIAL_EMAIL_FROM` | optional | The verified getzerro.app sender (default `Zerro <noreply@getzerro.app>`). Must be a domain verified in Resend. |
| `TRIAL_CODE_TTL_SECONDS` | optional | Verification-code lifetime (default `600` = 10 min). |
| `TRIAL_CODE_MAX_ATTEMPTS` | optional | Max verify tries per issued code before it's burned (default `5`). |
| `TRIAL_TOKEN_TTL_SECONDS` | optional | Trial session-token lifetime (default `1800` = 30 min). |
| `TRIAL_RATE_LIMIT_PER_EMAIL` / `_PER_IP` / `_WINDOW_SECONDS` | optional | `trial-start` rate limits (defaults `8` / `30` per `3600`s). |
| `REFRESH_CRON_SECRET` | ✅ **Dev Mode manifest** | Shared secret guarding `refresh-agent-models`. The function rejects any POST whose `x-refresh-secret` header ≠ this value (constant-time). Set it as an Edge secret **and** seed the SAME value into Vault as `refresh_cron_secret` so the daily cron can read it (see "Dev Mode model manifest" below). Generate: `openssl rand -hex 32`. The `agent-models` read function needs no secret (public). `refresh-agent-models` reuses the existing `ANTHROPIC_API_KEY` to fetch the Anthropic model list (OpenAI is retired — Codex sources its own per-account list client-side). |

---

## Deploy

> **Shipping the multi-model launch?** Follow `docs/DEPLOY-RUNBOOK.md` — it
> sequences these steps with the LemonSqueezy dashboard work, pg_cron
> verification, and the release-note callouts. This section is the generic
> reference.

```bash
# One-time: link the local dir to your Supabase project (Pro — free tier
# auto-pauses and is unsuitable for a live paywall backend).
supabase link --project-ref <your-project-ref>

# 1. Apply the schema + RLS migrations. NOTE: 20260611120000 enables pg_cron —
#    if the hosted project locks extensions to dashboard management, enable
#    pg_cron under Database → Extensions FIRST, then verify the cron.job row
#    landed (see "Yearly subscriptions" above).
supabase db push

# 2. Set the secrets (see table above).
supabase secrets set SESSION_JWT_SECRET="$(openssl rand -hex 32)"
supabase secrets set LEMONSQUEEZY_WEBHOOK_SECRET="<paste the LS webhook secret>"
supabase secrets set OPENAI_API_KEY="<your OpenAI key>"   # D2 — generate proxy + Whisper (always required)
supabase secrets set GEMINI_API_KEY="<your Gemini key>"   # multi-model — Gemini registry models
supabase secrets set ANTHROPIC_API_KEY="<your Anthropic key>"  # multi-model — Claude registry models
supabase secrets set RESEND_API_KEY="<your Resend key>"   # F  — trial-start email
supabase secrets set LEMONSQUEEZY_API_KEY="<your LS API key>"  # G — staleness re-check
# Phase E: supabase secrets set LS_VARIANT_STARTER=... LS_VARIANT_PRO="<monthly-id>,<yearly-id>"
# Phase F (optional): supabase secrets set TRIAL_CREDITS=40 TRIAL_EMAIL_FROM="Zerro <noreply@getzerro.app>"
# Phase 5: supabase secrets set LS_VARIANT_YEARLY="<yearly-id>" \
#          LS_VARIANT_TOPUP_BOOST="<boost-variant-id>" LS_VARIANT_TOPUP_POWER="<power-variant-id>"

# 3. Deploy the six functions. --no-verify-jwt is REQUIRED on all six
#    (see "Why --no-verify-jwt" below). config.toml already encodes this, but
#    pass the flag explicitly so a config drift can't silently re-enable the
#    gateway JWT gate.
supabase functions deploy lemonsqueezy-webhook --no-verify-jwt
supabase functions deploy session             --no-verify-jwt
supabase functions deploy entitlement          --no-verify-jwt
supabase functions deploy generate            --no-verify-jwt
supabase functions deploy trial-start         --no-verify-jwt
supabase functions deploy convert             --no-verify-jwt
# Dev Mode model manifest (see "Dev Mode model manifest" below):
supabase functions deploy refresh-agent-models --no-verify-jwt
supabase functions deploy agent-models         --no-verify-jwt
```

**Phase F also needs a verified sender domain in Resend** (`getzerro.app`, or
whatever `TRIAL_EMAIL_FROM` uses) so the verification email isn't rejected /
spam-filed. Add + verify the domain in the Resend dashboard before going live.

### Why `--no-verify-jwt` on every function

`verify_jwt` controls whether the **Supabase API gateway** demands a
Supabase-issued JWT before the function runs. Every function needs it **off**,
for different reasons:

- **lemonsqueezy-webhook** — LemonSqueezy sends no Supabase JWT. Security is the
  `X-Signature` HMAC check (raw body, constant-time), done in code.
- **session** — the credential is the **license key**, not a Supabase JWT.
  Security is the per-key/per-IP rate limit + key-hash lookup.
- **entitlement** / **generate** / **convert** — each verifies **our own**
  session JWT (HS256, `SESSION_JWT_SECRET`) **in code**. If the gateway also
  tried to verify a JWT, it would reject the app's token before our code runs.
  So the gateway gate is off and the in-code verify is the real gate.
- **trial-start** (Phase F) — an **unauthenticated public** endpoint: the user is
  mid-trial with no credential yet. Security is the per-email/per-IP rate limit +
  a hashed, TTL'd, attempt-limited code + a disposable-domain block + the
  one-grant-per-email cap, all in code.
- **refresh-agent-models** (Dev Mode manifest) — the caller is the daily pg_cron
  job (server-side `net.http_post`), not an app with a Supabase JWT. Security is
  the shared `REFRESH_CRON_SECRET` checked in code against the `x-refresh-secret`
  header; the gateway gate is off so that header reaches our code.
- **agent-models** (Dev Mode manifest) — a **public** read of public model ids
  (no credential, no user data). The app reads it at launch with no session, so
  there is nothing to verify; the write path stays service-role-only via RLS.

---

## Register the webhook in LemonSqueezy

LemonSqueezy dashboard → **Settings → Webhooks → +**:

- **Callback URL:**
  `https://<your-project-ref>.supabase.co/functions/v1/lemonsqueezy-webhook`
- **Signing secret:** the same value you set as `LEMONSQUEEZY_WEBHOOK_SECRET`.
- **Events to enable (all 11):** `subscription_created`, `subscription_updated`,
  `subscription_payment_success`, `subscription_payment_failed`,
  `subscription_payment_recovered`, `subscription_payment_refunded`,
  `subscription_cancelled`, `subscription_expired`, `license_key_created`,
  **`order_created`** (top-up pack purchases — a paid order whose variant is in
  `LS_VARIANT_TOPUP_BOOST`/`_POWER` inserts a `topup_credits` row), and (for
  revocation) `order_refunded`.

### Heads-up: the license key arrives in its OWN event

LemonSqueezy does **not** put the license key in the subscription payload. It
fires a separate **`license_key_created`** event whose `attributes.key` is the
raw key. The webhook hashes it and links it to the subscription by **order id**
(`pending_license_keys` covers the case where it arrives before
`subscription_created`). This is why `license_key_created` must be enabled — the
`session` endpoint can't find a subscriber without it.

### Idempotency key

LemonSqueezy ships **no guaranteed-unique event id**, and the raw body is **not**
guaranteed byte-unique across two distinct events — so the dedupe key is a
**composite**: `event_name : data.id : attributes.updated_at`, stored in
`webhook_events`. For payment events `data.id` is the (globally unique) invoice
id; for subscription events it's the subscription id distinguished by
`updated_at`. A true redelivery shares all three → deduped; two distinct events
differ in `data.id` and/or `updated_at` → never wrongly merged.

### Payment events carry an *invoice*, not a subscription

`subscription_payment_success` / `_failed` / `_recovered` / `_refunded` carry a
`subscription-invoices` resource: `data.id` is the **invoice** id and the
subscription is `data.attributes.subscription_id`. The webhook resolves the
mirror row via `subscription_id` for those events. Only a **renewal** invoice
(`billing_reason = "renewal"`) rolls a fresh period / resets credits; `initial`
is owned by `subscription_created`, and `updated` (mid-cycle) does not reset.

---

## Yearly subscriptions: the monthly credit-refresh job

**Why it exists.** LemonSqueezy bills a yearly subscription **once a year**, so
the renewal webhook (`subscription_payment_success`, `billing_reason:
"renewal"`) fires annually — but a yearly Managed subscriber is sold "300
credits **per month**". Without a scheduler, a yearly sub would get credits at
signup and then nothing for 12 months (Appendix E2; this was confirmed against
LS docs before yearly went on sale).

**What it does.** `refresh_yearly_credit_periods()` (migration
`20260611120000_yearly_credit_refresh.sql`) rolls a fresh `CREDITS_PRO` usage
period every month for each `active`/`past_due` subscription with
`billing_interval = 'yearly'`. Anchors derive from the latest
`usage_periods.period_start + 1 month` (catching up month-by-month if runs were
missed), and a period is **never** granted at/past
`subscriptions.current_period_end` — the annual renewal webhook owns the year
boundary. It is idempotent two ways: the age gate (a rolled period moves the
next anchor into the future) and the `(subscription_id, period_start)` unique
key, so racing executions can't double-grant. Monthly subs are untouched.

**The pg_cron dependency.** The migration enables `pg_cron` and schedules the
job **`refresh-yearly-credits`** hourly (`0 * * * *`) — hourly only bounds how
stale a month boundary can get; each run is cheap and a same-month re-run rolls
nothing. **Deploy note:** confirm pg_cron is enabled on the hosted project
(Dashboard → Database → Extensions) and verify the job row landed after
`supabase db push`:

```sql
select jobname, schedule, active from cron.job
where jobname = 'refresh-yearly-credits';
```

The displayed "Resets {date}" for yearly subs is computed from the same anchor
arithmetic (E8, `_shared/entitlement.ts`), so the app shows the next *monthly*
refresh, not the annual renewal.

---

## Dev Mode model manifest (`agent_models`)

Lets Dev Mode users pick the **model the coding agent runs** (`--model <id>`)
from a list of **current, pinned models that stays fresh on its own**. A server
job fetches the live provider model lists into Postgres; the app reads that
manifest. (Cursor is fetched client-side from its own CLI and is NOT in this
table.)

- **`agent_models` table** — `(provider, model_id, display_name, rank, active)`,
  unique on `(provider, model_id)`. RLS deny-by-default; the data is public model
  ids but the **write** path is service-role-only so a user can't poison the list.
- **`refresh-agent-models`** (writer, cron + manual) — fetches
  `GET api.anthropic.com/v1/models` (`x-api-key` + `anthropic-version`) with the
  existing `ANTHROPIC_API_KEY`, **filters to coding chat models** via a stable
  regex (the only curation surface — `refresh-agent-models/curate.ts`:
  `^claude-(opus|sonnet|haiku)-\d` → the live Opus/Sonnet/Haiku set),
  **ranks newest-first** (rank 0 = default pick), upserts, then marks any
  vanished model `active = false`. **A fetch that fails (or returns zero matches)
  leaves the rows untouched — never wiped.** Returns `{ anthropic: n|null,
  errors: [...] }`. Guarded by `REFRESH_CRON_SECRET` (`x-refresh-secret` header,
  constant-time). **OpenAI is retired**: a ChatGPT-account Codex uses its own
  slugs (e.g. `gpt-5.5`) and rejects the OpenAI API codex ids, so Codex sources
  its model list from its OWN per-account tool (`~/.codex/models_cache.json`)
  client-side — the manifest serves Anthropic (Claude Code) only.
- **`agent-models`** (reader, public GET, no auth) — returns active rows grouped
  by provider, ordered by rank, with `Cache-Control: public, max-age=3600`:
  `{ providers: { anthropic: [{ model_id, display_name }], openai: [] } }`
  (openai is always empty post-retirement; the app ignores it).

**The pg_cron + pg_net dependency.** `20260618120100_agent_models_cron.sql`
enables `pg_cron` + `pg_net` and schedules **`refresh-agent-models`** daily
(`0 6 * * *`). The job calls `public.refresh_agent_models_cron()`, which reads
the function URL + secret from **Vault** and POSTs the Edge Function — so no
secret is committed to git. **One-time operator setup** (values are secrets):

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
select vault.create_secret('<REFRESH_CRON_SECRET value>', 'refresh_cron_secret');
```

```bash
supabase secrets set REFRESH_CRON_SECRET="<same value as the Vault secret>"
```

Until Vault is seeded the job logs a skip notice instead of erroring. Verify the
job + a manual run:

```sql
select jobname, schedule, active from cron.job where jobname = 'refresh-agent-models';
-- manual (off the cron): curl -X POST \
--   -H "x-refresh-secret: $REFRESH_CRON_SECRET" \
--   https://<project-ref>.supabase.co/functions/v1/refresh-agent-models
select provider, model_id, display_name, rank, active from public.agent_models order by provider, rank;
```

**Verify the filter regexes against the LIVE ids** after the first real invoke
(provider ids drift) and tune `curate.ts` if a current coding model is missed or
a non-chat SKU slips through. New model versions then appear automatically on the
next daily refresh with no app release.

---

## The `generate` proxy (D2)

`POST /functions/v1/generate`, `Authorization: Bearer <session JWT>`, JSON body =
`{ mode, model, audio, frames, clicks }` — `model` is optional (absent → the
registry's recommended default), frames may carry per-frame `ocr_text`, and
`clicks` is the optional click-event channel (Phase 3). The app sends **inputs
+ two enums only** — **never** a transcript or prompt text, and `model` selects
the provider adapter + credit price ONLY, never the prompt. The server
transcribes and owns the system prompt; that ownership is what stops the
provider keys from being driven as a general-purpose LLM.

**Flow (order is money-safety critical):**

1. Cap the raw body (`MAX_PAYLOAD_BYTES`) before parsing.
2. Verify our session JWT in code → `401` if invalid/expired. `kind` selects the
   credit ledger: `subscription` (D2) or `trial` (Phase F, see below); any other
   kind → `401`.
3. Resolve + authorize the identity. Subscription: load the subscriber;
   `status ∈ (active, past_due)` → continue, else `403` (`past_due` still
   generates on its remaining credits, §9.1). Trial: load the `trial_grants` row
   by the token's grant id; must exist + be verified, else `404`/`403`.
4. **Input fuse** (`limits.ts`) — frame count, MIME allow-lists, audio bytes,
   optional declared duration. Over-limit → `413`/`415`, **before any OpenAI
   call or credit work**. The limits sit well above any real recording; only a
   forged/oversized payload trips them.
5. Per-subscriber rate limit (`check_rate_limit`) → `429`.
6. **Acquire the concurrency slot** (cap = 1) → `429 generation_in_progress` if a
   request is already in flight for this subscriber.
7. **Check** the combined balance (plan + non-expired top-up) covers **the
   selected model's credit price** (no decrement) → `402 out_of_credits` (with
   `model_price`) if not, no provider call.
8. Transcribe (Whisper) → re-apply the **true** `MAX_AUDIO_SECONDS` gate on the
   measured duration before the expensive chat call → compose the server-owned
   system prompt + interleave frames/transcript/clicks → call chat on the
   selected model via its provider adapter.
9. **On a fully usable result only:** `consume_credit(sub, credits)` atomically —
   usually the model's fixed price; the circuit breaker (see "Model registry")
   charges metered cost instead on a pathological generation.
10. Log token counts + cost + model/provider + success to `generation_log`;
    release the slot; return `{ prompt, usage, credits_remaining,
    credits_charged }` — `credits_charged` is the exact spend the app shows in
    its "−N credits" toast (replayed verbatim from `idempotency_cache` on a
    retried request, so a retry never re-charges or mis-reports).

**Credit ordering — check-then-consume-on-success.** We deduct only on success;
a provider failure (429 / 5xx / timeout) charges nothing and returns a retryable
error (`503`; non-retryable → `502`). The one race this can't see — two
"last credits" requests both passing the availability check and both paying the
provider before either consumes — is removed by the **concurrency cap of 1**
(`generation_slots`): a single subscriber can't have two generations in flight.
`consume_credit()` remains the hard double-spend guard. *Deferred to Phase G:*
reserve-then-commit (reserve the credits before the provider call,
commit/release after) if the cap is ever raised above 1.

**Privacy (§14.5).** Audio, frames, transcript, and the composed prompt are
processed **in memory only** — never persisted, no temp files. `generation_log`
has columns for token counts + cost + success and **nothing else** — there is no
column that could hold content.

**Limits are env-tunable** (see the secrets table): the `GENERATE_MAX_*`
constants are the input fuse — lower them in one place against measured cost
(search `// TODO: tune down` in `generate/config.ts`). `STT_MODEL` swaps the
transcription model server-side; the **chat** model is chosen per request from
the registry below (the legacy `CHAT_PROVIDER`/`CHAT_MODEL` knobs no longer
route Managed generations).

**Provider-agnostic chat.** The `generate` proxy resolves its STT and chat
clients through `generate/providers/factory.ts` (`makeSttClient` /
`makeChatClient`); the chat adapter is built **per request** from the validated
model's provider. STT stays OpenAI Whisper (the interleaver needs segment-level
timestamps), which is why `OPENAI_API_KEY` is always required. The interleaver
emits provider-neutral `TimelineBlock`s; each adapter (`providers/openai.ts`,
`providers/gemini.ts`, `providers/anthropic.ts`) renders its own wire format.
The Swift BYOK path routes across the same three providers since Phase 6,
key-gated per provider in the app.

---

## Model registry + credit pricing (multi-model)

The 6 user-selectable models live in **`generate/models.ts`** — one table of
`{ id, provider, displayName, creditPrice, enabled }` that feeds request
validation (`ALLOWED_MODELS`), provider routing, pricing, and the app's picker.
Credit price is **fixed per model** (plan §1.2; 1 credit = $0.01 of provider
cost, a unit deliberately not env-tunable):

| Model (wire id) | Provider | Credits |
|---|---|---|
| `gpt-5.4-mini` | OpenAI | 2 |
| `gemini-3.5-flash` (recommended + default) | Gemini | 4 |
| `gemini-3.1-pro-preview` | Gemini | 5 |
| `claude-sonnet-4-6` | Anthropic | 7 |
| `claude-opus-4-7` | Anthropic | 10 |
| `gpt-5.5` | OpenAI | 11 |

- **`enabled` is the kill switch.** Flipping it `false` drops the model from
  `ALLOWED_MODELS` (new requests → `400 invalid_model`) — a one-line edit +
  `generate` redeploy; no migration, no app update, no schema change. Use it if
  a provider update regresses a model's output contract.
- **A request without `model`** (pre-multi-model app) runs the recommended
  entry — `gemini-3.5-flash`, 4 credits — NOT the legacy env `CHAT_MODEL`
  (gpt-4o isn't a registry model and has no credit price).
- **`creditCostForModel` applies the circuit breaker:** the fixed price is
  charged unless the generation's real estimated cost exceeds
  `GENERATE_CIRCUIT_BREAKER_MULTIPLIER` (default 3) × the price in dollars, in
  which case the metered amount (`ceil(cost / $0.01)`) is charged instead.
  `credits_charged` in the response makes this visible to the app.
- **No tier-gating:** subscription + trial see all 6 models; BYOK sees all 6
  but each is selectable only with a key for its provider.

**Three synced mirrors (KEEP IN SYNC):** the per-token price table in
`generate/cost.ts` (`CHAT_PRICING`) is mirrored in the eval harness
(`apps/desktop/Scripts/eval-models.mjs`) and the Swift app duplicates the
registry + BYOK cost constants (`Zerro/Services/ModelRegistry.swift`, the BYOK
cost estimator in the OpenAI/Gemini/Anthropic service files). A rate or
registry change must update all of them.

**Calibration caveat (plan §2): the credit prices are calibration-v1
estimates** — real token shape × published June-2026 API rates, validated
against measured Gemini Flash spend and the Phase 0 eval runs. **Post-launch
task:** after a few hundred multi-model generations, query `generation_log`
grouped by `model` for the real p75 `est_cost_usd` and retune each
`creditPrice` (a one-line edit + redeploy; no migration). `gpt-5.4-mini`'s
2-credit price is margin-generous and the likely first retune.

**Prompt/interleaving parity.** `generate/prompt.ts` and
`generate/interleave.ts` are **verbatim ports** of the Swift BYOK path so Managed
output matches. They carry `KEEP IN SYNC with …` markers — **if the Swift prompt
or interleaving changes, update the server copy too**, or Managed and BYOK drift.
The interleaving algorithm and system prompt stay byte-identical across
BYOK/Managed and across chat providers; only the final wire format differs
per-provider (handled in the adapters).

---

## The `trial-start` flow (Phase F)

`POST /functions/v1/trial-start` (no auth — see "Why `--no-verify-jwt`"). One
function, two actions:

**`{ action: "request", email }`** — normalize the email (lowercase + trim; Gmail
dots/`+tags` collapsed so they can't farm the cap), reject disposable domains
(`422`), rate-limit per email + per IP (`429`). If the email already verified and
spent every credit → `{ status: "already_used" }` (no email sent). Otherwise mint
a 6-digit code, store its **SHA-256 hash** with a short TTL (`trial_codes`,
default 10 min, attempts reset to 0), and send it via **Resend** from the verified
`getzerro.app` sender. A Resend failure → `502 { error: "send_failed" }`. Success
→ `{ status: "code_sent" }`.

**`{ action: "verify", email, code }`** — look up the pending code, check TTL +
attempts (expired/over-attempts → burn it), **constant-time compare the hashes**
(a mismatch increments attempts → `400 invalid_code`). On a match: delete the code
(single use) and call `verify_trial_grant(email, TRIAL_CREDITS)` — a
create-once/never-reset upsert on `trial_grants.email_normalized` (so a re-verify
after a reinstall resumes the SAME balance, never a fresh grant). If the grant is
already exhausted → `{ status: "already_used" }`. Otherwise mint a short-lived
**trial session token** (`kind:"trial"`, `sub` = the opaque grant id — the raw
email never travels onward) and return `{ token, expires_at,
trial_credits_remaining, trial_credits_limit }` (the limit is the grant total,
so the app's trial meter has a denominator — E4).

**The `generate` trial branch.** A `kind:"trial"` token resolves the
`trial_grants` row by grant id, then runs the IDENTICAL pipeline as a subscription
(input fuse → per-identity rate limit → concurrency cap of **1** via
`trial_generation_slots` → credit availability → Whisper → true-seconds gate →
chat → **`consume_trial_credit(grant_id, credits)` only on success**, charging
the selected model's price). Same money safety: deduct on success only, a
provider failure charges nothing, over-cap rejects with no charge,
`402 out_of_credits` when the grant can't cover the model's price (the app
drops to the paywall — trial credits exhausted is one of the two trial-expiry
conditions). `consume_trial_credit` is the conditional UPDATE that is the
double-spend guard; the slot cap makes check-then-consume safe exactly as for
subscriptions. Trials see all 6 registry models at the same credit prices.
A trial generation logs to `generation_log` with `subscription_id = null` (no FK;
the cap is enforced on `trial_grants`, not the log).

**`TRIAL_CREDITS`** is the grant size (env, default 40) — tune the trial economics
without a logic change.

---

## Verify (no app needed)

### Unit tests (`_shared` + `generate` + `trial-start`)

```bash
cd supabase/functions
deno test --allow-env --allow-net --allow-read .            # run EVERYTHING (all functions + _shared)
# …or per area:
deno test --allow-net _shared/                 # signature verify, JWT round-trip, crypto, LS status map
deno test --allow-env --allow-net --allow-read generate/    # full generate flow + key-repurposing defense
#   (--allow-read: prompt_test.ts reads apps/desktop/Scripts/artifact-eval/prompt-v2.md
#    to enforce byte-identity of the locked prompt — run from inside the repo)
deno test --allow-env trial-start/             # request/verify flow + email helpers (stubbed sender)
deno test --allow-env --allow-net session/     # §14.6 staleness re-check (stub LS client)
deno test --allow-env --allow-net lemonsqueezy-webhook/  # full lifecycle + replay/forgery/stale-drop
deno test --allow-env --allow-net --allow-read refresh-agent-models/ agent-models/  # manifest: curate/rank/upsert, vanished→inactive, fetch-failure-never-wipes, grouped read
```

The **Phase G** additions: `session/handler_test.ts` proves the §14.6 staleness
re-check (stale + LS-cancelled → 403 even when the local mirror still says
active; LS down → fail open); `lemonsqueezy-webhook/handler_test.ts` proves the
whole subscription lifecycle (created → period, renewal → roll+reset, tier change
→ next-period limit, payment_failed → past_due no reset, recovered → active,
cancelled/expired/refund → revoke), plus replay dedup, signature forgery → 401,
and stale-drop. `generate/handler_test.ts` adds the key-repurposing assertion (a
client-supplied transcript / system_prompt / messages array is IGNORED).

The `trial-start` tests inject an in-memory store + a stub email sender (no real
mail), and cover: request rate-limits + rejects disposable domains + refuses an
already-used email; verify creates a grant **once** (a second verify for the same
email doesn't double-grant / reset credits); wrong/expired/over-attempts codes;
and a successful verify minting a valid `kind:"trial"` token. The `generate`
trial-branch tests (in `generate/`) cover: a trial token decrements the grant
atomically, deduct-on-success-only, `402` at zero, the concurrency cap, and that
the cap can't be exceeded across sequential requests.

The `generate` tests inject **stub provider transports** and an in-memory
store, so they never hit a real provider or spend money. They cover: happy path
(the model's credit price consumed exactly once, `generation_log` row with
tokens/cost/model/provider and **no content**, prompt returned); credit gating
(balance below the model price → `402`, no provider call); model validation
(unknown/disabled model → `400`); provider routing + missing-key failures;
input fuse (too many frames / wrong MIME / oversized payload / audio too long →
rejected before any provider call, no charge); provider failure → no charge +
`success=false` log; idempotent replay (same key → cached response incl.
`credits_charged`, no second charge); auth (`401`) and status (`403`/`404`);
the concurrency cap (second in-flight request → `429`); `past_due` still
generates; and the consume-race edge (result returned once, logged, not
double-charged).

### End-to-end curl battery (against the deployed functions)

```bash
export BASE="https://<your-project-ref>.supabase.co/functions/v1"
export WEBHOOK_SECRET="<your LEMONSQUEEZY_WEBHOOK_SECRET>"
supabase/test/run-curl-tests.sh
```

It exercises: bad/missing signature → 401; `subscription_created` →
`license_key_created` → `session` returns a token → `entitlement` returns
credits; duplicate event → 200 no-op; `payment_failed` → `past_due` but the key
still gets a token; `payment_success` → reset; `cancelled` → `session` 403.

For `generate` it exercises only the **free** money-safety gates (no real OpenAI
spend): missing/invalid token → 401; wrong audio/frame MIME → 415 (rejected
before transcription); and — after the subscription is cancelled — `generate`
→ 403 (server re-checks status). The **happy path spends real OpenAI money and
needs real audio/frames**, so it lives in the stubbed Deno tests above, not in
this live battery.

### RLS spot-check (deny-by-default)

With an **anon** key, any direct table read must return zero rows / be denied —
the app never gets this key, but confirm the posture:

```bash
curl "$SUPABASE_URL/rest/v1/subscriptions?select=*" \
  -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>"
# → [] (RLS denies; no policy grants anon)
```

The service role (used inside the functions) bypasses RLS and works normally.

---

## What's intentionally deferred

- **Reserve-then-commit credit ordering** → Phase G. D2 uses
  check-then-consume-on-success, kept safe by the concurrency cap of 1; the
  upgrade seam is marked `// DEFERRED Phase G` in `generate/handler.ts`.
- **Live LemonSqueezy re-check** when the mirror is stale (missed-webhook
  money-leak guard, §14.6) → **done (Phase G).** `session/handler.ts` does a live
  `GET /v1/subscriptions/{id}` when the mirror is older than
  `SESSION_STALENESS_SECONDS`; a conclusive `cancelled`/`expired` reconciles the
  mirror + refuses (403), a conclusive `active`/`past_due` reconciles + mints, and
  an inconclusive answer (LS down / `LEMONSQUEEZY_API_KEY` unset) fails OPEN.
  Proven by `session/handler_test.ts`; see SECURITY-RUNBOOK.md for the live recipe.
- **`trial-start` + trial-credit enforcement** (email-keyed) → **done (Phase F).**
  `generate` now accepts `kind:"trial"` tokens and spends `trial_grants` via
  `consume_trial_credit`.
- **Abuse flagging on over-limit payloads** → possible Phase G; the proxy just
  rejects cleanly with no tracking.
- **Tighter rate limiting + window cleanup** → Phase G; `rate_limits` +
  `check_rate_limit()` are the v1 basic limiter (now also backing `trial-start`).
- **`trial_codes` / expired-row cleanup** → Phase G. Expired code rows are burned
  on the next verify attempt but there's no periodic sweep; a cron/TTL job is a
  Phase G nicety (the rows are tiny + harmless).
