# Task: Switch Managed credits from fixed per-model price to metered actual cost

## Goal (plain English)

Today every generation is charged a **fixed credit price per model** (`creditPrice`
in `models.ts`: 2/4/5/7/10/11), and the real cost is only charged when an
anti-abuse circuit-breaker trips. We are switching to **always charging the real
metered cost**: `credits_charged = ceil(est_cost_usd / $0.01)`. Because
`USD_PER_CREDIT` is already `$0.01`, a user's monthly credit allowance becomes a
true **dollar cost cap** (Pro's 300 credits = a $3 hard COGS ceiling per user per
period → ~80% gross margin floor on the $15 plan).

Three secondary changes ride along:
1. The out-of-credits gate must work **without a known price up front** (the real
   cost isn't known until after the chat call) — solved with a pre-chat estimate
   plus headroom (see Part A3).
2. The model picker stops showing any per-model credit cost. It just lists the
   models with **Gemini 3.5 Flash** kept as the recommended default.
3. The per-tier caps and trial allowance are retuned (Part C — **needs your
   sign-off on the numbers**).

This touches the server (`/generate` edge function), the desktop app (Swift), the
triple-mirror model registry, the eval harness, and tests. Scope = full stack.

---

## Locked decisions (from product discussion)

- **Always meter.** `credits_charged = ceil(est_cost_usd / USD_PER_CREDIT)`, with a
  **floor of 1 credit** per successful generation.
- **Gate = estimate + headroom.** Before the chat call, estimate the cost from the
  known inputs (frame count, transcript, OCR, fixed system prompt) plus a
  conservative output-token allowance. Allow if `balance >= estimate - HEADROOM`.
  Charge the **actual** metered cost afterward.
- **Residual overshoot is acceptable and already handled.** `consumeCredit` is
  all-or-nothing; the handler already has an "couldn't charge → return the result
  once, free, and log it" path (`afterConsume === null`). We keep that as the
  residual-overshoot behavior. A single recording is hard-capped (3 min / ≤28
  keyframes ⇒ ~$0.44 ≈ 44 credits), so the worst-case free result is pennies.
- **Picker shows no per-model price.** Keep Flash recommended.
- **Caps:** Pro stays 300 credits ($3 cap). Starter / Trial / top-ups retuned —
  see Part C, pending sign-off.

---

## Current-state reference (verified in repo)

- `supabase/functions/generate/config.ts`
  - `USD_PER_CREDIT = 0.01` (the unit definition — **keep**).
  - `CIRCUIT_BREAKER_MULTIPLIER` (default 3) — becomes redundant under metering.
- `supabase/functions/generate/cost.ts`
  - `estimatedCostUsd(audioSeconds, provider, model, inTok, outTok)` → STT + chat $.
  - `chatCostUsd(...)`, `sttCostUsd(...)`, `CHAT_PRICING` (per-`provider:model`
    $/1M-token table, incl. Gemini Pro tiered >200k), `STT_PRICING`
    (`openai:whisper-1` = $0.006/min).
  - `creditCostForModel(modelId, estCostUsd)` → returns fixed `creditPrice` unless
    `estCost > CIRCUIT_BREAKER_MULTIPLIER * fixed * USD_PER_CREDIT`, else metered.
- `supabase/functions/generate/models.ts` — `MODEL_REGISTRY` (id, provider,
  displayName, `creditPrice`, recommended, enabled), `ALLOWED_MODELS`, `modelById`,
  `DEFAULT_MODEL_ID` (the `recommended` entry = Gemini 3.5 Flash).
- `supabase/functions/generate/handler.ts` — charge flow:
  - Step 8: availability check `remaining < modelEntry.creditPrice` → 402
    `{ error: "out_of_credits", credits_remaining, model_price }`. **(runs BEFORE
    Whisper.)**
  - Step 9: Whisper transcribe (skipped if `has_speech:false`).
  - Step 10: true-seconds gate (can reject before chat).
  - Step 11: compose system prompt + interleave + chat call.
  - Step 12: `estCost = estimatedCostUsd(...)`; `credits = creditCostForModel(...)`;
    `afterConsume = account.consume(credits)`; `null` → free-result path.
  - Step 14: returns `{ prompt, usage, credits_remaining, credits_charged }`.
- `supabase/functions/_shared/config.ts` — `CREDITS_STARTER=100`, `CREDITS_PRO=300`,
  `creditsForTier`, `TOPUP_BOOST_CREDITS=200`, `TOPUP_POWER_CREDITS=500`,
  `TOPUP_EXPIRY_MONTHS=12`. Comment notes Managed plan = $15/mo + $144/yr.
- `supabase/functions/trial-start/config.ts` — `TRIAL_CREDITS=40`.
- App (Swift):
  - `apps/desktop/Zerro/Services/ModelRegistry.swift` — **THIRD MIRROR** of
    `models.ts` (id/provider/displayName/shortName/`creditPrice`/recommended/enabled).
  - `apps/desktop/Zerro/Services/Billing/CreditDisplay.swift` — `estimatedLeft`,
    `isLowBalance(balance, selectedModelPrice)`, `creditsHeadline`, `translationLine`.
  - `apps/desktop/Zerro/Surfaces/MenuBarPanel/ModelPickerSubmenu.swift`,
    `Settings/Sections/ModelSection.swift` — picker UI (shows "~N left" today).
  - `apps/desktop/Zerro/Services/Managed/ManagedProxyClient.swift` — parses
    `/generate` response incl. `credits_charged` / `out_of_credits`.
  - `apps/desktop/Zerro/Surfaces/Pill/PillView.swift` — post-generation surface.
- Eval mirror: `apps/desktop/Scripts/eval-models.mjs` (`CHAT_PRICING` + model list).

---

## Part A — Server: `supabase/functions/generate`

### A1. `creditCostForModel` → always metered (`cost.ts`)
Replace the fixed/breaker logic with a pure metered charge:

```ts
export function creditCostForModel(modelId: string, estCostUsd: number | null): number {
  const entry = modelById(modelId);
  if (!entry) throw new Error(`creditCostForModel: unknown model '${modelId}'`);
  // Unpriced model / missing usage → fall back to the per-model typical estimate
  // (keep a small fallback on the registry; never 0, never block).
  if (estCostUsd === null || !Number.isFinite(estCostUsd)) return entry.fallbackCredits;
  return Math.max(1, Math.ceil(estCostUsd / USD_PER_CREDIT)); // floor of 1 credit
}
```

- Remove the `CIRCUIT_BREAKER_MULTIPLIER` import/branch here.
- **Decision flagged:** the old `creditPrice` field is no longer a charge. Keep a
  per-model `fallbackCredits` (rename of `creditPrice`) used ONLY when est cost is
  unavailable, so a pricing gap never charges 0 or blocks. See A7.

### A2. New preflight estimator (`cost.ts`)
Add a function that estimates credits from known inputs, before the chat call:

```ts
export function estimateGenerationCredits(args: {
  provider: string; model: string;
  frameCount: number; transcriptChars: number; ocrChars: number;
  audioSeconds: number;
}): number
```

Estimate **input tokens** as:
`SYSTEM_PROMPT_TOKENS + frameCount * FRAME_TOKENS[provider] + ceil(transcriptChars/4)
+ ceil(ocrChars/4)`; **output tokens** = `OUTPUT_TOKENS_ESTIMATE` (conservative).
Feed those into the existing `estimatedCostUsd(...)` (it already prices
input/output per model + STT), then `ceil(usd / USD_PER_CREDIT)`.

New tunable constants in `config.ts` (env-overridable, matching existing style) —
**proposed starting values, please confirm:**

| Constant | Proposed | Rationale |
|---|---|---|
| `SYSTEM_PROMPT_TOKENS` | measure once from `composedSystemPrompt()` (~2–4k) | fixed floor every request |
| `FRAME_TOKENS` gemini | 1120 | ProcessingConfig note: `media_resolution_high` |
| `FRAME_TOKENS` openai | ~1100 (6 × 512px tiles, 16:9) | tune vs real data |
| `FRAME_TOKENS` anthropic | ~1200 | tune vs real data |
| `OUTPUT_TOKENS_ESTIMATE` | 3000 | conservative; real avg out ≈ 1.5–3k in `generation_log` |
| `HEADROOM_CREDITS` | 5 | the "21 left vs est-22 but really-19" tolerance |

> Calibration hook: log the **keyframe count** in `generation_log` (a new nullable
> `frame_count int` column, mirrors the `duration_seconds` column already added) so
> `FRAME_TOKENS` and `OUTPUT_TOKENS_ESTIMATE` can be retuned from real
> `(frames, tokens_in, tokens_out)` after launch — same one-line-edit posture as
> the `creditPrice` calibration note.

### A3. Move + rewrite the gate (`handler.ts`)
- **Keep a cheap pre-Whisper floor check** (replaces old step 8): if
  `creditsRemaining < 1` → 402 immediately (don't pay for Whisper on an empty
  account). This is the only check before STT.
- **Add the real gate AFTER Whisper, before the chat call** (between step 10 and
  step 11): compute `estimate = estimateGenerationCredits({... transcriptChars from
  segments, frameCount from parsed frames, ocrChars ...})`. If
  `creditsRemaining < estimate - HEADROOM_CREDITS` → 402
  `{ error: "out_of_credits", credits_remaining, estimate }`. (STT is already paid;
  log `success:false` with `sttCostUsd(measured)` like the existing pre-chat
  rejections do.)

### A4. Charge actual after chat (`handler.ts` step 12)
No change to the shape: still `credits = creditCostForModel(model, estCost)` then
`afterConsume = account.consume(credits)`. The `afterConsume === null` free-result
path stays as the residual-overshoot handler. Confirm the floor-of-1 from A1 means
even a tiny recording charges ≥1 credit.

### A5. 402 response contract
Replace `model_price` (fixed) with `estimate` everywhere the 402 is produced and
consumed. The app's top-up prompt currently reads `model_price`; update both ends
(see B5). Keep `credits_remaining`.

### A6. `config.ts`
- Keep `USD_PER_CREDIT = 0.01`.
- Remove `CIRCUIT_BREAKER_MULTIPLIER` (and its env) — metering is now the default,
  not an exception. Grep for all usages.
- Add the A2 constants.

### A7. `models.ts`
- Rename `creditPrice` → `fallbackCredits` (used only by A1's null-cost fallback),
  OR keep the name and document that it's now a fallback estimate, not the charge.
  **Recommend rename** to prevent "this is the price" confusion. Update the
  triple-mirror note. Keep `recommended: true` on `gemini-3.5-flash`.

---

## Part B — Desktop app (Swift)

### B1. `ModelRegistry.swift` (third mirror)
Mirror A7: rename `creditPrice` → `fallbackCredits` (or drop from the app entirely
since the picker no longer displays it — but keep the field if any code still needs
a fallback). Keep id/provider/displayName/recommended/enabled. Flash stays
recommended. Update the "KEEP IN SYNC" note.

### B2. Picker UI — remove per-model cost
Remove the "~N left" per-row text and any per-model credit/translation line; render
each model by name with the "Recommended" badge on Gemini 3.5 Flash only. Callers
to update (verified):
- `apps/desktop/Zerro/Surfaces/MenuBarPanel/ModelPickerSubmenu.swift` — drops the
  `estimatedLeft:` row value (~L61–62, the `estimatedLeft` struct field ~L130) and
  the `translationLine` (~L111).
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift` —
  `CreditDisplay.estimatedLeft(...)` call (~L576).
- `apps/desktop/Zerro/Surfaces/Settings/Sections/ModelSection.swift` — any per-model
  cost rendering.

### B3. `CreditDisplay.swift`
- `estimatedLeft(balance, creditPrice)` and `translationLine(...)` are per-model —
  remove or stop calling them once B2 + BillingSection no longer use them (grep
  to confirm zero callers before deleting).
- `isLowBalance(balance, selectedModelPrice)` → replace with a price-agnostic
  threshold, e.g. `isLowBalance(balance) { balance <= LOW_BALANCE_CREDITS }`
  (propose `LOW_BALANCE_CREDITS = 10`). Update the caller in
  `Settings/Sections/BillingSection.swift` (~L695) and the generation-flow top-up
  prompt.
- `BillingSection.swift` also calls `translationLine` (~L631, ~L658) for the usage
  meter — decide whether to keep a single balance-only helper there or drop it.
- Keep `creditsHeadline` (the "N credits" headline is unchanged).

### B4. Post-generation surface (`AppState.swift` + `PillView.swift`)
`AppState.swift` already parses `(credits_charged, credits_remaining)` from the
`/generate` 200 (~L433 doc, consumed ~L1629–1630, with a pre-D2 fallback when
`credits_charged` is absent). Surface the **actual** `credits_charged` + remaining
in the post-generation pill/toast (`PillView.swift`) — this is the only place a
user sees per-recording cost. Copy suggestion: "Used N credits · M left".

### B5. Out-of-credits handling (`ManagedProxyClient.swift` + `AppState.swift`)
- `ManagedProxyClient.swift`: parse the new 402 field `estimate` (was
  `model_price`).
- `AppState.swift`: the `.outOfCredits` `RecordingFailureReason` (~L179, mapped
  ~L840/849, messaged ~L270/1708/1762) drives the top-up prompt — update any copy
  that referenced the per-model price; use `estimate`/`credits_remaining` instead.
- Confirm `credits_charged` parsing is otherwise unchanged.

### B6. Tests
Update: `CreditDisplayTests`, `ModelRegistryTests`, `ManagedProxyClientTests`,
`PillView` previews referencing credit copy, `TrialCreditsTests`. Remove assertions
tied to fixed per-model pricing.

---

## Part C — Caps & trial retune (NEEDS SIGN-OFF)

Under metering, `credits = cents of real COGS`, so each allowance is a hard dollar
cap. Proposed (`_shared/config.ts` + `trial-start/config.ts`):

| Knob | Current | Proposed | Cost cap | Notes |
|---|---|---|---|---|
| `CREDITS_PRO` | 300 | **300 (keep)** | $3.00 | $15/mo ⇒ ~80% margin floor |
| `CREDITS_STARTER` | 100 | **confirm** | $1.00 | **Need Starter's monthly price** to set with margin parity |
| `TRIAL_CREDITS` | 40 | **80 (propose)** | $0.80 | 40 ≈ only 1–2 gpt-5.5 recordings; 80 lets a new user actually evaluate |
| `TOPUP_BOOST_CREDITS` | 200 ($10) | keep / confirm | $2.00 | 80% margin on the pack |
| `TOPUP_POWER_CREDITS` | 500 ($22) | keep / confirm | $5.00 | 77% margin on the pack |

**Heads-up — this changes recordings-per-plan even though the number "300" is
unchanged.** Old fixed prices (gpt-5.5 = 11 credits) under-charged premium models;
metering charges the real ~24 credits. So Pro goes from ~27 → ~13 gpt-5.5
recordings/month (≈55 on Flash). That's the intended margin fix, but billing copy
and onboarding should set the expectation ("most recordings cost a few credits;
premium models more").

**I need from you:** Starter's monthly price (to set its cap), and sign-off on the
Trial bump (40 → 80) and the top-up amounts.

---

## Part D — Mirrors & eval harness

- `apps/desktop/Scripts/eval-models.mjs`: mirror the `models.ts` field
  rename (A7) and keep `CHAT_PRICING` in sync with `cost.ts` (existing F8 contract).
- If `eval-models.mjs` reproduces the charge logic, update it to the metered
  formula so eval cost numbers match production.

---

## Part E — Tests & verification

- `cost_test.ts`: replace circuit-breaker tests with (1) metered `creditCostForModel`
  (incl. floor-of-1 and null-cost fallback), (2) `estimateGenerationCredits` for a
  light recording (few frames, short transcript) vs a heavy one (28 frames, long
  transcript) — assert heavy > light and both in a sane range.
- `handler_test.ts`: (1) pre-Whisper empty-balance 402; (2) post-Whisper estimate
  gate with headroom (balance just below estimate-minus-headroom blocks; just above
  passes); (3) actual charge = metered after success; (4) residual overshoot →
  existing free-result path still fires.
- Swift: update B6 tests; add a CreditDisplay test for the price-agnostic
  `isLowBalance`.
- Manual smoke: record one short clip and one long/busy clip on Flash and on
  gpt-5.5; confirm `credits_charged` ≈ real `est_cost_usd × 100` and that the
  response view shows it.
- Migration: add nullable `frame_count int` to `generation_log` (calibration hook,
  A2) — additive, mirrors the `duration_seconds` add; existing rows stay NULL.

---

## Open items requiring your decision before/while implementing

1. **Starter monthly price** → to set `CREDITS_STARTER`.
2. **Trial bump** 40 → 80? (recommend yes)
3. **Tunable defaults** in A2 (`HEADROOM_CREDITS=5`, `OUTPUT_TOKENS_ESTIMATE=3000`,
   `FRAME_TOKENS`, `SYSTEM_PROMPT_TOKENS`) — confirm or adjust.
4. **Remove the circuit-breaker** entirely (recommend yes) vs keep as a hard
   per-recording ceiling.
5. **Rename `creditPrice` → `fallbackCredits`** (recommend yes) vs remove the field.
