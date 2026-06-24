# Claude Code handoff prompt — Fix credit overspend (charge into the negative + block when negative)

Copy everything below the line into Claude Code, running from the repo root.

---

You are fixing a money-safety bug in the Zerro credit system. The server-side
`generate` proxy (`supabase/functions/generate`, Deno/TypeScript) and the Postgres
credit ledger let a low-balance user run generations that are **never charged**,
and they can repeat this indefinitely. Read this entire brief, then explore the
referenced files before writing any code.

## The bug (confirmed root cause)

The charge path has three guards in `supabase/functions/generate/handler.ts`:

1. **Floor gate** (step 8, ~lines 255–261): `if (remaining < 1) → 402 out_of_credits`.
2. **Estimate + headroom gate** (step 10.5, ~lines 338–363):
   `if (remaining < estimate - HEADROOM_CREDITS) → 402` (`HEADROOM_CREDITS = 5`).
3. **Consume** (step 12, ~line 401): `account.consume(credits)` calls the
   **all-or-nothing** RPCs `consume_credit` / `consume_combined_credit` /
   `consume_trial_credit`. If the real metered cost exceeds the balance they
   `return null` and spend **nothing**.

The defect: when `consume` returns `null` (real cost > balance), the handler
(~lines 403–440) treats it as a "residual-overshoot race," **returns the generated
prompt for free, and logs `creditsUsed: 0`.** The balance is never decremented, so
the user repeats forever ("unlimited requests with their remaining low credits").

Because consume is all-or-nothing, **a balance can never go negative today** — which
is also why the negative-block requirement isn't met (negatives never occur). The
estimate gate additionally pre-blocks the very generation that should be allowed to
dip negative.

## Target behavior (product decisions — implement exactly this)

1. **The final generation is uncapped.** A user with a spendable balance (≥ 1 credit)
   may run **one** generation of any cost; it is **charged in full** and the balance
   goes **negative**. Remove the pre-generation estimator gate so nothing blocks it.
2. **Block at ≤ 0.** Once the balance is at or below zero, **every** further
   generation is blocked (server + client) until either the monthly allowance renews
   or the user buys a top-up pack. Keep the existing `remaining < 1` floor gate as
   this enforcement point.
3. **New credits start fresh — never net the debt.** When the monthly period renews
   OR a top-up pack is purchased, the user starts from the new balance with the prior
   negative **cleared, not subtracted**. (This already falls out of the architecture
   — see Guardrails — so the job is mostly to NOT break it.)
4. **UI on the negative-going generation:** the expanded response view's bottom-left
   must show the **correct deducted credits** and then **`Out of Credits`** (not the
   raw negative number). The **menu-bar menu** must also show **`Out of Credits`**.
5. **Trial users behave the same as paid** (one uncapped final generation → negative
   → blocked). Apply the change uniformly across the subscription, converted
   (combined), and trial ledgers.

## Part A — New "allow-negative" consume RPCs (new migration)

Add ONE append-only migration (e.g. `supabase/migrations/20260622130000_overspend_allow_negative.sql`).
**Do NOT modify the existing `consume_credit` / `consume_combined_credit` /
`consume_trial_credit` functions** — per the repo's money-safety convention their
semantics must never shift under deployed callers (see the header notes in
`20260609120000_multi_model_credits.sql` and `20260619130000_trial_subscription_link.sql`).
Add new overspend-capable functions instead:

- `consume_credit_overspend(uuid, integer)`
- `consume_combined_credit_overspend(uuid, uuid, integer)`
- `consume_trial_credit_overspend(uuid, integer)`

Each is a near-copy of its all-or-nothing sibling with these differences:

- **Remove the all-or-nothing early `return null`** (the
  `if v_plan_avail + v_topup_avail < p_credits then return null` block, and the
  trial+plan+topup version of it).
- Spend the real availability first, in the existing product order
  (combined: trial → plan period → top-ups FIFO; single: plan → top-ups FIFO), then
  **put any remaining shortfall onto the latest `usage_periods.credits_used`** for
  the subscription paths, or onto `trial_grants.trial_credits_used` for the pure-trial
  path. Those columns have only a `>= 0` CHECK (no upper bound), so they may exceed
  their limit → the balance goes negative.
