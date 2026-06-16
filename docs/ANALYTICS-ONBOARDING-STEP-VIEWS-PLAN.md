# Plan — Onboarding Step-View Tracking (drop-off funnel)

Status: proposal · Scope: macOS app · Date: 2026-06-15

## Goal

See **where users stop in onboarding** — i.e. which step they reach and never
get past. Today only two onboarding events fire (`onboarding_started`,
`onboarding_completed`), so a user who quits on the Screen Recording step is
invisible. Adding one `onboarding_step_viewed` event per step turns onboarding
into a five-stage funnel where the drop between any two stages is the abandon
rate at that step.

## The flow we're instrumenting

`OnboardingStep` (raw `Int`, `CaseIterable`) defines the order, and
`OnboardingWindowView.stepBody` renders the current one:

| index | case | analytics name |
|---|---|---|
| 0 | `.welcome` | `welcome` |
| 1 | `.email` | `email` |
| 2 | `.screenRecording` | `screen_recording` |
| 3 | `.microphone` | `microphone` |
| 4 | `.allSet` | `all_set` |

Target funnel in PostHog:
`onboarding_step_viewed[welcome]` → `[email]` → `[screen_recording]` →
`[microphone]` → `[all_set]` → `onboarding_completed`.

## The one hard problem: don't double-count

Two things make a step legitimately render more than once for the same user:

1. **SIGKILL on Screen Recording grant.** The OS kills the app when the user
   grants Screen Recording. `OnboardingState` persists `currentStep` specifically
   so the window re-opens on that same step after relaunch — so the step's view
   appears a second time through no fault of the user.
2. **Cmd-Q / resume.** A user can quit mid-onboarding and the window resumes on
   the persisted step.
3. **Back navigation** (`goBack()`) and dev-panel `jump(to:)` also re-enter steps.

If each appearance fired an event, the funnel would show *more* views of
`screen_recording` than `email`, which is nonsense for a drop-off analysis.

**Decision: dedupe at the source — fire each `onboarding_step_viewed` at most
once per step per install.** This makes the funnel monotonic and immune to the
SIGKILL re-entry, resume, and back-nav, with zero analysis-side cleanup. We
already have the exact primitive for this: `Analytics.captureOnce(_:key:_:)`,
which is keyed by a UserDefaults flag (it's how `onboarding_started` is deduped).
We just use a per-step key.

> Alternative considered: fire on every appearance with `step` + `step_index`
> and dedupe in PostHog with a "first time" funnel step. Rejected as the default
> because it bakes a known footgun (the SIGKILL re-fire) into every query and
> inflates raw event volume. Source-side dedup is simpler and matches the goal.

## Changes

Three small edits, all in `apps/desktop/Zerro/Surfaces/Onboarding/`.

### 1. `OnboardingStep.swift` — add a stable analytics name

Don't derive the event name from `devLabel` or the enum order (both can change).
Add an explicit, stable mapping:

```swift
/// Stable snake_case identifier for analytics. Decoupled from raw value
/// and devLabel so reordering steps never silently renames an event.
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

### 2. `OnboardingState.swift` — one capture method, deduped per step

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

Properties are metadata only (enum name + indices), so this stays inside the
existing no-content privacy contract.

### 3. `OnboardingWindowView.swift` — call it when a step becomes visible

Firing from the **view** (not from `advance()`) is what makes us catch the step
that's shown after the SIGKILL relaunch — that path restores `currentStep` in
`init` and re-presents the window without ever calling `advance()`. `onAppear`
covers the initial/restored step; `onChange` covers every forward/back
transition. Dedup makes the overlap harmless.

```swift
stepBody
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, VFSpacing.lg)
    .onAppear { onboarding.recordStepViewed(onboarding.currentStep) }
    .onChange(of: onboarding.currentStep) { _, newStep in
        onboarding.recordStepViewed(newStep)
    }
```

Leave the existing `onboarding_started` (fires on first `advance()` out of
welcome) and `onboarding_completed` exactly as they are — they remain useful
funnel bookends and the new events slot between them.

## Event reference (what ships)

| Event | When | Properties | Dedup |
|---|---|---|---|
| `onboarding_step_viewed` | each step first becomes visible | `step`, `step_index`, `total_steps` | once per step per install |

## Optional follow-on: explicit abandonment (Phase 2)

`onboarding_step_viewed` already lets you *infer* drop-off (no `all_set` view =
didn't finish). If you later want an explicit signal, add `onboarding_abandoned`
with a `last_step` property, fired from the onboarding window's `onDisappear`
when `hasCompletedOnboarding == false`. Slightly trickier (window-close vs
app-quit disambiguation), so it's deliberately out of scope for v1.

## Verification

1. **Debug build, fresh state.** Reset the dedup flags (delete the app's
   UserDefaults, or clear keys prefixed `vf.analytics.onboardingStep.`) and walk
   through onboarding. With `config.debug = true`, confirm in Xcode console that
   exactly one `onboarding_step_viewed` fires per step, in order.
2. **SIGKILL path.** On the Screen Recording step, grant permission, let the app
   get killed and relaunch. Confirm `screen_recording` does **not** fire a second
   time (flag already set), and that continuing to Microphone/All Set still
   fires those once.
3. **Back nav.** `goBack()` to a prior step → confirm no duplicate event.
4. **Opt-out.** Toggle analytics off, fresh state, walk through → confirm nothing
   is sent (the `Analytics`/`CrashReporting` opt-out gate covers this).
5. **PostHog.** Once events land, build the funnel above and confirm the stages
   are monotonically non-increasing.

## Known limitation

`captureOnce` sets its dedup flag even when capture no-ops (analytics disabled or
not yet started). So a user who completes onboarding with analytics **off**, then
turns it **on**, won't retroactively emit step views. This matches the existing
behavior of `onboarding_started` and is acceptable; the dedup flag reflects "this
step happened on this install," not "this event was transmitted."

## Effort

~30 lines across three files, no new dependencies, no SDK changes. The wrapper,
opt-out gate, and `captureOnce` primitive all already exist.
