# Handoff: Trial credits stranded when a generation costs more than the trial remainder

## The bug (verified)

When a trial user has a small trial balance left and their next recording costs **more** credits than that remainder, the system does **not** spend the remaining trial credits. Instead:

1. The `generate` proxy returns `402 out_of_credits` (the whole recording is blocked).
2. The user is prompted to subscribe; the recording is parked via `PendingPaidGeneration`.
3. After they pay, the *same* recording re-runs against the **paid subscription** token and the **full** metered cost is charged to the paid plan.

Net result: leftover trial credits are stranded (never spent), and the full generation cost lands on the paid usage limit instead of only the difference.

## Root cause (traced through the code)

The architecture forbids cross-ledger spending, by design at three layers:

1. **One generation = one ledger.** `supabase/functions/generate/handler.ts` resolves the session JWT to exactly one identity via `claims.kind`:
   - `kind: "trial"` → `trial_grants`, spends via `consume_trial_credit(grant_id, credits)` (`resolveTrial`, ~line 517).
   - `kind: "subscription"` → `usage_periods` + `topup_credits`, spends via `consume_credit(sub_id, credits)` (`resolveSubscription`, ~line 498).
   There is no path that spends against both in one request.

2. **Each spend is strictly all-or-nothing.** In migration `supabase/migrations/20260609120000_multi_model_credits.sql`:
   - `consume_trial_credit(uuid, integer)` is a single conditional UPDATE gated on `trial_credits_used + p_credits <= trial_credits_limit`. If the cost exceeds the remaining trial balance it updates **zero rows** and returns NULL ("nothing spent").
   - `consume_credit(uuid, integer)` does the same against the combined plan + top-up balance.
   The estimate/headroom gate in `handler.ts` (step 10.5, ~line 346) returns `402 out_of_credits` whenever `remaining < estimate - HEADROOM_CREDITS`, so an over-budget recording never even reaches `consume_*`.

3. **The two ledgers are not reliably linked.** `trial_grants` (`supabase/migrations/20260601120000_billing_schema.sql`, ~line 110) and `subscriptions` (`subscriptions.email_normalized`, migration `20260616130000_subscriptions_email.sql`) share **no foreign key**. The only common field is `email_normalized`, and even that is normalized DIFFERENTLY on each side (trial collapses Gmail dots/+tags to defeat farming; subscriptions does not), so it is not a dependable join.

Client side, `ManagedProxyClient.parse` (`apps/desktop/Zerro/Services/Managed/ManagedProxyClient.swift`, ~line 584) maps `402` → `ManagedGenerationError.outOfCredits`, which `AppState` surfaces as `.trialCreditsExhausted` and parks via `PendingPaidGenerationStore` (`apps/desktop/Zerro/Services/Billing/PendingPaidGeneration.swift`). The resume re-runs the recording against the paid token (`reason: .trialCreditsExhausted`), charging the full cost to the paid plan.

## Desired behavior

**Cross-ledger spend in a single generation:** when a trial user's recording costs more than their remaining trial credits, first drain the trial remainder, then charge **only the difference** to the paid subscription — atomically, within the same `/generate` request. No stranded trial credits, no full-cost double-charge.

## Your task

Design and implement the cross-ledger spend. This is a money-safety-critical change, so it must be atomic, double-spend-safe, and idempotent-replay-safe in the same way the existing single-ledger paths are. Before writing code, produce a short design note covering the decisions below, because they materially change the implementation.

### Decisions to make first (and surface in your design note)

1. **How does the proxy learn about BOTH ledgers in one request?** Today the session JWT carries a single `kind` (`trial` | `subscription`). For a trial user who has ALSO subscribed, the proxy must be able to resolve both the trial grant and the subscription. Options to evaluate:
   - Establish a real link between `trial_grants` and `subscriptions` (e.g. a nullable FK or a join table), set when a trial user converts to paid. Note the `email_normalized` normalization mismatch — do NOT rely on email matching alone; if you go this route you must reconcile normalization or link explicitly at conversion time (in `lemonsqueezy-webhook`).
   - Carry both identities in the session token / mint a token that references both.
   - Resolve the paired ledger server-side at generate time from a stored link.

2. **What's the spend order and is it the right product call?** Proposed: spend the perishable trial remainder FIRST, then plan credits, then top-ups (FIFO by expiry). Confirm this matches product intent.

