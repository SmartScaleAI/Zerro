# Zerro billing — security runbook & pre-launch checklist (Phase G)

This is the operator's companion to `README-backend.md`. It is the Phase G
deliverable: the threat-model control matrix (what's proven by an automated test
vs what needs your live run), how to run the abuse battery, the manual
LemonSqueezy-test-mode lifecycle runbook, the fail-open/fail-closed audit, and
the pre-launch checklist.

Phase G added **no product features** — it hardened, proved, and closed one real
gap (the §14.6 staleness re-check). Authoritative threat model:
`zerro-billing-plan.md` §14 (+ §9.1 past-due, §6 proxy).

---

## 0. The one gap Phase G closed — §14.6 staleness re-check

**The leak.** LemonSqueezy is the system of record; `public.subscriptions` is a
webhook-fed mirror. If a `subscription_cancelled` / `_expired` webhook is
**dropped** (LS outage, our 5xx, a deploy window), the mirror keeps showing
`active` forever and `session` keeps minting tokens for a non-paying user.

**The fix** (`session/handler.ts`). When the mirror row hasn't been touched by a
webhook **or** a prior live re-check within `SESSION_STALENESS_SECONDS` (default =
the token TTL), `session` does a **live** `GET /v1/subscriptions/{id}` before
minting:

| Live LemonSqueezy answer | Action |
|---|---|
| `cancelled` / `expired` / `unpaid` | reconcile the mirror to that status **and refuse (403)** — the dropped-webhook catch |
| `active` / `on_trial` / `paused` / `past_due` | reconcile the mirror (resets the freshness anchor) **and mint** (past_due still works, §9.1) |
| inconclusive — LS down, non-200, unparseable, **or `LEMONSQUEEZY_API_KEY` unset** | **fail OPEN** → mint with the existing mirror status (a payer is never locked out by an LS outage) |

The freshness anchor is the row's `updated_at` (the `set_updated_at` trigger
stamps it on every webhook write and on a re-check reconcile), so a
recently-heard-from subscription **skips** the live call — the cost is bounded to
~one LS call per subscriber per staleness window. An already-issued token still
can't outlive its short expiry, so a missed cancel is caught within ~one token
TTL of the mirror going stale.

**Required for the guard:** set `LEMONSQUEEZY_API_KEY` (see README secrets table).
Without it the guard is disabled (logged: `stale_recheck_disabled_no_api_key`)
and `session` fails open.

---

## 1. Control matrix — what proves each §14 control

`A` = automated (runs with no live backend). `L` = needs your live run / manual.

