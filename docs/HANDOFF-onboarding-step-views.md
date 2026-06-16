# Claude Code handoff — implement onboarding step-view analytics

Implement `onboarding_step_viewed` tracking in the Zerro macOS app so we can see
where users drop off during onboarding. The full design and rationale already
live in `docs/ANALYTICS-ONBOARDING-STEP-VIEWS-PLAN.md` — read it first; this is
the implementation order.

## Context you need

- All analytics flow through `apps/desktop/Zerro/Observability/Analytics.swift`.
  Use `Analytics.captureOnce(_:key:_:)` (already exists) — do NOT touch the
  PostHog SDK setup. Properties must be metadata only (enums/counts) — never user
  content. This is a hard privacy contract; honor it.
- Onboarding lives in `apps/desktop/Zerro/Surfaces/Onboarding/`. Steps are
  `welcome → email → screenRecording → microphone → allSet` (`OnboardingStep`,
  `Int`-raw, `CaseIterable`), rendered by `OnboardingWindowView.stepBody`.
- CRITICAL constraint: macOS issues a SIGKILL when Screen Recording is granted,
  and `OnboardingState` persists `currentStep` so the window re-opens on the same
  step after relaunch. Because of this, each step's view can appear more than
  once. We must dedupe so each step fires at most ONCE per install — that's why
  we use `captureOnce` with a per-step key and fire from the view layer.

## Make exactly these three edits

### 1. `OnboardingStep.swift` — add a stable analytics name
Add a computed property (do not reuse `devLabel` or rawValue for the name):
```swift
var analyticsName: String {
    switch self {
    case .welcome:         return "welcome"
    case .email:           return "email"
    case .screenRecording: return "screen_recording"
    case .microphone:      return "microphone"
    case .allSet:          return "all_set"
    }
}
```

### 2. `OnboardingState.swift` — add a deduped capture method
```swift
/// Fire `onboarding_step_viewed` at most once per step per install.
/// Deduped via UserDefaults so the SIGKILL relaunch on Screen Recording
/// grant, Cmd-Q resume, and back-navigation don't inflate the funnel.
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
Leave the existing `onboarding_started` and `onboarding_completed` calls
untouched.

### 3. `OnboardingWindowView.swift` — fire when a step becomes visible
Attach to `stepBody` (the existing modifier chain inside `mainPanel`). Firing
from the view — not from `advance()` — is required so the step restored after the
SIGKILL relaunch is also counted:
```swift
stepBody
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, VFSpacing.lg)
    .onAppear { onboarding.recordStepViewed(onboarding.currentStep) }
    .onChange(of: onboarding.currentStep) { _, newStep in
        onboarding.recordStepViewed(newStep)
    }
```

## Constraints
- No new dependencies, no PostHog SDK config changes, no new events beyond
  `onboarding_step_viewed`.
- Keep the diff minimal (~30 lines across the three files).
- Match the surrounding code style and existing comment conventions.

## Verify before you finish
- The project builds (`xcodebuild` on the `apps/desktop` target, or confirm in
  Xcode).
- Trace the logic for the SIGKILL path: after granting Screen Recording and
  relaunching, `screen_recording` must NOT fire a second time (flag already set),
  while later steps still fire once.
- `goBack()` to a prior step produces no duplicate event.
- With analytics opted out, nothing is captured (the existing opt-out gate in
  `Analytics`/`CrashReporting` covers this — confirm you didn't bypass it).
- Show me the final diff and a short note on how each verification point holds.