3. **Atomicity.** The existing functions get their double-spend guarantee from a single statement / a single row lock (`consume_credit` locks the latest `usage_periods` row as the per-subscription mutex; `consume_trial_credit` locks the grant row). A cross-ledger spend touches BOTH a `trial_grants` row and `usage_periods`/`topup_credits` rows, so you need a single Postgres function that:
   - takes a consistent lock order across both tables (define it, e.g. trial grant → period → top-ups, and document it to avoid deadlocks),
   - checks combined availability (trial remainder + plan + top-ups) BEFORE any write,
   - is all-or-nothing across both ledgers,
   - returns enough for the handler to report `credits_charged` split by source if needed.
   Prefer a new RPC (e.g. `consume_combined_credit(p_grant_id, p_subscription_id, p_credits)`) over orchestrating two existing RPCs from the handler (two RPCs = two transactions = a window where one succeeds and the other doesn't).

4. **Idempotency replay (M1).** The handler caches a charged result keyed on `account.key` + `Idempotency-Key` and replays it without re-charging. A combined spend must replay correctly too — make sure the cached `credits_charged` / `credits_remaining` reflect the combined spend, and that the `account.key` scheme still uniquely identifies the (trial+sub) identity so a replay can't be mis-scoped.

5. **Concurrency cap.** The cap-1 slot (`acquire_slot` / `acquire_trial_slot`) is what makes check-then-consume-on-success safe. With one request now spending against two ledgers, decide which slot (or both) is held so two in-flight generations for the same user can't both pass the combined-availability check. Keep the existing "deduct only on success" ordering.

6. **`buildEntitlementSnapshot`** (`supabase/functions/_shared/entitlement.ts`) and the displayed `credits_remaining` must stay consistent with whatever the combined spend path will actually allow — the file's header explicitly promises the displayed number matches the spend path. If a trial+paid user now has a combined spendable balance, the snapshot must reflect it.

7. **Client changes.** If the combined-spend path means an over-budget recording should NO LONGER be blocked as `trialCreditsExhausted` for a user who also has a paid plan, update the preflight gate (`EntitlementStore.preflightBlock` / `routesThroughManagedProxy` in `apps/desktop/Zerro/Services/Billing/EntitlementStore.swift`) and the failure mapping so the recording proceeds and is charged across ledgers instead of being parked. Make sure `PendingPaidGeneration` resume still works for the genuine "no paid plan yet" case.

### Implementation guidance

- Add a new append-only migration under `supabase/migrations/` (follow the existing header/comment + RLS deny-by-default + explicit `service_role` grant conventions; see `20260609120000_multi_model_credits.sql` as the template). Do NOT modify the existing `consume_credit` / `consume_trial_credit` signatures — add a new function.
- Wire the new RPC through `supabase/functions/generate/store.ts` (`BillingStore`) and the `ResolvedAccount` abstraction in `handler.ts` so the money-safety ordering stays in one place.
- If you add a trial↔subscription link, set it at conversion time in `supabase/functions/lemonsqueezy-webhook/` and backfill consideration for existing converted users.

### Tests (required)

- Server: extend `supabase/functions/generate/handler_test.ts` and add coverage for the new RPC — combined balance sufficient (spends trial first, bills difference to paid), combined balance insufficient (all-or-nothing, nothing spent, 402), trial-only sufficient, paid-only sufficient, idempotent replay of a combined charge, concurrency (two in-flight requests can't double-spend the shared remainder).
- Client: extend `apps/desktop/ZerroTests/PreflightGateTests.swift`, `TrialCreditsTests.swift`, and `PendingPaidGenerationTests.swift` for the new "trial user with a paid plan, over-budget recording proceeds and is charged across ledgers" path, and confirm the no-paid-plan case still parks + resumes.

### Verification before you call it done

- Run the Deno tests for the `generate` function and the Swift `ZerroTests` suite.
- Walk through the atomicity argument in your design note against the new function's lock order and confirm no deadlock and no partial cross-ledger charge is possible.
- Confirm `buildEntitlementSnapshot` output matches what the new spend path allows for a trial+paid user.

## Key files

- `supabase/functions/generate/handler.ts` — the proxy; identity resolution + spend ordering.
- `supabase/functions/generate/store.ts` — `BillingStore`, where RPCs are called.
- `supabase/functions/_shared/entitlement.ts` — displayed combined balance.
- `supabase/migrations/20260609120000_multi_model_credits.sql` — current `consume_credit` / `consume_trial_credit` (template + the all-or-nothing logic to extend).
- `supabase/migrations/20260601120000_billing_schema.sql` — `trial_grants` table.
- `supabase/migrations/20260616130000_subscriptions_email.sql` — the email-normalization mismatch to be aware of.
- `supabase/functions/lemonsqueezy-webhook/` — where a trial↔sub link would be set on conversion.
- `apps/desktop/Zerro/Services/Billing/EntitlementStore.swift` — preflight gate + routing.
- `apps/desktop/Zerro/Services/Billing/PendingPaidGeneration.swift` — park/resume.
- `apps/desktop/Zerro/Services/Managed/ManagedProxyClient.swift` — 402 → error mapping.
- `apps/desktop/Zerro/AppState.swift` — `RecordingFailureReason` / failure surfacing.

## Do NOT

- Do not orchestrate two separate RPCs from the handler to fake cross-ledger spend — that splits the transaction and opens a partial-charge window.
- Do not rely on `email_normalized` equality alone to pair a trial grant with a subscription (the two sides normalize differently).
- Do not change the existing `consume_credit(uuid, integer)` / `consume_trial_credit(uuid, integer)` semantics; add a new function.