| # | Threat-model control | Status | Proven by |
|---|---|---|---|
| §14.1 | Provider keys never reach the client; live only in `OPENAI_API_KEY` / `GEMINI_API_KEY` | A | `generate/index.ts` reads env and passes keys to the adapter factory; keys never in any response/log (Gemini key sent via `x-goog-api-key` header, never the URL). Asserted indirectly by the no-content log test. |
| §14.1 | **Key can't be repurposed** — client-supplied transcript / system_prompt / messages are IGNORED; server transcribes + composes | **A** | `generate/handler_test.ts` → *"client-supplied … fields are IGNORED"*. The wire contract (`limits.ts`) has no transcript/prompt field at all. |
| §14 input | Oversized audio / too many frames / oversized payload / wrong MIME rejected **before** any OpenAI call or charge | A | `generate/handler_test.ts` (payload 413, frames 413, MIME 415, **true post-Whisper seconds gate** 413). |
| §14 spend | **Concurrent double-spend** prevented — two last-credit requests → exactly one charges | A | `generate/handler_test.ts` concurrency-cap tests (sub + trial); the atomic `consume_credit` / `consume_trial_credit` conditional `UPDATE` + the slot cap=1. |
| §14 spend | OpenAI failure never charges; deduct on success only | A | `generate/handler_test.ts` (429→503, 500→503, 401→502, all `used` unchanged). |
| §14.3 | **Webhook forgery** rejected — bad/missing `X-Signature` → 401, nothing written | A | `lemonsqueezy-webhook/handler_test.ts` (+ `_shared/ls-signature_test.ts`). |
| §14.3 | **Webhook replay** deduped — same event twice → processed once | A | `lemonsqueezy-webhook/handler_test.ts` (composite idempotency key; no double period-roll). |
| §9 / §14.2 | **Leaked-then-revoked** credential dies — cancelled/expired → next `session` mint 403; short token expiry bounds an already-issued one | A + L | A: `session/handler_test.ts` (terminal status → 403) + curl (cancelled key → 403). L: live LS-test-mode cancel (§4). |
| §14.6 | **Missed-webhook** money-leak guard — stale mirror + LS-cancelled → 403 | A + L | A: `session/handler_test.ts`. L: §3 live recipe below. |
| §14.2 | Patched client can't forge entitlement — generate is the sole spend authority | A | `generate/handler_test.ts` (no token → 401, cancelled → 403, no credit → 402) + app `BillingHardeningTests` (a local `.managed` flag routes to the proxy, never spends alone). |
| §14.7 | Trial refarm bounded — one grant per verified email, never fresh credits; disposables blocked; code rate-limited | A | `trial-start/handler_test.ts` (verify creates once / never resets; disposable 422; rate-limit 429) + the `email_normalized` UNIQUE + `verify_trial_grant` create-once. |
| §14.3 | **RLS deny-by-default** — anon key reads/writes nothing | L | curl RLS section (set `SUPABASE_URL`+`ANON_KEY`); the migrations enable+FORCE RLS with zero policies. |
| §9.1 | Past-due keeps working on remaining credits; no fresh allowance; nudge shown | A | `lemonsqueezy-webhook/handler_test.ts` (failed → past_due, no reset) + app `BillingHardeningTests` (past_due refresh stays managed + nudge). |
| §3.2 | Variant→tier mapping correct for all 4 variants | A | `lemonsqueezy-webhook/tier_test.ts` (pro monthly+yearly, starter) + `handler_test.ts` (created → Pro for both Pro variants). |
| §14.5 | Privacy — audio/frames/transcript/prompt never persisted; `generation_log` is token/cost/success only | A | `generate/handler_test.ts` no-content-leak assertion; the table **has no content column** (schema). |
| §5 | Fail-open on infra failure; fail-closed on spend | A | App `BillingHardeningTests` + `EntitlementStoreManagedTests` + `TrialCreditsTests`; server `store.ts` rate-limit fail-open. See §5 below. |

**Lifecycle (§3)** webhook handlers are all automated in
`lemonsqueezy-webhook/handler_test.ts`; the **live LS-test-mode** walk-through is
§4 (you must run it once against your real test-mode store before launch).

---

## 2. Run the abuse battery

### Backend unit/integration (Deno — no live backend, no spend)

```bash
cd supabase/functions
deno test --allow-env --allow-net .          # all functions + _shared
```

Expected: **all green** (107+ tests). Key files:
`session/handler_test.ts` (§14.6), `lemonsqueezy-webhook/handler_test.ts`
(lifecycle/replay/forgery), `generate/handler_test.ts` (input fuse, double-spend,
key-repurposing, privacy), `trial-start/handler_test.ts` (refarm bound).

### App-side (XCTest — fail-open/closed + terminal routing)

```bash
xcodebuild test -scheme Zerro -destination 'platform=macOS' \
  -only-testing:ZerroTests/BillingHardeningTests \
  -only-testing:ZerroTests/EntitlementStoreManagedTests \
  -only-testing:ZerroTests/TrialCreditsTests
```

> Note: two **pre-existing** `LicenseServiceTests` cases read your *real* Keychain
> managed license + the live backend and so resolve `.managed` not `.byok` on
> your dev machine (they pass on a clean machine/CI). They are unrelated to Phase
> G — don't be alarmed if only those two fail locally.

### End-to-end (curl — against the deployed functions)

```bash
export BASE="https://<project-ref>.supabase.co/functions/v1"
export WEBHOOK_SECRET="<your LEMONSQUEEZY_WEBHOOK_SECRET>"
export SUPABASE_URL="https://<project-ref>.supabase.co"   # for the RLS section
export ANON_KEY="<your anon/publishable key>"             # for the RLS section
supabase/test/run-curl-tests.sh
```

Covers: signature 401, lifecycle, idempotency, session token / past-due / cancelled
→ 403, generate free-gates (no spend), and the **RLS anon-denial** sweep over
every billing table (skipped if `SUPABASE_URL`/`ANON_KEY` unset).

---

## 3. §14.6 staleness re-check — LIVE verification recipe

The dropped-webhook catch can't be exercised by replaying a webhook (that would
just update the mirror). Force the *gap* instead:

