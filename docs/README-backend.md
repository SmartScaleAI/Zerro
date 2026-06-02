# Zerro billing backend (Supabase) — deploy & operate

This `supabase/` directory is the **server-side mirror of subscription state** for
Zerro's Managed tier (Phase D1). LemonSqueezy is the system of record for who
paid; Postgres here is a fast local mirror kept current by LemonSqueezy
webhooks, so the runtime can authorize a generation without calling LemonSqueezy
on every request.

**Scope (D1 + D2):** D1 built the data layer + the `lemonsqueezy-webhook`
receiver + the `session` / `entitlement` read endpoints. **D2 adds the
`generate` proxy** — the server-side counterpart that holds the OpenAI key,
transcribes audio + composes the prompt server-side, enforces input limits +
credits, and returns the generated prompt. `generate` is the only function that
touches OpenAI; it can never be bypassed to spend money without a valid
subscriber **and** an available credit.

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
    20260601120300_billing_generate_slots.sql # D2: generation_slots + acquire/release (concurrency cap)
  functions/
    _shared/                          # env, config, crypto, ls-signature, jwt, db, types,
                                      # entitlement, http  (+ *_test.ts Deno tests)
    lemonsqueezy-webhook/             # signature-verified webhook receiver
    session/                          # license key → short-lived JWT
    entitlement/                      # token → display-only snapshot
    generate/                         # D2: session JWT → transcribe + prompt + chat (OpenAI proxy)
                                      #   handler.ts (flow), openai.ts (injectable client),
                                      #   prompt.ts / interleave.ts (ported, KEEP IN SYNC),
                                      #   limits.ts, cost.ts, config.ts, store.ts (+ handler_test.ts)
  test/run-curl-tests.sh              # post-deploy verification battery
README-backend.md                     # this file
```

**Tables:** `subscriptions`, `usage_periods`, `trial_grants` (Phase F),
`webhook_events` (idempotency), `pending_license_keys` (reconciliation buffer
for LS's separate license-key event), `generation_log` (D2 writes it),
`rate_limits` (basic limiter), `generation_slots` (D2 concurrency cap). License
keys are stored only as a **SHA-256 hash** — never raw.

**Atomic credit primitive:** `consume_credit(subscription_id)` — a single
conditional `UPDATE … WHERE credits_used < credits_limit RETURNING …` on the
subscription's latest period. The conditional update under a row lock is the
double-spend guard. D2's `generate` calls it on a successful generation.

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
| `LS_VARIANT_STARTER` | ⚠️ Phase E | LemonSqueezy **variant id** of the Starter product → maps to tier `starter`. Until set, an unmapped variant defaults to `starter` (logged). |
| `LS_VARIANT_PRO` | ⚠️ Phase E | Variant id of the Pro product → tier `pro`. |
| `CREDITS_STARTER` | optional | Starter monthly allowance (default `100`). |
| `CREDITS_PRO` | optional | Pro monthly allowance (default `300`). |
| `SESSION_TOKEN_TTL_SECONDS` | optional | Session token lifetime (default `1800` = 30 min). |
| `SESSION_RATE_LIMIT_PER_KEY` / `_PER_IP` / `_WINDOW_SECONDS` | optional | Basic `session` rate limit (defaults `10` / `30` per `60`s). |
| `OPENAI_API_KEY` | ✅ **D2** | The OpenAI key for the `generate` proxy. **Lives ONLY here**, read from env in the function — never returned to the client, never logged. This is the new secret D2 requires. |
| `STT_MODEL` | optional | Transcription model (default `whisper-1`). Swap server-side without an app update. |
| `CHAT_MODEL` | optional | Generation model (default `gpt-4o`). Swap server-side without an app update. |
| `GENERATE_MAX_AUDIO_SECONDS` / `_MAX_AUDIO_BYTES` / `_MAX_FRAMES` / `_MAX_PAYLOAD_BYTES` | optional | Input fuse (defaults `300`s / `12`MB / `200` / `60`MB). Set generously above any real recording; lower against measured cost. |
| `GENERATE_SLOT_STALE_SECONDS` | optional | Concurrency-slot stale-reclaim window (default `180`s; must exceed worst-case OpenAI round-trip). |
| `GENERATE_RATE_LIMIT_PER_SUB` / `_WINDOW_SECONDS` | optional | Per-subscriber `generate` rate limit (defaults `20` per `60`s). |
| `GENERATE_OPENAI_TIMEOUT_MS` | optional | OpenAI request timeout (default `120000`). |

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
supabase secrets set OPENAI_API_KEY="<your OpenAI key>"   # D2 — generate proxy
# Phase E: supabase secrets set LS_VARIANT_STARTER=... LS_VARIANT_PRO=...

# 3. Deploy the four functions. --no-verify-jwt is REQUIRED on all four
#    (see "Why --no-verify-jwt" below). config.toml already encodes this, but
#    pass the flag explicitly so a config drift can't silently re-enable the
#    gateway JWT gate.
supabase functions deploy lemonsqueezy-webhook --no-verify-jwt
supabase functions deploy session             --no-verify-jwt
supabase functions deploy entitlement          --no-verify-jwt
supabase functions deploy generate            --no-verify-jwt
```

### Why `--no-verify-jwt` on all four

