# Claude Code Prompt — Consolidate Screen Recording + Microphone onboarding into one Permissions step

Status: ready to implement · Scope: macOS app (`apps/desktop`) · Analytics: PostHog onboarding funnel

---

## Goal

Merge the two separate first-launch onboarding steps — **Screen Recording**
(`.screenRecording`) and **Microphone** (`.microphone`) — into a **single
`.permissions` step** that requests both permissions on one screen, modeled on
the Superwhisper "Let's set up permissions" page: each permission shown as its
own row with its own Allow control, and a single **Continue Setup** primary
button at the bottom that stays **disabled until both permissions are granted**.

Consolidate the PostHog onboarding-funnel analytics to match: the two
`onboarding_step_viewed` steps (`step = screen_recording` and
`step = microphone`) become one `step = permissions`.

**Do NOT change** the `permission_granted` / `permission_denied` /
`permission_revoked` events in `PermissionsManager` — those track real TCC
transitions (including mid-session, outside onboarding), are keyed by
`permission: screen_recording | microphone`, and must stay split per permission.
This task only touches the onboarding *step* funnel.

---

## Background: how onboarding works today

- `OnboardingStep` (`apps/desktop/Zerro/Surfaces/Onboarding/OnboardingStep.swift`)
  is an `Int`-raw `CaseIterable` enum. `advance()`/`goBack()` are `rawValue ± 1`,
  so **ordering is load-bearing** — keep cases contiguous.
  Current order: `welcome(0) · consent · email · screenRecording · microphone · devMode · allSet` (7 cases).
- `OnboardingWindowView.stepBody` switches on `currentStep` to render each step's
  view. `StepDotsIndicator` and the `total_steps` analytics property are both
  driven by `OnboardingStep.allCases.count` (no hard-coded counts in app code).
- Each permission step view (`ScreenRecordingStepView`, `MicrophoneStepView` in
  `OnboardingSteps.swift`) renders a tri-state (`PermissionStatus`:
  `.notDetermined` / `.granted` / `.denied`) plus, for Screen Recording only, a
  fourth "needs relaunch" sub-state (`permissions.screenRecordingNeedsRelaunch`).
  They use shared sub-views: `OnboardingGrantedView`, `OnboardingDeniedView`,
  `OnboardingRelaunchView`.
- Both views currently **auto-advance** on grant (via `OnboardingGrantedView`'s
  `autoAdvance` timer) and manage 1 Hz polling while in `.denied`
  (`permissions.managePolling(for:)` + `stopPolling()` on disappear).
- Dev overrides: `OnboardingState.pinnedScreenSubState` / `pinnedMicSubState`
  (DEBUG only) let the dev panel force a sub-state. **Keep both.**
- SIGKILL survival: macOS kills the app when Screen Recording is granted.
  `OnboardingState.currentStep` is persisted to UserDefaults so the window
  reopens on the same step after relaunch. After consolidation the restored step
  is `.permissions` with Screen Recording already granted and Microphone still
  pending — the combined view must render that partial state correctly.
- Gating: `ZerroApp.swift` (~lines 674–685) re-routes a record-hotkey press back
  into onboarding at `.screenRecording` or `.microphone` if either permission is
  not granted.

---

## Changes (all in `apps/desktop/`)

### 1. `Zerro/Surfaces/Onboarding/OnboardingStep.swift`

Replace the two cases with one. New enum:

```swift
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case consent
    case email
    case permissions   // merged Screen Recording + Microphone
    case devMode
    case allSet
    ...
}
```