1. Activate a test-mode subscription in the app so `session` mints tokens.
2. In the **LemonSqueezy dashboard**, **cancel** that subscription — but do **not**
   let the webhook reconcile the mirror. Two ways to simulate the drop:
   - temporarily point the webhook URL elsewhere / disable it, cancel, then
     re-enable; **or**
   - immediately after cancelling, `UPDATE public.subscriptions SET updated_at =
     now() - interval '1 hour', status = 'active' WHERE id = '<id>'` (re-stale +
     re-activate the mirror to model the missed event).
3. Wait out `SESSION_STALENESS_SECONDS` (or set it low for the test), then call
   `/session` with the license key again.
4. **Expect 403** (`not_entitled`) and the function log line
   `stale_recheck_revoked`. Confirm `public.subscriptions.status` is now
   `cancelled` (the re-check reconciled it).
5. **Fail-open check:** with `LEMONSQUEEZY_API_KEY` unset (or LS unreachable),
   step 3 instead **mints** a token and logs `stale_recheck_*_fail_open` /
   `_disabled_no_api_key` — a payer is never locked out by an LS outage.

---

## 4. Full subscription lifecycle — LS test-mode runbook

Run once end-to-end in LemonSqueezy **test mode** before launch. After each step,
check `public.subscriptions` + `public.usage_periods` (SQL editor) and the app's
Billing section. The webhook-handler logic for every step is already proven by
`lemonsqueezy-webhook/handler_test.ts`; this confirms the **live wiring** (webhook
registered, secret matches, variant ids mapped, app reflects it).

| Step | Do in LS test mode | Expect in the mirror | Expect in the app |
|---|---|---|---|
| **Subscribe** | Buy Starter (and separately Pro) via the checkout | `status=active`, correct `tier`+`credits_limit` (100/300), one `usage_periods` row `credits_used=0`, `license_key_hash` set | `.managed`, tier + full credits, reset date |
| **Generate** | Record a few clips | `credits_used` increments by 1 each | credits line ticks down |
| **Renewal** | Advance the period / force a renewal charge (`subscription_payment_success`, `billing_reason=renewal`) | a **new** period row, `credits_used=0` (reset); status stays `active` | credits reset to full |
| **Tier change** | Switch Starter↔Pro (`subscription_updated`) | `tier`+`credits_limit` change; **current** period untouched | new limit shows for next period |
| **Payment failed** | Let a renewal fail (`subscription_payment_failed`) | `status=past_due`; credits/period **unchanged** | still generates on remaining credits; "update card" nudge |
| **Recovery** | Pay the past-due invoice (`subscription_payment_recovered` + `_payment_success`) | `status=active`; renewal rolls a fresh period | nudge clears; fresh allowance |
| **Cancel** | Cancel (`subscription_cancelled`) | `status=cancelled` | next record → paywall; `/session` → 403; **library still readable** |
| **Refund/dispute** | Refund the order (`order_refunded`) or invoice (`subscription_payment_refunded`) | `status=expired` | paywall; sessions refused |

