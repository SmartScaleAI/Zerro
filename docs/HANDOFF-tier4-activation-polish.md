# Claude Code handoff — Tier 4 analytics (activation/economics polish) + checkout-coverage fix

Final analytics tier for the Zerro macOS app: complete the checkout funnel
coverage (carryover from Tier 3), add the activation/economics events, and ship
the onboarding step-view funnel. After this the app's instrumentation matches
the plan's high-value set.

## Read first
- `docs/HANDOFF-tier3-monetization.md` (esp. §0 identity + the `BillingLinks.checkoutURL` helper it added),
  `docs/ANALYTICS-ONBOARDING-STEP-VIEWS-PLAN.md`, and `docs/ANALYTICS-POSTHOG-PLAN.md` §4.2/§4.7/§4.9.

## Ground rules (binding)
- All events go through `Observability/Analytics.swift`. Metadata only — model
  ids, enums, booleans, counts. Never content, paths, hotkeys, emails, balances.
- Behind the existing opt-out gate. Keep diffs focused; match surrounding style.

---

## 0. Checkout-coverage fix (carryover from Tier 3)

Tier 3 instrumented only four checkout entry points. Other genuine checkout
opens were left un-plumbed, so `checkout_opened` undercounts AND their
server-side `subscription_activated` falls back to an unstitched
`ls:<subscription_id>`. Wire every remaining **checkout** open through the
existing `BillingLinks.checkoutURL(_:product:)` helper + a `checkout_opened`
capture.

Genuine checkout sites still needing instrumentation:
- `Settings/Sections/BillingSection.swift`
  - line ~468: the upgrade row — only the `proCheckoutURL` (NOT managed) branch → `subscription_pro`.
  - line ~613: `Button("Upgrade to Managed")` → `subscription_pro`.
  - line ~653 / ~657: Boost / Power top-ups → `topup_boost` / `topup_power`.
  - line ~698: the `byokCheckoutURL` (NOT licensed) branch → `byok`.
- `Surfaces/MenuBarPanel/MenuBarPanelView.swift`
  - line ~693: the menu-bar subscription upgrade row (`subscriptionCheckoutURL(tier: .pro)`) → `subscription_pro`.

**Do NOT instrument `customerPortalURL` opens** (BillingSection ~299/~468-managed/~698-licensed,
MenuBarPanelView ~568) — the portal is for managing an existing subscription,
not a checkout. No `checkout_opened`, no distinct_id plumbing there.

Suggested: add a small `openCheckout(_ url: URL, product:)` helper in
`BillingSection` (decorate via `BillingLinks.checkoutURL`, fire `checkout_opened`,
then `NSWorkspace.open`) and use it at the checkout sites; leave the generic
`openBillingLink` for portal opens. Preserve the existing nil-placeholder
early-returns (fire nothing when the URL is unset).

## 1. `model_changed`

Two user-driven selection sites both write `preferences.selectedModelID`:
`Surfaces/MenuBarPanel/ModelPickerSubmenu.swift` (~line 66) and
`Surfaces/Settings/Sections/ModelSection.swift` (~line 56).

- Fire `model_changed { from_model, to_model, surface }` at each, where
  `surface` ∈ `menu_bar` / `settings`. Capture `from_model` BEFORE the write.
- Only fire on an actual change (`to != from`) so re-selecting the current model
  is a no-op. Model ids only — no content.

## 2. `artifact_produced`

The activation signal for "the product returned something usable." Fire where a
freshly generated response is first parsed and shown — `AppState` where
`parsedResponse = parsed` is set on the main generation success path (~line 1920).

- `artifact_produced { artifact_type, was_chat_only }` where
  `artifact_type` = `parsed.artifact?.type.rawValue ?? "chat"` and
  `was_chat_only` = `parsed.artifact == nil` (bool).
- Fire ONCE per generation — only for the initial generation result, NOT the
  "Write agent prompt" conversion re-parse (which sets `parsedResponse` at a
  different site, ~line 2139). Verify it doesn't double-fire on conversion.

`ArtifactType` raw values for reference: `agent_prompt`, `message`, `snippet`,
`document`, `generic`.

## 3. `model` on `generation_failed`

Both `generation_failed` captures in `AppState` currently carry only
`route` / `reason` / `latency_ms`. Add `"model": self.generationModelID ?? "unknown"`
to both (the Tier 1/2 field already holds the resolved per-generation id), so
failures are segmentable by model — consistent with `generation_succeeded`.

## 4. Onboarding step-view funnel

> NOTE: the flow changed — there are now SIX steps (a `consent` clickwrap was
> added at index 1). Instrument the CURRENT enum, below. Re-read
> `OnboardingStep.swift` to confirm before coding.

Goal: a per-step funnel so drop-off is visible. Deduped at the source (each step
fires at most once per install) so the Screen-Recording-grant SIGKILL relaunch,
Cmd-Q resume, and back-nav don't inflate it. Reuse `Analytics.captureOnce`.

### 4a. `OnboardingStep.swift` — stable analytics names (current 6 cases)
```swift
var analyticsName: String {
    switch self {
    case .welcome:         return "welcome"
    case .consent:         return "consent"
    case .email:           return "email"
    case .screenRecording: return "screen_recording"
    case .microphone:      return "microphone"
    case .allSet:          return "all_set"
    }
}
```

### 4b. `OnboardingState.swift` — deduped capture
```swift
func recordStepViewed(_ step: OnboardingStep) {
    Analytics.captureOnce(
        "onboarding_step_viewed",
        key: "vf.analytics.onboardingStep.\(step.analyticsName)",
        [
            "step": step.analyticsName,
            "step_index": step.rawValue,
            "total_steps": OnboardingStep.allCases.count,
        ]
    )
}
```
Leave the existing `onboarding_started` / `onboarding_completed` untouched.

### 4c. `OnboardingWindowView.swift` — fire when a step becomes visible
Fire from the view (not `advance()`) so the step restored after the SIGKILL
relaunch is counted. Attach to `stepBody`:
```swift
.onAppear { onboarding.recordStepViewed(onboarding.currentStep) }
.onChange(of: onboarding.currentStep) { _, newStep in
    onboarding.recordStepViewed(newStep)
}
```

(The new `consent` step is worth watching — a clickwrap gate is a plausible
drop-off point.)

---

## Verify before finishing
- App builds (Xcode/`xcodebuild`).
- `checkout_opened` now fires from the Settings + menu-bar checkout sites too,
  each opened URL carries `checkout[custom][ph_distinct_id]` + `[product]`, and
  `customerPortalURL` opens fire NOTHING.
- `model_changed` fires only on real changes, with the right `surface`.
- `artifact_produced` fires once per generation and NOT on the conversion reparse;
  `was_chat_only` matches whether an artifact was present.
- Both `generation_failed` captures now include `model`.
- Each `onboarding_step_viewed` fires at most once per step per install (trace
  the SIGKILL relaunch: `screen_recording` not re-fired), all 6 steps covered.
- No content/PII in any property.
- Show me the final diff, how each point holds, and the event list:
```
New:     model_changed { from_model, to_model, surface: menu_bar|settings }
         artifact_produced { artifact_type, was_chat_only:Bool }
         onboarding_step_viewed { step, step_index, total_steps } (×6 steps, deduped)
Changed: generation_failed (+ model)
         checkout_opened now fired from all checkout entry points (Settings + menu bar)
```