- **Never drive a `topup_credits` row below zero** — it has a
  `check (credits_used <= credits_total)` constraint. Top-ups are spent only up to
  their real availability; the overspend remainder must land on the plan period
  (or the trial grant), never a top-up row.
- **Return the true (possibly negative) remaining**: single/trial return
  `integer`; combined returns the same `jsonb` shape
  `{ remaining, trial_spent, plan_spent, topup_spent }` with `remaining` possibly
  negative. `remaining = (real availability across buckets) - p_credits`.
- **Return `NULL` only for a genuinely non-spendable account** (no spendable
  `usage_periods` row for an active/past_due sub; missing/unverified trial grant).
  That is the only `null` path that survives.

Preserve every locking / atomicity property unchanged: the same `FOR UPDATE` lock
order (trial grant → latest period → top-ups FIFO by expiry), `set search_path = ''`,
the `p_credits <= 0` guard, and append-only conventions. Add explicit
`grant execute … to service_role` for each new overload (Postgres treats overloads
as distinct functions). Mirror the comment style of the existing migrations.

## Part B — Repoint the store at the new RPCs

In `supabase/functions/generate/store.ts`:

- `SupabaseBillingStore.consumeCredit` → call `consume_credit_overspend`.
- `consumeCombinedCredit` → call `consume_combined_credit_overspend`.
- `consumeTrialCredit` → call `consume_trial_credit_overspend`.

Keep the method signatures and return types the same (they already return
`number | null` / `CombinedSpendResult | null`); the only change is that the returned
remaining may now be negative. Update the interface doc comments in `BillingStore`
(the "all-or-nothing … or null …" wording) to describe the new "always spends; balance
may go negative; null only for a non-spendable account" semantics.

**Do NOT touch** `SupabaseBillingStore.creditsRemaining` — keep the
`Math.max(0, creditsLimit - used)` clamp at ~line 167 (see Guardrails).

## Part C — Handler: remove the estimator gate and the free-result path

In `supabase/functions/generate/handler.ts`:

- **Keep** the step-8 floor gate (`if (remaining < 1) → 402`). This is the ≤ 0 block.
- **Delete the estimate + headroom gate** (step 10.5, ~lines 338–363) entirely, so
  the final generation is uncapped. The audio-seconds gate (step 10) and all input
  fuses stay.