**Pitfalls to verify live:** (a) the **license key arrives in its own
`license_key_created` event** — confirm `license_key_hash` is populated (else
`session` can't find the subscriber); (b) `LS_VARIANT_STARTER`/`_PRO` are
**comma-separated** monthly+yearly ids — confirm a yearly purchase still maps to
the right tier; (c) payment events carry an **invoice** resource, not a
subscription.

---

## 5. Fail-open vs fail-closed audit

The split, audited across every place entitlement is computed/refreshed or a
generation is authorized. **No violations found**; each row is the proof.

### Fail-OPEN — infra failure never drops an entitled user

| Layer | Branch | Proof |
|---|---|---|
| Trial clock | Keychain `.failure` read → grant full trial (never `.expired`) | `TrialManager.evaluate` + `TrialManagerTests` |
| License presence | `grantsBYOK` true for `.present` **and** `.indeterminate` (read error) | `EntitlementStoreManagedTests.testTransientKeychainFailureKeeps{Managed,Byok}` |
| License revalidation | network/inconclusive → keep `.byok`; only definitive `valid:false` disabled/expired clears | `EntitlementStore.performRevalidation` |
| Managed `/entitlement` refresh | transient network/5xx → keep cached `.managed` | **`BillingHardeningTests.testManagedRefreshFailsOpen*`** |
| `session` staleness re-check | LS down / API key unset → mint (fail open) | `session/handler_test.ts` inconclusive/disabled |
| Server rate limiter | `check_rate_limit` infra error → allow (spend still gated) | `generate/store.ts` `rateLimitOk` / `session/store.ts` |

### Fail-CLOSED — no positive server credit ⇒ no server-funded generation

| Layer | Branch | Proof |
|---|---|---|
| Proxy spend authority | no token → 401; cancelled/expired sub → 403; zero credits → 402; OpenAI fail → no charge | `generate/handler_test.ts` |
| Definitive Managed revocation | `not_entitled` or terminal status from `/entitlement` → drop `.managed`, clear cache, paywall | **`BillingHardeningTests.testManagedRefreshFailsClosed*`** |
| Server truth ≠ local cache | a server-revoked grant clears the local snapshot for **spend**; the display cache is irrelevant to the gate | `BillingHardeningTests` (snapshot cleared on revocation) |
| Trial dual-expiry | credits hit 0 → `.expired` even with a live clock | `TrialCreditsTests.testExhaustedCreditsExpire*` |
| Client flag alone | `.managed`/`.trial` local flag routes to the proxy; the proxy enforces credits regardless | `BillingHardeningTests` + the entire `generate` server suite |

---

## 6. Terminal-state UX — no dead ends

| End state | App behavior | Source |
|---|---|---|
| Trial active | reach selector; first server-funded generation needs a verified email | `generationRoute` → `.trialProxy` / `.trialNeedsEmail` |
| Trial exhausted | `.expired` → paywall (subscribe or add own key) | dual-expiry → `canGenerate=false` |
| Expired (clock) | paywall | `EntitlementState.expired` |
| Out of credits (managed) | blocked **this generation** only, non-punitive copy + reset date; **library readable**; still `.managed` | `RecordingFailureReason.outOfCredits` (402) |
| Past due | keeps working on remaining credits + "update card" nudge | `.managed` + `managedSnapshot.status == .pastDue` |
| Revoked / cancelled | paywall; sessions refused; library readable | `handleManagedRevocation` → recompute |

---

## 7. Pre-launch checklist

**Secrets** (`supabase secrets set …`):

- [ ] `SESSION_JWT_SECRET` (32+ random bytes)
- [ ] `LEMONSQUEEZY_WEBHOOK_SECRET` (matches the LS webhook)
- [ ] `LEMONSQUEEZY_API_KEY` — **required for the §14.6 guard** (else it fails open)
- [ ] `OPENAI_API_KEY` — **always required** (Whisper STT, even when chat runs on Gemini)
- [ ] `GEMINI_API_KEY` — **required only when `CHAT_PROVIDER=gemini`**; rotate alongside `OPENAI_API_KEY`. Lives only in secrets; never returned/logged (same handling as the OpenAI key, §14.1).
- [ ] `RESEND_API_KEY` + a **verified** Resend sender domain
- [ ] `LS_VARIANT_STARTER` / `LS_VARIANT_PRO` (comma-separated monthly,yearly ids)
- [ ] (optional) `CREDITS_*`, `TRIAL_CREDITS`, `SESSION_STALENESS_SECONDS`, provider/model overrides (`CHAT_PROVIDER`, `CHAT_MODEL`, `GEMINI_THINKING_LEVEL`)

**Deploy**:

- [ ] `supabase db push` (all 5 migrations applied)
- [ ] all 5 functions deployed **`--no-verify-jwt`** (config.toml mirrors this)
- [ ] webhook registered in LS with **all** events incl. `license_key_created` + `order_refunded`

**Prove**:

- [ ] `deno test --allow-env --allow-net .` → all green
- [ ] `BillingHardeningTests` + `EntitlementStoreManagedTests` + `TrialCreditsTests` green
- [ ] `run-curl-tests.sh` (with `SUPABASE_URL`+`ANON_KEY`) → all green, **RLS rows = []**
- [ ] §3 staleness live recipe → 403 on the dropped-cancel; fail-open with key unset
- [ ] §4 lifecycle runbook walked end-to-end in LS test mode (Starter **and** Pro, incl. yearly)
- [ ] confirm `generation_log` has **no** content column; spot-check a row is tokens/cost only

**Posture sanity**:

- [ ] app never ships a Supabase anon/service key
- [ ] RLS enabled + FORCED on every billing table, zero permissive policies
- [ ] license keys + trial codes stored only as SHA-256 hashes
- [ ] short token TTL set (15–60 min); staleness window ≈ TTL