- `analyticsName`: remove `.screenRecording` / `.microphone`; add
  `case .permissions: return "permissions"`. **Keep all other names byte-for-byte
  identical** (they're shipped funnel ids).
- `devLabel`: collapse "Screen" + "Mic" into one `"4 · Permissions"` and renumber
  the trailing labels (`devMode` → 5, `allSet` → 6).

### 2. `Zerro/Surfaces/Onboarding/OnboardingWindowView.swift`

In `stepBody`, replace the two arms:

```swift
case .screenRecording: ScreenRecordingStepView()
case .microphone:      MicrophoneStepView()
```

with:

```swift
case .permissions: PermissionsStepView()
```

`StepDotsIndicator` needs no change (it iterates `allCases`).

### 3. `Zerro/Surfaces/Onboarding/OnboardingSteps.swift` — new `PermissionsStepView`

Delete `ScreenRecordingStepView` and `MicrophoneStepView`; add a single
`PermissionsStepView` that shows **both** permissions on one screen and a single
**Continue Setup** button. Reuse the existing design-system pieces
(`OnboardingStepLayout`, `OnboardingPrimaryButton`, `HaloBadge`,
`SystemSettingsURLs`, `RecordingPillDemo`, etc.) and the existing copy where it
still fits.

Requirements:

- **Two permission rows**, each with an icon, title, one-line description, and a
  trailing control that reflects that permission's effective sub-state:
  - **Screen Recording** — `effectiveScreen = onboarding.pinnedScreenSubState ?? permissions.screenRecordingStatus`
    - `.notDetermined`: **Allow** button → `permissions.requestScreenRecording()`
    - `.granted`: granted indicator (checkmark)
    - `.denied`: **Open System Settings** (deep-link `SystemSettingsURLs.screenRecording`) + **Check again** → `Task { await permissions.probeScreenRecordingEffectiveness() }`
    - **needs-relaunch** (`onboarding.pinnedScreenSubState == nil && permissions.screenRecordingNeedsRelaunch`, takes priority over the tri-state): **Relaunch Zerro** → `permissions.relaunchToApplyScreenRecording()` + **Check again** → same probe as above. Preserve this exactly — it's the "granted in Settings but not live in this process" recovery path.
  - **Microphone** — `effectiveMic = onboarding.pinnedMicSubState ?? permissions.microphoneStatus`
    - `.notDetermined`: **Allow** button → `Task { await permissions.requestMicrophone() }`
    - `.granted`: granted indicator
    - `.denied`: **Open System Settings** (`SystemSettingsURLs.microphone`) + **Check again** → `permissions.refreshStatuses()`
- **Continue Setup** primary button at the bottom:
  - `disabled` unless **both** are granted:
    `permissions.screenRecordingStatus == .granted && permissions.microphoneStatus == .granted`
    (use the live `permissions.*` values for the gate, not the dev pins, so a pin
    can't let a tester past the real gate — match current production behavior).
  - On tap → `onboarding.advance()`.
  - **Do not auto-advance.** Remove reliance on `OnboardingGrantedView`'s
    auto-advance timer for this step; advancing is now an explicit user action
    (per product decision). `OnboardingGrantedView` may still be used elsewhere —
    don't delete it, just don't drive the step transition from its timer here.
- **Polling**: start 1 Hz polling while *either* permission is `.denied` so an
  out-of-band System Settings toggle is detected; stop otherwise and on
  disappear. Combine the existing rule rather than calling
  `managePolling(for:)` twice (two callers fight over the single timer). E.g.:

  ```swift
  .task(id: pollKey) {
      let needsPolling = effectiveScreen == .denied || effectiveMic == .denied
      if needsPolling { permissions.startPolling() } else { permissions.stopPolling() }
  }
  .onDisappear { permissions.stopPolling() }
  ```
  where `pollKey` changes whenever either effective status changes (e.g. a small
  hashable struct of the two statuses) so the `.task` re-runs on transitions.
- Keep using `onboarding.pinnedScreenSubState` / `pinnedMicSubState` for the
  per-row display so the DEBUG dev panel still works.
- **Partial-grant rendering** (the SIGKILL-restore case): screen `.granted` +
  mic `.notDetermined` must render cleanly — screen row shows granted, mic row
  shows its Allow button, Continue stays disabled until mic is granted.

### 4. `Zerro/Surfaces/Onboarding/OnboardingDevPanel.swift`

`subStatePinRow` switches on the step. Replace the separate
`.screenRecording` / `.microphone` arms with a single `.permissions` arm that
renders **both** pin rows (SCREEN and MIC) stacked, so a tester can pin each
sub-state independently on the combined screen:

```swift
case .permissions:
    VStack(spacing: VFSpacing.sm) {
        permissionPinRow(label: "SCREEN", binding: bindScreen)
        permissionPinRow(label: "MIC",    binding: bindMic)
    }
```

Update the "No sub-states for this step" arm's case list to
`.welcome, .consent, .email, .devMode, .allSet`.

### 5. `Zerro/ZerroApp.swift` (~lines 674–685)

Keep the two separate `if` checks (they log which permission failed) but point
both jumps at the consolidated step:

```swift
if permissions.screenRecordingStatus != .granted {
    Log.hotkey.notice("gating: screen recording not granted — opening onboarding @ permissions")
    onboarding.jump(to: .permissions)
    AppDelegate.openOnboarding()
    return
}
if permissions.microphoneStatus != .granted {
    Log.hotkey.notice("gating: microphone not granted — opening onboarding @ permissions")
    onboarding.jump(to: .permissions)
    AppDelegate.openOnboarding()
    return
}
```

### 6. `ZerroTests/OnboardingStepTests.swift`

Update the shipped contracts:

- `testStepCount`: expect **6** (Welcome → Consent → Email → Permissions → Dev → Ready).
- `testDevModeOrdering`: Dev Mode is now `permissions.rawValue + 1`; All Set is `devMode.rawValue + 1`.
- Add `testPermissionsAnalyticsName`: `OnboardingStep.permissions.analyticsName == "permissions"`.
- Remove any assertion referencing `.microphone` / `.screenRecording`.

---

## Analytics — what this produces

The funnel event is emitted by `OnboardingState.recordStepViewed(_:)`, which
derives everything from the enum, so **no change to that method is needed**.
After this work it will emit, for the merged step:

- event `onboarding_step_viewed`, `step = "permissions"`, `step_index = 3`,
  `total_steps = 6`
- deduped once per install under key
  `vf.analytics.onboardingStep.permissions` (new key — `captureOnce` handles it).

The old `screen_recording` / `microphone` step values simply stop being emitted;
their dedupe keys (`vf.analytics.onboardingStep.screen_recording` / `…microphone`)
become dead and harmless. Historical data in PostHog is retained.

**Leave `PermissionsManager.emitPermissionTransition` and its
`permission_granted` / `permission_denied` / `permission_revoked` events
unchanged.** They are not onboarding-step events.

---

## Out of scope for Claude Code (do NOT attempt)

A saved PostHog insight must be edited **in PostHog**, not in this repo —
flag it in your summary but don't try to change it from code:

- Insight **`[App] Onboarding step funnel`** (short_id `zoD7kmHv`). Today its
  steps are: `welcome → consent → email → screen_recording → microphone →
  all_set → onboarding_completed`. It must become:
  `welcome → consent → email → permissions → all_set → onboarding_completed`
  (drop the two separate `step` filters, add one `step = permissions`).

Optionally update the doc references for consistency (low priority):
`docs/POSTHOG-DASHBOARD-macos-plan.md`,
`docs/HANDOFF-posthog-dashboard-chrome.md`.

---

## Verification

1. `xcodebuild`/Xcode test the `ZerroTests` target — `OnboardingStepTests` passes
   with the new count/order.
2. Fresh-state DEBUG walkthrough (reset onboarding via the dev menu): the dots
   show 6 steps; the Permissions step shows both rows; **Continue Setup is
   disabled** until both are granted.
3. SIGKILL path: on the Permissions step, grant Screen Recording → app relaunches
   → restores to Permissions with Screen Recording granted and Microphone
   pending; Continue stays disabled until Microphone is granted.
4. Denied path per permission: deny → row shows Open System Settings + Check
   again; toggle on in System Settings → polling flips the row to granted within
   ~1 s.
5. Dev panel: on the Permissions step, both SCREEN and MIC pin rows appear and
   independently drive each row's rendering.
6. Gate regression: finish onboarding, revoke a permission in System Settings,
   press the record hotkey → re-routed to the Permissions step.
7. Analytics (DEBUG sends nothing to PostHog by design): assert via the unit
   test that `permissions.analyticsName == "permissions"` and
   `allCases.count == 6`; spot-check the `recordStepViewed` properties in the
   debugger if desired.

Keep edits minimal and match the surrounding SwiftUI / design-system style
(`VFSpacing`, `Color.vf*`, the existing onboarding view vocabulary).
