# Implementation Plan — Multi-Model Selector + Variable Credit System

**Status:** Ready for implementation
**Audience:** Claude Code (and human reviewers)
**Scope:** Add a 6-model selector (user-selectable per generation), replace the flat "1 credit = 1 recording" model with a variable per-model credit system, add top-up packs, and re-shape Managed plans (monthly/yearly). BYOK stays free + unmetered.

---

## 0. Context & Goals

Zerro currently runs Managed generations on a **single server-configured model** (`CHAT_PROVIDER`/`CHAT_MODEL` env), and `consume_credit()` always spends **exactly 1 credit** per generation. This plan makes the **model user-selectable per request** and makes the **credit cost vary by model**, so margins stay roughly constant regardless of which model a user picks.

**Design principle (quality-first):** Users should experience the full quality of every model — including premium ones — before and after paying. Cost is pushed onto the user via faster credit burn on pricier models, never by hiding models.

**Non-negotiables carried over from the existing architecture:**
- Money-safety ordering in `generate/handler.ts` (check-then-consume-on-success, cap=1 slot, idempotency) must be **preserved**. We change *how many* credits are consumed, not *when*.
- The server owns the system prompt; the client only ever sends a `mode` enum (and now a `model` selection). The client must NOT be able to drive the key as a general-purpose LLM.
- `generation_log` holds token counts + cost + success ONLY — never content (§14.5). We are adding non-content metadata columns (model/provider), which is consistent with this.

---

## 1. Locked Product Decisions (source of truth for all numbers)

### 1.1 The six models

| Provider | Model ID (API) | Display name | Tier label |
|---|---|---|---|
| OpenAI | `gpt-5.4-mini` | GPT-5.4 mini | Lowest cost |
| Gemini | `gemini-3.5-flash` | Gemini 3.5 Flash ⭐ **Recommended for Zerro** | Lowest cost |
| Gemini | `gemini-3.1-pro-preview` | Gemini 3.1 Pro | Mid |
| Claude (Anthropic) | `claude-sonnet-4-6` | Claude Sonnet 4.6 | Mid |
| Anthropic | `claude-opus-4-7` | Claude Opus 4.7 | Highest cost |
| OpenAI | `gpt-5.5` | GPT-5.5 | Highest cost |

> **Label by cost, not quality.** Gemini 3.5 Flash is the recommended model for Zerro (field-leading multimodal/screenshot reading) **and** one of the cheapest — never imply higher credits = better output.

> **Model IDs are placeholders to confirm at build time.** Verify exact API model strings against each provider's current docs before wiring (see Phase 0 eval gate). Anthropic adapter does not exist yet (see Phase 3).

### 1.2 Credit pricing — `1 credit = $0.01 of real cost`

Fixed per-model price, quoted upfront, constant per generation. Derived from p75 of real cost (workload: ~7,969 input / ~966 output tokens + ~$0.006 STT).

| Model | Real cost (avg) | **Fixed credit price** | Approx. margin |
|---|---|---|---|
| GPT-5.4 mini | $0.0099* | **2** | ~50% |
| Gemini 3.5 Flash | $0.0266 | **4** | ~33% |
| Gemini 3.1 Pro | $0.0335 | **5** | ~33% |
| Claude Sonnet 4.6 | $0.0444 | **7** | ~37% |
| Claude Opus 4.7 | $0.0700 | **10** | ~30% |
| GPT-5.5 | $0.0748 | **11** | ~32% |

- **Circuit-breaker:** if a single generation's *real* `est_cost_usd` exceeds **3× its fixed price** (in dollar terms: `3 × price × $0.01`), charge the metered amount `ceil(est_cost_usd / 0.01)` instead of the fixed price. Anti-abuse only; normal users never trigger it.
- Prices live in **config** (one constant table), retunable without migration.

### 1.3 Plans

- **One Managed tier**, two billing intervals:
  - **Monthly:** $15/mo → 300 credits
  - **Yearly:** $12/mo billed annually ($144/yr) → 300 credits, refreshed every 30 days