`verify_jwt` controls whether the **Supabase API gateway** demands a
Supabase-issued JWT before the function runs. All four need it **off**, for
different reasons:

- **lemonsqueezy-webhook** — LemonSqueezy sends no Supabase JWT. Security is the
  `X-Signature` HMAC check (raw body, constant-time), done in code.
- **session** — the credential is the **license key**, not a Supabase JWT.
  Security is the per-key/per-IP rate limit + key-hash lookup.
- **entitlement** / **generate** — each verifies **our own** session JWT (HS256,
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

## The `generate` proxy (D2)

`POST /functions/v1/generate`, `Authorization: Bearer <session JWT>`, JSON body =
`{ mode, audio, frames }`. The app sends **audio + frames + a mode enum only** —
**never** a transcript or prompt text. The server transcribes and owns the
system prompt; that ownership is what stops the OpenAI key from being driven as a
general-purpose LLM.

**Flow (order is money-safety critical):**

1. Cap the raw body (`MAX_PAYLOAD_BYTES`) before parsing.
2. Verify our session JWT in code → `401` if invalid/expired (trial-kind tokens
   are Phase F → `401`).
3. Load the subscriber; `status ∈ (active, past_due)` → continue, else `403`.
   `past_due` still generates on its remaining credits (§9.1).
4. **Input fuse** (`limits.ts`) — frame count, MIME allow-lists, audio bytes,
   optional declared duration. Over-limit → `413`/`415`, **before any OpenAI
   call or credit work**. The limits sit well above any real recording; only a
   forged/oversized payload trips them.
5. Per-subscriber rate limit (`check_rate_limit`) → `429`.
6. **Acquire the concurrency slot** (cap = 1) → `429 generation_in_progress` if a
   request is already in flight for this subscriber.
7. **Check** a credit is available (no decrement) → `402 out_of_credits` if zero,
   no OpenAI call.
8. Transcribe (Whisper) → re-apply the **true** `MAX_AUDIO_SECONDS` gate on the
   measured duration before the expensive chat call → compose the server-owned
   system prompt + interleave frames/transcript → call chat (gpt-4o).
9. **On a fully usable result only:** `consume_credit()` atomically (deduct one).
10. Log token counts + cost + success to `generation_log`; release the slot;
    return `{ prompt, usage, credits_remaining }`.

**Credit ordering — check-then-consume-on-success.** We deduct only on success;
an OpenAI failure (429 / 5xx / timeout) charges nothing and returns a retryable
error (`503`; non-retryable → `502`). The one race this can't see — two
"last credit" requests both passing the availability check and both paying
OpenAI before either consumes — is removed by the **concurrency cap of 1**
(`generation_slots`): a single subscriber can't have two generations in flight.
`consume_credit()` remains the hard double-spend guard. *Deferred to Phase G:*
reserve-then-commit (reserve the credit before OpenAI, commit/release after) if
the cap is ever raised above 1.

**Privacy (§14.5).** Audio, frames, transcript, and the composed prompt are
processed **in memory only** — never persisted, no temp files. `generation_log`
has columns for token counts + cost + success and **nothing else** — there is no
column that could hold content.

**Models + limits are env-tunable** (see the secrets table): `STT_MODEL` /
`CHAT_MODEL` swap the models server-side without an app update; the
`GENERATE_MAX_*` constants are the input fuse — lower them in one place against
measured cost (search `// TODO: tune down` in `generate/config.ts`).

**Prompt/interleaving parity.** `generate/prompt.ts` and
`generate/interleave.ts` are **verbatim ports** of the Swift BYOK path so Managed
output matches. They carry `KEEP IN SYNC with …` markers — **if the Swift prompt
or interleaving changes, update the server copy too**, or Managed and BYOK drift.

---

## Verify (no app needed)

### Unit tests (`_shared` + `generate`)

```bash
cd supabase/functions
deno test --allow-net _shared/                 # signature verify, JWT round-trip, crypto vectors
deno test --allow-env --allow-net generate/    # full generate flow: stubbed OpenAI + in-memory store
```

The `generate` tests inject a **stub OpenAI transport** and an in-memory store,
so they never hit real OpenAI or spend money. They cover: happy path (credit
decremented exactly once, `generation_log` row with tokens/cost and **no
content**, prompt returned); credit gating (zero → `402`, no OpenAI call);
input fuse (too many frames / wrong MIME / oversized payload / audio too long →
rejected before OpenAI, no charge); OpenAI failure → no charge + `success=false`
log; auth (`401`) and status (`403`/`404`); the concurrency cap (second
in-flight request → `429`); `past_due` still generates; and the consume-race
edge (result returned once, logged, not double-charged).

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
  money-leak guard, §14.6) → seam + `// DEFERRED Phase G` marker in
  `session/index.ts`.
- **`trial-start` + trial-credit enforcement** (email-keyed) → Phase F;
  `trial_grants` table exists now, and `generate` rejects trial-kind tokens with
  `401` until then.
- **Abuse flagging on over-limit payloads** → possible Phase G; D2 just rejects
  cleanly with no tracking.
- **Tighter rate limiting + window cleanup** → Phase G; `rate_limits` +
  `check_rate_limit()` are the v1 basic limiter.