- **Delete the free-result fallback** (the `if (afterConsume === null) { … }` branch
  at ~lines 403–440). With allow-negative consume, a spendable account is always
  charged. Replace that branch with: treat `null` strictly as a non-spendable account
  (defensive — it's already gated at resolve time and step 8) → log a failure row
  (`creditsUsed: null`) and return `402 out_of_credits`; **never return a prompt
  without charging.**
- On success, log `creditsUsed: credits` (the metered charge) and return
  `credits_remaining: afterConsume` (which may be negative) and
  `credits_charged: credits`. The idempotency cache should store/replay these as-is.

Then remove the now-dead estimator machinery (grep for callers first to be safe):
`estimateGenerationCredits` in `cost.ts`, and `HEADROOM_CREDITS` + the estimator
token constants in `config.ts` (`OUTPUT_TOKENS_ESTIMATE`, `FRAME_TOKENS_*`,
`SYSTEM_PROMPT_TOKENS`) **only if** nothing else references them. The metered charge
(`creditCostForModel` / `estimatedCostUsd` for the real post-chat cost) is unchanged —
do not touch it.

## Part D — Client UI: show "Out of Credits"

In `apps/desktop/Zerro` (Swift/SwiftUI):

- `Services/Billing/CreditDisplay.swift`:
  - `chargeLine(charged:remaining:)` (the "−4 credits · 96 left" builder): when
    `remaining <= 0`, render the balance segment as **`Out of Credits`** instead of
    `"<n> left"`, e.g. `"−30 credits · Out of Credits"`. The deducted amount must stay
    correct (it's the server's `credits_charged`).
  - Add a small shared helper (e.g. `balanceLabel(_ balance: Int) -> String`) returning
    `"Out of Credits"` for `balance <= 0`, else the existing `creditsHeadline` string,
    and use it in both spots below so the rule lives in one place.
- `Surfaces/MenuBarPanel/MenuBarPanelView.swift` (~line 528, the
  `"\(snapshot.creditsRemaining) credits left"` line): show **`Out of Credits`** when
  `snapshot.creditsRemaining <= 0`.
- Ensure the post-generation path updates `EntitlementStore.managedSnapshot.creditsRemaining`
  with the server's returned value (which may be ≤ 0) so the **next**
  `preflightBlock` (`EntitlementStore.swift` ~line 503, `creditsRemaining <= 0 →
  .outOfCredits`) blocks immediately. Do not clamp the snapshot up to a positive number.
- The block → paywall path already exists (`.outOfCredits` → `PaywallCopy.topup`,
  "Add Credits"). Update the `PaywallCopy.topup` subheadline in
  `Surfaces/Paywall/PaywallView.swift` to also mention waiting for next month, e.g.
  "Top up now to keep generating, or wait for next month's credits to renew." Verify
  the paywall opens on a negative/zero snapshot.

## Tests (required)

- `supabase/functions/generate/handler_test.ts`: replace the existing
  uncharged/free-result test(s) (search for `uncharged_result_returned` / the
  `credits_charged: 0` free path) with:
  - subscriber with a small positive balance + a generation whose metered cost
    exceeds it → success, `credits_remaining` negative, `credits_charged` = full cost,
    `logGeneration` called with `creditsUsed = cost`, provider WAS called.
  - follow-up request with a ≤ 0 balance → `402 out_of_credits`, provider NOT called.
  - converted (combined) user overspend, and trial user overspend → same negative-then-
    blocked behavior.
  - a generation that previously would have been rejected by the estimate gate now
    proceeds (gate removal).
- SQL: add tests under `supabase/test` (follow the existing harness) for each new RPC:
  overspend pushes `usage_periods.credits_used` above `credits_limit` (and
  `trial_credits_used` above its limit for the trial fn), top-up rows are never driven
  below zero, the returned `remaining` is negative, and `NULL` is returned only for a
  non-spendable account. Verify renewal (a new `usage_periods` row) yields a fresh
  positive balance with no carry-over.
- Swift: extend the `CreditDisplay` tests (and any menu-bar snapshot tests) for the
  `Out of Credits` rendering at `balance <= 0` (both `chargeLine` and the balance
  label).

Run `deno test` for the generate function and the app's Swift test target; everything
must pass.

## Guardrails — do NOT change

- **Keep** the `Math.max(0, creditsLimit - used)` clamp in `store.ts`
  `creditsRemaining`, and the `greatest(0, …)` plan/trial availability math in the
  RPCs. This is precisely what makes new monthly/top-up credits read as their own
  fresh bucket and **prevents the negative from being subtracted** from them. Do not
  add any debt carry-forward.
- **Do not** modify the existing all-or-nothing `consume_*` functions; add new ones.
- **Keep** the floor gate at `remaining < 1` (block at ≤ 0). Do not lower it to
  `< 0` (a balance of exactly 0 stays blocked, consistent with the client's existing
  `<= 0` preflight).
- **Keep** all input fuses (`MAX_AUDIO_SECONDS`, `MAX_FRAMES`, `MAX_PAYLOAD_BYTES`,
  transcript/click/OCR caps), the post-Whisper seconds gate, the concurrency cap (1),
  the rate limiter, and idempotency. These bound a single overspend and prevent abuse.
- **Privacy (§14.5):** `generation_log` and the idempotency cache rules are unchanged —
  never log transcript/audio/frames/prompt content.
- The metered charge (`creditCostForModel`, real post-chat cost) is unchanged.

## Acceptance criteria

1. A subscriber with a small positive balance who triggers a costlier generation is
   **charged the full metered cost**, the balance goes **negative**, and the response
   shows the correct deduction plus **`Out of Credits`** in the expanded response
   view's bottom-left.
2. With a ≤ 0 balance, the next generation is blocked **server-side** (`402
   out_of_credits`, no provider call) **and client-side** (preflight → paywall with
   the top-up / wait-for-renewal copy).
3. Buying a top-up pack **or** the monthly renewal lets the user generate again with
   the **full new balance**; the prior negative is **not** subtracted.
4. Trial users behave identically (one uncapped final generation → negative → blocked).
5. The menu-bar menu shows **`Out of Credits`** when the balance is ≤ 0.
6. **No free / uncharged-result path remains** — every successful generation is
   charged.

Work in small, reviewable commits (migration + store, then handler, then client, then
tests). Explore each referenced file before editing, and report any spot where the
real code diverges from the line references above.