- Credits are **non-rollover** (reset each period).
- **Trial:** **40 credits**, **all 6 models ungated** (no model gating anywhere). Email-keyed via existing `trial_grants` (unique-email anti-farming already in place).
- **BYOK:** **$69 one-time license, includes 1 year of updates** (after that, a new license is required to update to versions released past the year — older versions keep working). No credits, no credit UI. Supports all three providers (OpenAI + Gemini + Anthropic); the user adds a key per provider (any subset). A model is selectable only if the user has a key for its provider; models without a key are greyed-out with a hint (not hidden). User pays their own provider directly for usage.
  - **NOTE (changed from earlier "BYOK free"):** BYOK is now a paid license. Phase 6 must gate the BYOK path behind a valid license (the app already has `Services/Billing/LicenseService.swift` + license-key activation — reuse it). The 1-year-of-updates rule is enforced by the existing Sparkle/appcast update mechanism + license validity window; treat the precise enforcement as an OPEN item to design (flag, don't guess).

### 1.4 Top-up packs

| Pack | Credits | Price | $/credit |
|---|---|---|---|
| Boost | 200 | $10 | $0.050 |
| Power | 500 | $22 | $0.044 |

- **Spend order:** plan credits drain first, top-up credits last (ChatGPT model).
- Top-up credits **survive the monthly reset** and **expire 12 months from purchase**.
- **UI shows a single combined balance.** Two buckets tracked under the hood; breakdown only on a secondary/settings view.
- Purchasable when the user is **low or out** (not gated to exactly zero).

### 1.5 Terminology rule (applies to ALL user-facing copy — app + website)
The user-facing **unit is "credits," never a flat "generations" count.** A generation's credit cost varies by model (e.g. ~2 credits for GPT-5.4 mini vs ~10 for Opus), so stating "300 generations/month" would mislead — that's only true on the cheapest model. Rules:
- The **primary number is always credits** (balances, plan allowance, trial allowance, top-up packs, picker "~N left" is credits-derived).
- "Generations" may appear ONLY as a **secondary translation line** that shows the model-dependent range, e.g. "300 credits ≈ 75 with Flash or ~30 with Opus." It explains what credits buy; it is never the headline unit and never a single flat number.
- The free trial is **"40 credits,"** not "40 generations."
- This matches the website copy (kept in sync): website also leads with credits + the same translation line.

---

## 2. Calibration Caveat (must be stated in code comments + post-launch task)

The per-model prices are **real-token-shape × published API rates**, validated against measured Gemini Flash spend — solid starting points, **not permanent truth**. All non-Flash dollar figures are projections until real multi-model data exists. Published rates are as of **June 2026** and must be re-verified before launch. **Post-launch:** recompute real p75 per model from the new `model`-tagged logs after a few hundred multi-model generations and retune the config price table.

---

## 2.5 Codebase Verification Findings (read before any phase)

> A full pass over the real code was done before implementation. These are the facts that differ from naive assumptions — Claude Code should treat them as ground truth and FLAG if any have changed.

**F1 — Tiers already exist (Phase 1/5).** `_shared/config.ts` already defines TWO tiers: `Tier = 'starter' | 'pro'`, with `CREDITS_STARTER=100`, `CREDITS_PRO=300` (env-overridable), and `creditsForTier()`. The `subscriptions.tier` CHECK already allows `('starter','pro')`. **Decision:** for the single launch plan, use the **`pro` tier (300 credits)** as the Managed plan, OR repurpose `starter`. Do NOT invent a new tier. The "300 credits" in this plan = `CREDITS_PRO`. The webhook maps LS variant → tier via `LS_VARIANT_STARTER`/`LS_VARIANT_PRO` secrets.

**F2 — The chat client is built ONCE at startup, not per-request (Phase 3/4).** `generate/index.ts` constructs a single `chat` client from env `CHAT_PROVIDER`/`CHAT_MODEL` and injects it into `handleGenerate(req, { chat, ... })`. **Per-request model selection requires changing this**: either (a) inject a `makeChat(modelId)` factory function into deps instead of a prebuilt `chat`, or (b) pass all provider keys into deps and have the handler build the right adapter per request from the registry. Option (a) keeps the handler testable (preserves dependency injection). The provider adapters already take `(key, model, [thinking])` constructors and the factory already takes `model` as an arg — so only the wiring point moves.

**F3 — `consume_credit` is single-credit AND single-table (Phase 1).** `consume_credit(p_subscription_id uuid)` does ONE conditional UPDATE on the latest `usage_periods` row (`credits_used + 1`), gated `status in ('active','past_due') AND credits_used < credits_limit`. For variable + two-bucket spend, the new `consume_credit(uuid, integer)` must atomically (1) spend up to `p_credits` against the plan period, then (2) overflow the remainder into `topup_credits` (FIFO by `expires_at`), all in ONE function so it stays the double-spend guard. This is more than a parameter add — it spans two tables now. `consume_trial_credit` is similarly single-credit single-table (trial has NO top-up bucket, so it only needs the integer param).

**F4 — Entitlement snapshot has no top-up concept (Phase 4/5/6).** `_shared/entitlement.ts` + `EntitlementSnapshot` (`{tier,status,credits_remaining,credits_limit,reset_date}`) compute `credits_remaining = credits_limit - credits_used` of the latest period ONLY. The app reads this for its balance. **To show the combined balance (plan + top-up) the snapshot must be extended** with top-up balance (e.g. add `topup_remaining` and/or make `credits_remaining` the combined number while keeping plan figures for the meter). `session` and `entitlement` both build this snapshot via the SHARED helper — update in one place.

**F5 — The desktop BYOK path is hard-pinned to OpenAI gpt-4o (Phase 6 — BIG scope).** `Services/OpenAI/OpenAIPromptGenerationService.swift` has `static let model = "gpt-4o"` and there is NO provider abstraction on the client — only an `OpenAI/` folder (client + transcription + prompt-gen). **BYOK for Gemini + Anthropic is net-new**: needs a provider abstraction, two new client implementations (Gemini, Anthropic chat), per-provider Keychain key storage, and model→provider routing. This is the largest single piece of Phase 6. Transcription (Whisper) stays OpenAI regardless — confirm a BYOK user always needs an OpenAI key for STT even when chatting via Gemini/Anthropic (mirrors the server, where STT is always OpenAI).

**F6 — The app already models BYOK vs Managed cleanly (Phase 6 — helps).** `Services/Billing/EntitlementState.swift` has `enum EntitlementState { trial(...) , expired, byok, managed(tier:creditsRemaining:resetDate:) }` and `enum ManagedTier { starter, pro }`. The either/or Settings restructure (6E) maps directly onto this existing enum — the mode source-of-truth already exists. Settings UI lives in `Surfaces/Settings/Sections/BillingSection.swift` (plan/license) and `APIAuthSection.swift` (API key). These two sections are what 6E reorganizes.

**F7 — The eval harness already exists (Phase 0).** `apps/desktop/Scripts/eval-models.mjs` + `README-eval.md` replicate the production pipeline; prior results in `apps/desktop/eval-results/`; fixtures in `apps/desktop/eval-recordings/`. It has `chatOpenAI`/`chatGemini` only (no Anthropic), prices 3 models, dispatches `provider==='gemini'?...:openai`. Phase 0 EXTENDS this (add `chatAnthropic`, price 6 models, 3-way dispatch) — do not rebuild.

**F8 — Cost table must mirror in TWO places.** `supabase/functions/generate/cost.ts` (`CHAT_PRICING`) and `apps/desktop/Scripts/eval-models.mjs` (`CHAT_PRICING`) are intentional mirrors, and the Swift BYOK path has its own pricing constants (`OpenAIPromptGenerationService.swift`). All six models' rates must be added to each relevant place; keep them in sync (the files document this contract).

**F9 — Migrations are append-only, timestamped.** Existing: `20260601120000_billing_schema.sql` (core + `consume_credit`), `..._billing_rls.sql`, `..._billing_grants.sql` (EXECUTE grants), `..._billing_generate_slots.sql`, `..._billing_trial_credits.sql` (`consume_trial_credit` + trial slots), `20260605120000_billing_idempotency.sql`. New migrations follow `YYYYMMDDHHMMSS_*.sql`, RLS deny-by-default (force RLS, no policies), and must add EXECUTE grants for any new/overloaded function (mirror the grants migration).

---

## Phase 0 — Pre-Implementation Eval Gate (HARD GATE)

**Goal:** No model enters the menu until it passes a real-clip eval. This protects against a model that can't read frames or won't obey the strict output contract (notably Opus 4.7's documented "arguing"/preamble/hallucination risk).

**Use the existing harness (see F7) — do NOT build a new one.** `apps/desktop/Scripts/eval-models.mjs` + `Scripts/README-eval.md`; fixtures in `apps/desktop/eval-recordings/`; prior results in `apps/desktop/eval-results/`.

**Tasks**
1. Confirm exact current API model IDs + that each supports image input, against provider docs.
2. **Extend the harness:** add a `chatAnthropic` adapter (mirror `chatOpenAI`/`chatGemini`), make the provider dispatch 3-way (currently `provider==='gemini'?...:openai`), and add all six models to its `CHAT_PRICING` table. Require `ANTHROPIC_API_KEY` for `anthropic:*` specs.
3. Use real recordings in `eval-recordings/` (capture more via `Scripts/capture-recording.sh` if <5). Run all six models in **both** `--mode instruct` and `--mode explain` (Gemini Pro at `--thinking low` and `high`). The harness already uses the real prompt/interleave mirrors.
4. Score via the harness's existing 1–5 rubric in `SCORECARD.md`: small-text fidelity, deixis, hallucination, faithfulness, + auto cost/latency.
5. **Pass criteria:** model reliably produces valid, contract-compliant output. A model that produces *differently-styled but valid* output passes (the user decides preference); a model that breaks the output contract (preamble, refusals, fabrication, can't read frames) **fails and is dropped**. Watch Opus 4.7 specifically for preamble/arguing.
6. Record results; the menu + "Recommended" badge reflect eval outcomes, not just benchmarks.
7. **Eval-only:** do NOT modify `supabase/functions/` in this phase.

**Exit criteria:** A confirmed list of shipping models (≤6) with verified API IDs. Update §1.1 if any model is dropped.

---

## Phase 1 — Database Schema & RPCs (Supabase migrations)

> All changes are **new migrations** under `supabase/migrations/` (do not edit historical migrations). Follow the existing naming convention `YYYYMMDDHHMMSS_*.sql`. Keep RLS posture: service-role-only writes.

### 1.1 `generation_log`: add model/provider columns
- Add nullable `model text` and `provider text` to `public.generation_log`.
- Written on every generation (Phase 4). Enables post-launch per-model p75 calibration — **without this we cannot calibrate** (today only 2 models are even distinguishable, and only by reverse-engineering price signatures).
- Update the table comment to note these are non-content metadata (consistent with §14.5).

### 1.2 Variable credit consumption: `consume_credit(uuid, integer)`
- Add an overloaded/extended `consume_credit(p_subscription_id uuid, p_credits integer default 1)`.
- Behavior mirrors the current single-credit version (atomic conditional UPDATE on the latest `usage_periods` row, status in `active|past_due`, double-spend guard), but:
  - The spend gate must check `credits_used + p_credits <= credits_limit` **against the combined available balance including top-ups** (see 1.3). Spend plan credits first, overflow into top-up bucket.
  - Return remaining **combined** credits, or NULL if `p_credits` cannot be fully covered.
- **Atomicity:** the plan-vs-topup split + decrement must happen in ONE transaction/function so it stays a hard double-spend guard. Do not split into two RPCs.
- Keep the old 1-arg signature working (or route it to the new one with `p_credits => 1`) so nothing else breaks during rollout.
- Mirror the same change for **`consume_trial_credit(p_grant_id uuid, p_credits integer default 1)`** (trial path is ungated and must also support variable spend).

### 1.3 Top-up credit bucket (separate, survives reset, 12-mo expiry)
- New table `public.topup_credits`:
  - `id uuid pk`, `subscription_id uuid fk`, `credits_total integer`, `credits_used integer default 0`, `purchased_at timestamptz default now()`, `expires_at timestamptz` (= purchased_at + interval '12 months'), `ls_order_id text` (idempotency for the purchase webhook).
  - Index on `(subscription_id, expires_at)`.
- "Available top-up balance" = `sum(credits_total - credits_used)` over rows where `expires_at > now()`.
- Spend within `consume_credit`: after plan credits are exhausted for this generation, decrement from the **oldest non-expired** top-up row(s) first (FIFO, so nearest-to-expiry is used first).
- The monthly reset (existing `usage_periods` roll on `subscription_payment_success`) touches **only** plan credits — `topup_credits` is never reset by construction.

### 1.4 Billing interval + tier-readiness
- Add `billing_interval text check (billing_interval in ('monthly','yearly'))` to `public.subscriptions`. Both intervals map to the **same tier** with the **same 300-credit grant** and **same 30-day reset cadence**.
- **Reuse the existing tier system (see F1).** Tiers already exist: `'starter'` (CREDITS_STARTER=100) and `'pro'` (CREDITS_PRO=300). The single launch Managed plan = the **`pro` tier (300 credits)**. Both billing intervals (monthly $15 / yearly $12) map to `pro`. Do NOT add a new tier or change the CHECK constraint. `'starter'` stays available for a future cheaper tier. Set `CREDITS_PRO=300` (already the default).

### 1.5 Grants
- `grant execute` on the new/extended functions to `service_role` (mirror `20260601120200_billing_grants.sql`).

**Exit criteria:** Migrations apply cleanly on a branch DB; `generate_typescript_types` regenerated; existing billing tests still pass.

---

## Phase 2 — Backend Config: Model Registry & Price Table

**Files:** `supabase/functions/generate/config.ts`, new `supabase/functions/generate/models.ts`, `supabase/functions/generate/cost.ts`

1. **Model registry** (`models.ts`): a single source-of-truth map of the 6 shipping models →
   `{ id, provider, displayName, creditPrice, recommended?: boolean, enabled: boolean }`.
   - `enabled` lets you dark-launch / disable a model without a deploy if its eval regresses.
2. **Allowed-models list** derived from the registry (for request validation in Phase 4).
3. **Price table:** the fixed credit prices from §1.2 live here. Add a `circuitBreakerMultiplier = 3`.
4. **Extend `CHAT_PRICING` in `cost.ts`** to include all 6 models' published `$/1M` rates (so `est_cost_usd` is computed correctly per chosen model). Keep the existing tiered-pricing support (Gemini Pro >200k). Keep the "unpriced key → null estimate, never block" behavior.
5. Helper: `creditCostForModel(modelId, estCostUsd) → integer` implementing fixed price + circuit-breaker:
   `fixed = price[modelId]; metered = ceil(estCostUsd / 0.01); return estCostUsd > 3*fixed*0.01 ? metered : fixed;`

**Exit criteria:** Unit tests in `cost_test.ts` covering each model's fixed price, the circuit-breaker boundary, and unpriced fallback.

---

## Phase 3 — Provider Adapters: Add Anthropic + Per-Request Model

**Files:** `supabase/functions/generate/providers/` (`factory.ts`, `types.ts`, new `anthropic.ts`, `factory_test.ts`)

1. **Add an Anthropic chat adapter** (`anthropic.ts`) implementing `ChatClient` (mirror `gemini.ts`/`openai.ts`): converts the neutral `TimelineBlock[]` into Anthropic's messages API (image blocks + text), returns `ChatResult { provider:'anthropic', content, inputTokens, outputTokens, model }`.
2. **Factory:** extend `makeChatClient` to handle `provider==='anthropic'` (requires `ANTHROPIC_API_KEY`). Keep the "unknown provider → throw at wiring time" behavior.
3. **Per-request model — change the startup wiring (see F2).** Today `generate/index.ts` builds ONE `chat` client at startup from env and injects it. Change `GenerateDeps` so the handler can build the right adapter **per request** from the selected model: inject a `makeChat(modelId, provider) => ChatClient` factory (closing over the resolved provider keys) instead of a single prebuilt `chat`. Read all needed provider keys in `index.ts` (`OPENAI_API_KEY` always — also STT; `GEMINI_API_KEY`, `ANTHROPIC_API_KEY` when their models are enabled). This preserves dependency injection so `handler_test.ts` can inject a fake factory. Keep env `CHAT_MODEL`/`CHAT_PROVIDER` as the fallback when no model is sent (older-app compatibility).
4. Secrets: document `ANTHROPIC_API_KEY` (and confirm `GEMINI_API_KEY`, `OPENAI_API_KEY`) in `docs/README-backend.md`. Note: STT stays OpenAI Whisper regardless of chat provider — `OPENAI_API_KEY` is always required.

**Exit criteria:** Adapter unit tests (mock transport) for Anthropic; factory test covers all 3 providers + unknown-provider throw.

---

## Phase 4 — Backend Handler: Validate Model, Charge Variable Credits

**Files:** `supabase/functions/generate/limits.ts`, `handler.ts`, `store.ts`

1. **Request shape:** add an optional `model` field to the wire body (the only NEW client-supplied field besides `mode`). Parse + validate in `validateBody`:
   - If absent → fall back to the configured default model (backward compatible).
   - If present but not in the **allowed-models list** → `reject(400, "invalid_model")`. (No tier gating — all models allowed for subscription AND trial AND BYOK.)
   - The model selection must NOT influence the system prompt (server still owns prompt; `mode` is still the only prompt-affecting input).
2. **Resolve model → provider/creditPrice** from the registry; build the chat client for that model (Phase 3).
3. **Credit availability check (step 8):** change from "remaining <= 0" to "remaining < creditPriceForSelectedModel" → `402 out_of_credits` (with enough detail for the app to show the top-up prompt, e.g. `{ error, credits_remaining, model_price }`).
4. **Consume (step 12):** replace `account.consume()` (which spent 1) with `account.consume(credits)` where `credits = creditCostForModel(modelId, estCost)`. Compute `estCost` first (already happens), then derive the credit charge, then consume that many atomically.
   - **Preserve ordering:** still consume **only on a fully successful, usable result**. Failures/STT-only paths charge nothing. The cap=1 slot + idempotency stay exactly as-is.
   - The "uncharged_result_returned" race branch stays; just logs the model.
5. **Logging (step 13):** include `model` + `provider` in `logGeneration` / `GenerationLogRow` and the `generation_log` insert.
6. **Idempotency cache (M1):** the cached result already carries `usage.model`. On replay, do NOT re-charge (unchanged). Ensure the cached `credits_remaining` reflects the variable charge.
7. **`store.ts`:** update `consumeCredit`/`consumeTrialCredit` signatures to accept a credit count and call the new RPCs; update `GenerationLogRow` with `model`/`provider`; update the in-memory fake used by tests. Also update `creditsRemaining()` to return the **combined** plan+topup balance (it currently reads only the latest `usage_periods` row).
8. **Entitlement snapshot (see F4):** extend `_shared/entitlement.ts` + `EntitlementSnapshot` so the app's balance reflects plan + non-expired top-up. Keep the plan-only figures available (the meter in 6F needs plan `credits_used`/`credits_limit` separately from the combined total). `session` + `entitlement` share the helper — change once.

**Exit criteria:** `handler_test.ts` updated/added cases: model validation (valid/invalid/absent), correct variable charge per model, insufficient-credits-for-this-model → 402, circuit-breaker charge, failure charges nothing, idempotent replay doesn't double-charge, log carries model/provider, combined balance (plan+topup) spends in the right order. All existing money-safety tests still green.

---

## Phase 5 — Billing: Plans, Intervals, Top-Up Purchases (LemonSqueezy)

**Files:** `supabase/functions/lemonsqueezy-webhook/*`, `_shared/lemonsqueezy.ts`, `_shared/config.ts`

1. **Plan variants:** map LemonSqueezy monthly ($15) and yearly ($12/mo) variants → both to the **`pro` tier** (300 credits, see F1), `billing_interval` set accordingly, 30-day reset cadence preserved. Tier resolution already keys on `LS_VARIANT_STARTER`/`LS_VARIANT_PRO` secrets in `_shared/config.ts` (`resolveTier`) — set the Managed product's variant id(s) to map to `pro`. `credits_limit` is set by `creditsForTier()` (already 300 for `pro`). Reuse the existing `usage_periods` roll on `subscription_payment_success` (`store.openPeriod`, idempotent on `(subscription_id, period_start)`).
2. **Top-up purchases:** handle the top-up product purchase event(s) → insert a `topup_credits` row (credits per pack from §1.4, `expires_at = now()+12mo`, `ls_order_id` for idempotency via existing `webhook_events` HMAC dedupe). Boost = 200, Power = 500. Top-ups are a separate LS product/order, NOT a subscription event — confirm which LS event fires (likely `order_created`) and route it distinctly from subscription events in the webhook handler.
3. **Trial grant limit:** set **`TRIAL_CREDITS=40`** in `supabase/functions/trial-start/config.ts` (currently default 15, env-overridable). This is the single source — `trial-start/handler.ts` passes `TRIAL_CREDITS` into `verifyGrant`.
4. Idempotency: reuse the `webhook_events` HMAC-dedupe so a redelivered top-up purchase doesn't double-credit.

**Exit criteria:** Webhook handler tests: monthly vs yearly both create a `pro` (300) grant; top-up purchase inserts the right bucket once (idempotent); new trial grants are 40.

---

## Phase 6 — Desktop App (Swift): Model Selector + Credit UX

**Files (verified):** `Services/Managed/ManagedProxyClient.swift`, `Services/OpenAI/*` (existing BYOK, OpenAI-only), `Services/Billing/{EntitlementState,EntitlementStore}.swift`, `Surfaces/Settings/Sections/{BillingSection,APIAuthSection}.swift`, `Surfaces/Settings/SettingsView.swift`, `AppState.swift`.

> **Scope note (see F5):** BYOK is currently hard-pinned to OpenAI `gpt-4o` with NO provider abstraction. Multi-provider BYOK (Gemini + Anthropic clients, per-provider Keychain storage, model→provider routing) is the **largest single piece** of this phase. The mode model (BYOK vs Managed) already exists as `EntitlementState` (F6), which the Settings restructure builds on.

### 6A. Model picker UI (the key screen) — ONE component, mode-aware

The same picker is used for Managed, Trial, and BYOK. It renders models sorted by **credit cost ascending**, badges Gemini 3.5 Flash "Recommended for Zerro", and persists the user's last choice. **The credit column is conditional on billing mode** (see 6B/6D):

- **Managed / Trial mode:** each row shows display name + **credit price** + a live **"~N left"** (= floor(currentBalance / price)). Balance header visible.
- **BYOK mode:** each row shows display name + tier label ONLY. **No credit price, no "~N left", no balance header anywhere.** Credits are meaningless in BYOK (user pays their provider directly).

### 6B. Managed/Trial credit UX
1. **Send `model`** in the generate request body.
2. **Balance display:** the **primary number is CREDITS** (never dollars, never a flat "generations" count — a generation's cost varies by model, so a single generations number would mislead). E.g. headline "248 credits". Optionally add a SECONDARY translation/legibility line showing the model-dependent range, e.g. "≈ 35 with Sonnet · 24 with Opus · 124 with GPT-5.4 mini" — this is a helper that explains what credits buy, NOT the primary unit. Show reset date. Secondary/Settings view may show the plan-vs-topup breakdown + top-up expiry.
3. **Post-generation confirmation:** "−N credits · M remaining" using the variable charge returned by the server.
4. **Low/out-of-credits → top-up prompt:** when balance < selected model price (server `402` or client-side check), surface Boost/Power packs (links to LemonSqueezy checkout). Not gated to exactly zero.
5. **Trial UX:** identical picker, all 6 models, 40-credit balance; on exhaustion show the upgrade-to-Managed prompt.

### 6C. BYOK — all three providers, key-gated model list
> Net-new: code comments note BYOK was historically OpenAI-only. This extends BYOK to OpenAI + Gemini + Anthropic.
1. **Per-provider key storage:** Settings lets the user add/edit/remove a key for **each** of the three providers independently (any subset; not one-at-a-time). Store keys locally/securely as today (e.g. Keychain), keyed by provider.
2. **Provider-routing BYOK client:** based on the selected model's provider, route the generation to the user's key for that provider. The BYOK client must support all three provider request shapes (reuse/port the server adapter logic where practical, but BYOK calls go direct from the app, not through the proxy).
3. **Key-gated visibility:** a model is **selectable only if the user has a key for its provider.** Models whose provider has no key are shown **greyed-out with a hint** ("Add a Gemini API key in Settings to use this") — greyed, not hidden, so the user sees the tool supports them and is nudged to add keys.
   - With only an OpenAI key → GPT-5.4 mini + GPT-5.5 active, other four greyed.
   - With OpenAI + Gemini → four active. With all three → all six active.
4. **No credit accounting** in BYOK (per 6A).

### 6D. Billing-mode source of truth
The app already distinguishes Managed vs BYOK (key-based vs subscription). The picker reads that mode and (a) shows/hides the credit column, (b) for BYOK applies the per-provider key-gating, (c) for Managed/Trial applies the balance/"~N left" logic.

### 6E. Preferences → Account & Billing screen (restructure)
> Replaces today's screen, which stacks the BYOK "API Key" section AND a Managed "License Key / Buy a lifetime license" section simultaneously — confusing (reads as a checklist, not a choice), shows contradictory states (e.g. "Plan: Expired" next to an API key field), and uses an outdated "lifetime license" model that conflicts with the new subscription + credits design.

**Mode is a clean either/or, switchable.** The user is in exactly ONE mode at a time (Managed *or* BYOK). No hybrid: a generation never has to decide between credits and a personal key.

1. **Top control — "How you're using Zerro":** a single, prominent selector showing the two modes as mutually exclusive:
   - **Managed** — Zerro's plan + credits *(recommended / simplest)*
   - **Bring your own API keys (BYOK)** — you pay your providers directly
2. **Show only the active mode's detail below it:**
   - **Managed active →** show: current plan ($15/mo, or $12/mo yearly), the **usage meter** (see 6F), top-up packs (Boost/Power), manage-subscription link. Do NOT show API-key fields. **Remove "lifetime license" / "Buy a lifetime license" language entirely** — replace with the subscription + credits model. (If LemonSqueezy entitlement is still delivered via a license key under the hood, keep that activation mechanism but present it as "your subscription," not a lifetime license.)
   - **BYOK active →** show: the three per-provider API-key fields (OpenAI / Gemini / Anthropic), each with Keychain storage + verify/revalidate (mirror today's single-key UX, ×3). Do NOT show plan/credit/top-up/license UI (consistent with 6A + Appendix C #7).
3. **Always-present switch affordance:** whichever mode is active, show ONE low-key line to switch to the other (e.g. "Prefer your own API keys? Switch to BYOK" / "Don't want to manage keys? Switch to Managed"). The full other-mode section stays collapsed until the user switches — the choice is discoverable but not competing for attention.
4. **Fix contradictory states:** plan/credit status (e.g. "Expired", "X credits left") renders ONLY in Managed mode. In BYOK there is no plan state to show.

### 6F. Managed usage meter (inspired by Wispr Flow's billing meter)
A glanceable usage card at the top of the Managed billing section — Managed/Trial ONLY (never BYOK).

1. **Headline + bar:** "{combined balance} of {plan cap} credits remaining this month" with a proportional progress bar. The **bar tracks plan-credit consumption** against the 300 cap (the thing that resets); the **headline number is the combined balance** (plan + non-expired top-up) so it matches the model picker. (If a user has top-ups, the headline can exceed the bar's cap — that's expected; the secondary breakdown in 6E explains it.)
2. **Legibility line (secondary, not the primary unit):** under the bar, a translation of credits into the model-dependent range, e.g. "≈ 52 with Flash · 21 with Opus", so the abstract credit count stays meaningful. This explains what credits buy; the headline unit stays **credits**.
3. **Reset line:** "Resets {date}" (the plan-credit period end).
4. **Inline top-up prompt (replaces Wispr's 'Upgrade to Pro' line):**
   - Comfortable balance → quiet link: "Need more? Get a top-up pack."
   - **Low balance** (e.g. below the user's most-used model price, or a small threshold) → escalate: prominent "Running low — top up to keep going" surfacing Boost ($10/200) + Power ($22/500) with checkout links.
   - This is the SAME top-up trigger as the generation-flow prompt (6B.4), placed in the billing card too — keep one source of truth for the low-balance threshold.
5. **Trial:** same meter against the 40-credit trial allowance; the inline prompt becomes "Upgrade to Managed" instead of top-up (trials can't buy top-ups).

**Exit criteria:**
- Managed/Trial: app sends model, renders credit prices + "~N left", shows variable post-charge, surfaces top-up at low balance.
- BYOK: user can store all three keys; picker shows only key-backed models as active (rest greyed with hint); **no credit UI anywhere**; generation routes to the correct provider key for the selected model.
- Preferences → Account & Billing shows ONE active mode at a time with a switch link; Managed shows subscription + credits (no "lifetime license"); BYOK shows the 3 key fields (no plan/credit UI); plan-state strings appear only in Managed.
- Update `ManagedProxyClientTests`; add BYOK provider-routing + key-gating tests.

---

## Phase 7 — Docs, Secrets, Rollout

1. Update `docs/README-backend.md`: new model registry, price table, `ANTHROPIC_API_KEY`, top-up product mapping, the calibration caveat from §2.
2. Set secrets: `ANTHROPIC_API_KEY` (+ confirm Gemini/OpenAI keys) via `supabase secrets set`.
3. **Rollout order:** migrations → backend (functions) → billing webhook variants → app release. The optional-`model` fallback means a deployed backend stays compatible with the old app until the new app ships.
4. **Post-launch calibration task (scheduled/manual):** after ~a few hundred multi-model generations, query `generation_log` grouped by `model` for real p75 `est_cost_usd`, and retune the §1.2 price table (config edit, redeploy — no migration).

---

## Appendix A — Worked Margin Reference (300-credit grant)

| Usage pattern | Generations | Your API cost | Margin @ $15 / @ $12 |
|---|---|---|---|
| All Gemini Flash (recommended) | ~75 | $1.99 | 87% / 83% |
| All GPT-5.4 mini (cheapest) | ~150 | ~$1.49 | 90% / 88% |
| All Opus (worst case) | ~30 | $2.10 | 86% / 82% |
| Realistic mix | ~82 | ~$1.89 | 87% / 84% |

Trial (40 credits, all models): worst-case ~$0.28/user; realistic ~$0.25/user.

## Appendix B — Files Touched (quick index)

- **Migrations (new):** `generation_log` model/provider cols; `consume_credit(uuid,int)` + `consume_trial_credit(uuid,int)`; `topup_credits` table; `subscriptions.billing_interval`.
- **`generate/`:** `config.ts`, new `models.ts`, `cost.ts`, `limits.ts`, `handler.ts`, `store.ts`, `providers/{factory.ts,types.ts,anthropic.ts}` (+ tests).
- **`lemonsqueezy-webhook/`, `trial-start/`, `_shared/`:** plan variants, top-up purchases, trial limit = 40.
- **`apps/desktop/Zerro/`:** model picker, `ManagedProxyClient`, balance UX, top-up prompt, BYOK multi-provider.
- **`docs/README-backend.md`:** registry, prices, secrets, calibration caveat.

## Appendix D — Rollout decisions (locked during implementation)

- **D1 — No-model default = Flash (4 credits).** An un-updated app sends no `model`; the backend defaults to the recommended model (`gemini-3.5-flash`, 4 credits) because the old env default `gpt-4o` isn't a registry model and can't be priced. **Consequence:** existing apps go from 1 → 4 credits/generation until they update. **Decision: accept it** — deploy backend, ship the Phase 6 app build soon after to keep the window short (most users auto-update via Sparkle). No grandfather rule.
- **D2 — `credits_charged` is explicit in the 200 response.** Add `credits_charged` to the generate 200 response AND the idempotency cache shape, so the app's "−N credits" toast is exact (incl. the rare circuit-breaker case) rather than derived from the model price. (Implement in the Phase 4 follow-up / Phase 6 wiring.)

## Appendix E — Open items surfaced during implementation (track to launch)

- **E1 — RESOLVED: Top-up refund revocation built.** `handleOrderRefund` (lemonsqueezy-webhook) tries `topup_credits.ls_order_id` first: a refunded pack's UNSPENT remainder is revoked (`revokeTopupByOrderId`), spent credits stay consumed, other packs untouched; otherwise it falls through to the subscription-expiry branch. Top-ups are safe to sell. Original: `order_refunded` only matched `subscriptions.ls_order_id`, so a refunded pack kept its credits.
- **E9 — RESOLVED: the 5 licensing-test failures were the DEBUG dev-bypass hooks, not a bug (2026-06-11).** Root cause: the shared Xcode scheme ships `ZERRO_FUNCTIONS_BASE_URL` + `ZERRO_DEV_LICENSE_KEY` ENABLED (for local-stack dev), and two `#if DEBUG` hooks read them at call time — `LicenseService.activate`'s local-dev bypass (returns success + `local-dev-instance` without calling the transport → 3 LicenseServiceTests failures) and `SessionTokenManager.resolveLicenseKey`'s dev-key fallback (replaced the test's key → 2 SessionTokenManagerTests failures, incl. `testLicenseKeyRidesOnlyToSession`). **No real bug**: the license key still rode only to `/session`, release builds compile both hooks out, and the failures were deterministic environment coupling, not logic. Fix: both hooks are now gated on `usesRealTransport` (eligible only when NO transport was injected), so stub-injecting unit tests are hermetic regardless of scheme env, and the local-dev workflow is unchanged. Suite fully green after the gate; tests themselves were asserting correct behavior and were not modified.
- **E8 — RESOLVED: Yearly "Resets {date}" shows the next monthly refresh (Phase 7, 2026-06-11).** `_shared/entitlement.ts` now computes `reset_date` for `billing_interval='yearly'` as the latest `usage_periods.period_start + 1 month` (Postgres-style day clamping, matching the cron job's anchors), capped at `current_period_end` (the annual renewal owns the year boundary). Monthly/NULL-interval subs unchanged. Covered by `_shared/entitlement_test.ts`; both `session` and `entitlement` pick it up via the shared snapshot. Original: the label showed the annual renewal date; money was always correct.
- **E2 — RESOLVED: Yearly monthly credit refresh job built (2026-06-11).** Migration `20260611120000_yearly_credit_refresh.sql` + hourly pg_cron `refresh-yearly-credits`. Rolls a fresh 300-credit period monthly for active yearly subs, idempotent, bounded by `current_period_end` (12 grants/year, then annual renewal takes over). Tested on local stack. **Deploy note:** confirm pg_cron is enabled on the hosted project (Database → Extensions) and `cron.job` has the row after `db push`. Yearly is now safe to sell once the LS yearly product/variant + secrets exist (E3). Original problem for reference:
- **E2 (original) — Yearly monthly credit refresh — CONFIRMED BROKEN, do NOT sell yearly as-is.** Verified via LS docs (2026-06-11): LS bills a yearly subscription **once per year**, so `subscription_payment_success`/`billing_reason:"renewal"` fires annually, not monthly. The current period-roll (renewal-only) would give a yearly subscriber 300 credits at signup then NOTHING for 12 months. **Fix required before yearly goes on sale:** add a scheduled monthly credit-refresh — a Supabase pg_cron job (daily) that finds active `billing_interval='yearly'` subs whose latest `usage_periods.period_start` is ≥~30 days old and rolls a fresh 300-credit period (reuse `openPeriod`, idempotent on (sub,period_start)). **Until then: launch MONTHLY-only** (don't enable the yearly LS variant / hide it on the site). Monthly + BYOK + top-ups are fully working and unaffected.
- **E7 — RESOLVED: BYOK update-window enforcement built per the F.0 locked decisions (2026-06-11).** Entirely app-side: `LicenseAPIResponse.LicenseKeyObject.createdAt` decoded (tolerant 3-format parse in `LicenseService.parseCreatedAt`), persisted as epoch-seconds in the new `KeychainStore.byokLicenseCreatedAt` slot on every successful activate AND validate (pre-E7 licenses backfill on their next throttled re-validation; a pasted renewal key overwrites → window restarts), cleared with the license. `UpdateWindowPolicy` (pure, fully unit-tested — `SUAppcastItem` isn't constructible in tests, so the Sparkle delegate is a thin adapter) decides per appcast: defer to Sparkle when no window applies or nothing is filtered, pick the highest-versioned in-window item on a straddle (via `SUStandardVersionComparator`), `SUAppcastItem.empty()` when everything is out-of-window (silent "up to date"). Scoped to an EXPLICIT `licenseProductKind == byok` (Managed and unresolved kinds never filtered); fail-open on absent/garbage/unreadable window data and on undated appcast items. Hooked via `UpdateWindowUpdaterDelegate` (`bestValidUpdate(in:for:)`) on `UpdaterViewModel` (delegate held strongly; window read fresh per check). The F.2 trap explicitly avoided and regression-tested: `testOutOfWindowLicenseStillValidatesAndGenerates` proves an out-of-window license still validates, stays `.byok`, and `canGenerate` — `expires_at` is never decoded for the window and `isDefinitiveRevocation` is untouched. Design in Appendix F.
- **E5 — Existing BYOK users move off gpt-4o on update (release-note item).** The registry has no gpt-4o, so an updated BYOK user's generations run `gpt-5.4-mini` (fallback) or their picked model. Per plan (same 6 models everywhere), but a behavior change — call it out in the release notes (parallel to D1 for Managed).
- **E6 — RESOLVED: stale OpenAI-only copy corrected (2026-06-11).** The onboarding API-key step itself no longer exists (removed in Phase F — email step replaced it), so the fix was a copy sweep: `OnboardingSteps.swift` already-used subhead ("add your own OpenAI key" → "add your own API keys"), `AppState` `.trialCreditsExhausted` (same change) and `.apiAuth` ("OpenAI rejected your API key" → provider-neutral "Your API key was rejected", since `.auth` can come from any provider's chat call). Settings (`APIAuthSection`) and the paywall were already 3-provider-accurate. Remaining (cosmetic, dev-only): two `PillView` `#Preview` fixtures still use old OpenAI strings. The optional "model declined" refusal copy stays deferred. Original: onboarding copy mentioned only the OpenAI key.
- **E4 — RESOLVED: trial meter bar wired end-to-end (2026-06-11).** App now decodes `trial_credits_limit` from BOTH trial-start verify and resume (`TrialStartResponseDTO.trialCreditsLimit`, optional for old servers), caches it in `TrialCreditsManager.creditsLimit` (UserDefaults, cleared with the grant), surfaces it via `EntitlementStore.trialCreditsLimit`, and `BillingSection`'s trial meter draws the proportional bar (`CreditDisplay.trialFractionRemaining`). Missing limit (older server / pre-update cache) degrades to the bar-less display. Decode + fraction covered in `TrialCreditsTests` / `CreditDisplayTests`. Note: the limit arrives ONLY via trial-start (the Managed `/session`/`/entitlement` snapshot doesn't carry it — trial users never call those), so a user whose token never goes stale won't see the bar until their next resume; harmless. Original: server sent the limit but the app didn't decode it.
- **E3 — LemonSqueezy products don't exist yet (LAUNCH dependency for top-ups + yearly).** Code on both sides is wired, but inert until the LS storefront has: the **Boost ($10/200)** and **Power ($22/500)** top-up products, the **monthly + yearly Managed** variants, and the **$69 BYOK license** product. Their variant/product IDs feed the secrets `LS_VARIANT_TOPUP_BOOST/_POWER`, `LS_VARIANT_PRO` (both Managed ids), `LS_VARIANT_YEARLY`, and the app's `boostTopupCheckoutURL`/`powerTopupCheckoutURL`/BYOK checkout. Until created: top-up chips are hidden (amber notice only). **Create products + fill secrets/URLs before launch.**

## Appendix F — E7 design: BYOK "1 year of updates" enforcement (designed 2026-06-11; BUILT same day per F.0 — see the E7 entry in Appendix E for what shipped)

The $69 BYOK license includes 1 year of updates; after the window closes the installed build keeps working (generation is NEVER gated on this) but newer builds require re-purchase. This section is the design record; the F.0 decisions below were locked and implemented.

### F.0 — DECISIONS LOCKED (2026-06-11) — all client-side, NO backend work
1. **Window source:** client-derived — `license_key.created_at + 1 year`. Decode `createdAt` in `LicenseService` (`LicenseAPIResponse.LicenseKeyObject`), persist it beside the license (Keychain/defaults), refresh on each validate so pre-E7 activations backfill their window on next validate. No server-issued field, no BYOK-order mirroring.
2. **Offline / missing window date:** FAIL-OPEN — if the window date is absent/unreadable, offer updates (matches the billing layer's fail-open contract; never block a payer on an infra hiccup).
3. **Out-of-window UX:** SILENT appcast filtering — out-of-window users simply stop being offered new builds (check says "up to date"); no nag, no re-purchase prompt. They keep their installed build indefinitely.
4. **Re-purchase:** paste-new-key — a re-purchase issues a new LS key; pasting it in Settings sets a new `created_at` → restarts the window. No server-mapped renewal.

**Implementation (when built):** introduce an `SPUUpdaterDelegate` on `UpdaterViewModel` (currently `updaterDelegate: nil`), implement `bestValidUpdate(in:for:)` to filter appcast items by `SUAppcastItem.date ≤ (createdAt + 1yr)`, scoped to `productKind == .byok` only (Managed subscribers keep updating). LS product `expires_at` MUST stay null (the trap: it would flip validate to `status:expired` → `isDefinitiveRevocation` → wrongly blocks generation). Entirely app-side; no migration, no edge-function change.

### F.1 — Data: what LemonSqueezy actually returns (FEASIBLE)

Verified against the official `lemonsqueezy.js` SDK types (LS docs block scraping; the SDK mirrors the License API response shape): the `license_key` object in **all three** License API responses (activate / validate / deactivate) is `{ id, status, key, activation_limit, activation_usage, created_at, expires_at (nullable), test_mode }`.

- **`created_at` IS available** on every response → the window start is obtainable from the calls the app already makes. E7 is feasible as specced.
- **There is NO explicit update-entitlement / update-window field.** LS has no native "1 year of updates" concept — the window must be derived (`created_at` + 1yr) or issued by our own backend.
- The app currently decodes none of this: `LicenseAPIResponse.LicenseKeyObject` (LicenseService.swift) stops at `id/status/activationLimit/activationUsage`. Step 1 of any implementation is adding `createdAt` (the `.convertFromSnakeCase` decoder picks up `created_at` for free) and persisting it next to the license (a Keychain slot alongside `lastValidated`, refreshed on each successful activate/validate so a pre-E7 activation backfills on its next throttled re-validation).

### F.2 — The trap, confirmed in code: never use LS `expires_at` for the window

Setting a license expiry on the LS product flips `validate` to `valid:false, status:"expired"` after a year — and `ValidationResult.isDefinitiveRevocation` (LicenseService.swift) treats `expired` exactly like `disabled` (refund/chargeback): a DEFINITIVE revocation that clears the Keychain license and drops the entitlement out of `.byok`, **blocking generation**, not just updates. The update window must therefore be a SEPARATE, client/backend-owned date derived from `created_at` (or server-issued); the LS product must keep `expires_at` null forever. Corollary: `LicenseKeyStatus.expired` handling stays untouched — it remains the revocation signal for a key that LS genuinely expired.

### F.3 — Hook point: Sparkle updater delegate

`UpdaterViewModel` (UpdaterView.swift) constructs `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, …)` — there is no delegate today, so step 2 is introducing one (a strongly-held object passed at construction, before the updater starts). Two candidate `SPUUpdaterDelegate` methods, compared against the appcast item's publish date (`SUAppcastItem.date`, from `<pubDate>` in apps/web/public/appcast.xml — which our release pipeline already stamps per item):

- **`bestValidUpdate(in:for:)` (preferred):** the delegate filters the appcast to items with `date <= updateWindowEnd` and returns the best of those. An out-of-window user still receives older in-window builds (e.g. a security patch republished inside their window), and auto-checks simply find nothing newer rather than erroring. More code, better behavior.
- **`updater(_:shouldProceedWithUpdate:updateCheck:)` (simpler):** veto the found update by throwing; the thrown `NSError`'s localized description is what Sparkle surfaces. One method, but the UX is a refusal dialog on every check rather than a quiet "you're up to date", and no fallback to in-window builds.

Either way the gate must be scoped to `productKind == .byok` — Managed subscribers are also license-backed (same `LicenseService`) but get updates for as long as the subscription is active; their key's standing already mirrors the sub via the webhook. Trial/expired users (no license) are unaffected.

### F.4 — Sketch of the full shape (for sizing, not commitment)

1. Decode + persist `license_key.created_at` (F.1).
2. Compute `updateWindowEnd` (per F.5 decision) and expose it read-only (e.g. on `LicenseService` or `EntitlementStore`).
3. Updater delegate per F.3, consulting the cached window end synchronously (update checks must not wait on a network validate).
4. UX: a BYOK Settings row ("Updates included until {date}") + an out-of-window re-purchase CTA (BillingLinks.byokCheckoutURL); copy per F.5.
5. Note: client-side date gating is trivially defeated by clock tampering or an old app build — accepted; the stakes are an app update, not server-funded spend.

### F.5 — Decisions needed before building (listed, NOT decided)

1. **Window source:** purchase-date + 1yr derived client-side from LS `created_at` (zero backend work, but the rule is frozen into the client and goodwill extensions are impossible), vs. a server-issued `update_window_end` (our backend would have to start mirroring BYOK orders via the LS webhook — it currently only mirrors Managed subs — but gains grace periods, extensions, and a single source of truth).
2. **Offline / missing-data behavior:** when the cached window date is absent (pre-E7 activation that hasn't re-validated; Keychain read failure) or the device is offline — fail-open (offer updates; matches the billing layer's pervasive fail-open contract) vs. fail-closed (quietly skip; safer revenue-wise, but punishes a paying user over a flaky read).
3. **Out-of-window UX:** silent appcast filtering (checks say "up to date") vs. an explicit "Your year of included updates has ended — renew to get {version}" with the re-purchase CTA; where it lives (update-check dialog vs. Settings row vs. both); exact copy.
4. **Re-purchase mechanics:** LS has no native license renewal — a re-purchase issues a NEW key. Does the user paste the new key (replacing the old, restarting the window), or do we want an LS "upgrade/renewal" product mapped server-side? Affects decision 1.

## Appendix C — Invariants that must NOT regress

1. Credit consumed **only** on fully successful result; failures charge nothing.
2. cap=1 generation slot + idempotency (M1) unchanged — variable charge sits inside the same critical section.
3. Server owns the system prompt; client supplies only `mode` + `model`; `model` never affects the prompt.
4. `generation_log` stores no content (model/provider are non-content metadata).
5. Top-up credits never reset; plan credits never roll over; spend order = plan → top-up (FIFO by expiry).
6. No model gating by plan/tier: subscription + trial both see all 6 models. BYOK sees all 6 but each is selectable only with a key for its provider (key-gating, not tier-gating).
7. Credit UI (price, "~N left", balance, top-up) renders in Managed/Trial ONLY — never in BYOK.
