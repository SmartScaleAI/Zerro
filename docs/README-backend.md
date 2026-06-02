# Zerro billing backend (Supabase) — deploy & operate

This `supabase/` directory is the **server-side mirror of subscription state** for
Zerro's Managed tier (Phase D1). LemonSqueezy is the system of record for who
paid; Postgres here is a fast local mirror kept current by LemonSqueezy
webhooks, so the runtime can authorize a generation without calling LemonSqueezy
on every request.

**Scope of this phase (D1):** data layer + the `lemonsqueezy-webhook` receiver +
the `session` / `entitlement` read endpoints. It does **not** touch the OpenAI
key and does **not** call OpenAI — the `generate` proxy is **Phase D2**.

Design of record: `Documents/zerro-billing-plan.md` (§6.2, §6.3, §9/§9.1, §14)
and `Documents/zerro-billing-implementation-plan.md` (Phase D).

---

## What got built

```
supabase/
  config.toml                         # verify_jwt=false for all 3 functions (see notes)
  migrations/
    20260601120000_billing_schema.sql # tables + consume_credit() + check_rate_limit()
    20260601120100_billing_rls.sql    # RLS deny-by-default on every table
  functions/
    _shared/                          # env, config, crypto, ls-signature, jwt, db, types,
                                      # entitlement, http  (+ *_test.ts Deno tests)
    lemonsqueezy-webhook/             # signature-verified webhook receiver
    session/                          # license key → short-lived JWT
    entitlement/                      # token → display-only snapshot
  test/run-curl-tests.sh              # post-deploy verification battery
README-backend.md                     # this file
```

**Tables:** `subscriptions`, `usage_periods`, `trial_grants` (Phase F),
`webhook_events` (idempotency), `pending_license_keys` (reconciliation buffer
for LS's separate license-key event), `generation_log` (D2 writes it),
`rate_limits` (basic limiter). License keys are stored only as a **SHA-256
hash** — never raw.

**Atomic credit primitive:** `consume_credit(subscription_id)` — a single
conditional `UPDATE … WHERE credits_used < credits_limit RETURNING …` on the
subscription's latest period. The conditional update under a row lock is the
double-spend guard. D2's `generate` calls it; created now so D2 just uses it.

---

## Secrets

Set with `supabase secrets set NAME=value` (or the dashboard → Edge Functions →
Secrets). **`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by
the runtime — do NOT set them yourself.**

| Secret | Required | What it is |
|---|---|---|
| `SESSION_JWT_SECRET` | ✅ | HS256 signing secret for the short-lived session tokens. Generate a long random string (`openssl rand -hex 32`). |
| `LEMONSQUEEZY_WEBHOOK_SECRET` | ✅ | The signing secret you enter when creating the webhook in LemonSqueezy. The webhook verifies `X-Signature` against it. |
| `LS_VARIANT_STARTER` | ⚠️ Phase E | LemonSqueezy **variant id** of the Starter product → maps to tier `starter`. Until set, an unmapped variant defaults to `starter` (logged). |
| `LS_VARIANT_PRO` | ⚠️ Phase E | Variant id of the Pro product → tier `pro`. |
| `CREDITS_STARTER` | optional | Starter monthly allowance (default `100`). |
| `CREDITS_PRO` | optional | Pro monthly allowance (default `300`). |
| `SESSION_TOKEN_TTL_SECONDS` | optional | Session token lifetime (default `1800` = 30 min). |
| `SESSION_RATE_LIMIT_PER_KEY` / `_PER_IP` / `_WINDOW_SECONDS` | optional | Basic `session` rate limit (defaults `10` / `30` per `60`s). |
| `OPENAI_API_KEY` | ❌ not D1 | Belongs to Phase D2 (`generate`). Do not add yet. |

---

## Deploy

```bash
# One-time: link the local dir to your Supabase project (Pro — free tier
# auto-pauses and is unsuitable for a live paywall backend).
supabase link --project-ref <your-project-ref>

# 1. Apply the schema + RLS migrations.
supabase db push

# 2. Set the secrets (see table above).
supabase secrets set SESSION_JWT_SECRET="$(openssl rand -hex 32)"
supabase secrets set LEMONSQUEEZY_WEBHOOK_SECRET="<paste the LS webhook secret>"
# Phase E: supabase secrets set LS_VARIANT_STARTER=... LS_VARIANT_PRO=...

# 3. Deploy the three functions. --no-verify-jwt is REQUIRED on all three
#    (see "Why --no-verify-jwt" below). config.toml already encodes this, but
#    pass the flag explicitly so a config drift can't silently re-enable the
#    gateway JWT gate.
supabase functions deploy lemonsqueezy-webhook --no-verify-jwt
supabase functions deploy session             --no-verify-jwt
supabase functions deploy entitlement          --no-verify-jwt
```

### Why `--no-verify-jwt` on all three

`verify_jwt` controls whether the **Supabase API gateway** demands a
Supabase-issued JWT before the function runs. All three need it **off**, for
different reasons:

- **lemonsqueezy-webhook** — LemonSqueezy sends no Supabase JWT. Security is the
  `X-Signature` HMAC check (raw body, constant-time), done in code.
- **session** — the credential is the **license key**, not a Supabase JWT.
  Security is the per-key/per-IP rate limit + key-hash lookup.
- **entitlement** — it verifies **our own** session JWT (HS256,
  `SESSION_JWT_SECRET`) **in code**. If the gateway also tried to verify a JWT,
  it would reject the app's token before our code runs. So the gateway gate is
  off and the in-code verify is the real gate.

---

## Register the webhook in LemonSqueezy

LemonSqueezy dashboard → **Settings → Webhooks → +**:

- **Callback URL:**
  `https://<your-project-ref>.supabase.co/functions/v1/lemonsqueezy-webhook`
- **Signing secret:** the same value you set as `LEMONSQUEEZY_WEBHOOK_SECRET`.
- **Events to enable:** `subscription_created`, `subscription_updated`,
  `subscription_payment_success`, `subscription_payment_failed`,
  `subscription_payment_recovered`, `subscription_cancelled`,
  `subscription_expired`, `license_key_created`, and (for revocation)
  `order_refunded`.

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

## Verify (no app needed)

### Unit tests (`_shared`)

```bash
cd supabase/functions
deno test --allow-net _shared/   # signature verify, JWT round-trip, crypto vectors
```

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

- **`generate` proxy + `OPENAI_API_KEY`** → Phase D2. A note marks where it
  lives (`functions/entitlement/index.ts` tail; new `functions/generate/`).
- **Live LemonSqueezy re-check** when the mirror is stale (missed-webhook
  money-leak guard, §14.6) → seam + `// DEFERRED Phase G` marker in
  `session/index.ts`.
- **`trial-start` + trial-credit enforcement** (email-keyed) → Phase F;
  `trial_grants` table exists now.
- **Tighter rate limiting + window cleanup** → Phase G; `rate_limits` +
  `check_rate_limit()` are the v1 basic limiter.
