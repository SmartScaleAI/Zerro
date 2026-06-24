# Claude Code handoff prompt — Add a "Dev Mode" onboarding step

Copy everything below the line into Claude Code, running from the repo root.

---

You are adding ONE new step to the first-launch onboarding flow in the Zerro
macOS app (`apps/desktop`, Swift/SwiftUI, menu-bar app). The step introduces
**Dev Mode** to every user. Read this entire brief, then open the referenced
files before writing any code — the onboarding flow has several
source-of-truth invariants (analytics names, `rawValue` ordering, the
`allCases`-driven step dots) that you must respect.

## Goal (decisions are locked — do not re-litigate)

- **Surface:** a dedicated onboarding step (a new `OnboardingStep` case), NOT a
  coachmark or Settings entry.
- **Audience:** ALL users. No gating on whether a coding-agent CLI is installed.
- **Depth:** "pointer + what it does." Explain what Dev Mode is, how it differs
  from the default clipboard hand-off, and where the switch lives. Do NOT turn
  this into a setup tutorial — no agent-CLI install steps, no folder-picker, no
  readiness/blocked-state explanation. Those already live in the selector's
  dev-settings menu and in Settings.
- **Placement:** insert it as the second-to-last step, between `microphone` and
  `allSet`. New flow: Welcome → Consent → Email → Screen → Mic → **Dev Mode** →
  All Set.

## Background — how the flow is wired (read these first)

All paths under `apps/desktop/Zerro/Surfaces/Onboarding/`:

- **`OnboardingStep.swift`** — the `enum OnboardingStep: Int, CaseIterable`.
  Order is defined by implicit `Int` raw values; `advance()`/`goBack()` are
  `rawValue ± 1`. Two derived properties matter:
  - `analyticsName` — STABLE snake_case id, deliberately decoupled from
    `rawValue`. It is the funnel event property and the per-step dedupe key, so
    it must stay constant across releases.
  - `devLabel` — cosmetic labels for the DEBUG dev panel's jump pills only.
- **`OnboardingWindowView.swift`** — `stepBody` is a `switch` over
  `currentStep` mapping each case to its view. `StepDotsIndicator` renders one
  dot per `OnboardingStep.allCases`, and `recordStepViewed` fires the
  `onboarding_step_viewed` funnel event with `total_steps =
  OnboardingStep.allCases.count`. Both pick up a new case automatically.
- **`OnboardingSteps.swift`** — the per-step view structs. Mirror the existing
  ones. Reusable building blocks already defined here:
  - `OnboardingStepLayout { icon } content: { } actions: { }` — the centered
    icon / content / actions scaffold (see `AllSetStepView`, line ~544, and
    `WelcomeStepView`, line ~24, for canonical usage).
  - `OnboardingPrimaryButton("Label") { action }` (def ~line 997).
  - Spacing/radius tokens: `VFSpacing.*`, `VFRadius.*`.
- **`OnboardingState.swift`** — `advance()` moves to `rawValue + 1`;
  `recordStepViewed` is deduped per-install by `analyticsName`. No state changes
  are required for a purely informational step.

The control the copy points at — confirm it visually in
`apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift`
(`modeSwitchControl`, ~line 1753): a two-segment toggle on the LEFT of the
selector toolbar. Left segment = Artifact (`wand.and.stars`); right segment =
Dev (`chevron.left.forwardslash.chevron.right`, i.e. `</>`). The Dev segment
tints green (`Color.vfDevAccent`, `#34E27A`, defined in
`DesignSystem/Colors.swift`) when active. Match that glyph + color in the step's
icon so the screen visually rhymes with the real switch.

## Step-by-step

### 1. `OnboardingStep.swift` — add the case

Insert `case devMode` between `microphone` and `allSet`:

```swift
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case consent
    case email
    case screenRecording
    case microphone
    case devMode      // NEW — educational, shown to all users
    case allSet
    ...
}
```

Add it to BOTH derived switches (Swift will force you to — they're exhaustive):

```swift
// analyticsName — STABLE id, must never change once shipped
case .devMode: return "dev_mode"

// devLabel — DEBUG dev-panel pill; renumber the ones after it
case .microphone: return "5 · Mic"
case .devMode:    return "6 · Dev"
case .allSet:     return "7 · Ready"
```

### 2. `OnboardingWindowView.swift` — route the case

Add one arm to the `stepBody` switch:

```swift
case .devMode:         DevModeStepView()
```

Do NOT touch `StepDotsIndicator` or `recordStepViewed` — both are
`allCases`-driven and update automatically (dots go 6 → 7; `total_steps` in the
funnel goes 6 → 7).

### 3. `OnboardingSteps.swift` — add the view

Add near `AllSetStepView`. Single primary action that advances to All Set; no
secondary/skip (it's one tap, shown to everyone). Final copy is below — wire it
verbatim.

```swift
// MARK: - Dev Mode (educational)

/// Purely informational step shown to every user just before All Set.
/// Introduces Dev Mode at "what it is + where the switch is" depth — it does
/// NOT cover agent-CLI install or folder setup (those live in the selector's
/// dev-settings menu and Settings). No gating: shown to all users.
struct DevModeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepLayout {
            DevModeGlyphTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Building software? Try Dev Mode")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Normally Zerro copies a ready-to-paste prompt to your clipboard. Flip the green </> Dev switch in the selector toolbar and Zerro instead hands your narrated recording to a local coding agent — like Claude Code — that edits the files in your project for you.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Look for it on the left of the toolbar after you select a region.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextTertiary)
                    .multilineTextAlignment(.center)
            }
        } actions: {
            OnboardingPrimaryButton("Continue") { onboarding.advance() }
        }
    }
}

/// Small icon tile echoing the real Dev switch: the `</>` glyph in the same
/// green (`vfDevAccent`) the toolbar segment shows when active.
private struct DevModeGlyphTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
            .fill(Color.vfDevAccent.opacity(0.14))
            .frame(width: 64, height: 64)
            .overlay(
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.vfDevAccent)
            )
    }
}
```

If `OnboardingPrimaryButton`'s initializer signature differs from the
`("Label") { action }` form, match however `WelcomeStepView` / `AllSetStepView`
call it. If `VFRadius.md` doesn't exist, use whatever radius token those files
already use for tiles.

## Final copy (use verbatim)

- **Title:** Building software? Try Dev Mode
- **Body:** Normally Zerro copies a ready-to-paste prompt to your clipboard.
  Flip the green `</>` Dev switch in the selector toolbar and Zerro instead
  hands your narrated recording to a local coding agent — like Claude Code —
  that edits the files in your project for you.
- **Hint:** Look for it on the left of the toolbar after you select a region.
- **Button:** Continue

## Analytics

No new events needed. The new step auto-joins the funnel:
`onboarding_step_viewed` will fire once per install with `step = "dev_mode"`,
`step_index = 5`, `total_steps = 7`. Note for whoever owns dashboards: any query
that hard-codes `total_steps = 6` or assumes a fixed `step_index` ordering needs
updating. (Actual Dev Mode usage is already tracked separately via
`dev_mode_toggled` in `AreaSelectorWindowController` — leave that alone.)

## Migration / edge case to handle gracefully

`OnboardingState.currentStep` persists by `rawValue` (it survives the OS SIGKILL
on Screen Recording grant). Inserting a case shifts `allSet` from `rawValue 5`
to `6`. A user who updates mid-onboarding with a persisted `currentStep == 5`
would now resume on Dev Mode instead of All Set — harmless (they tap Continue
once more). No code change is required, but call this out in your PR description.
Do NOT renumber to append `devMode` at the end as a workaround — keeping it
before `allSet` is the product requirement, and `analyticsName` (not `rawValue`)
is the stable identifier by design.

## Tests

There are currently NO tests asserting onboarding step count or ordering
(`apps/desktop/ZerroTests` — only `TrialCreditsTests.swift` touches onboarding,
tangentially). Add a small guard so the ordering invariant is protected:

- Assert `OnboardingStep.devMode` sits immediately between `.microphone` and
  `.allSet` (`devMode.rawValue == microphone.rawValue + 1` and
  `allSet.rawValue == devMode.rawValue + 1`).
- Assert `OnboardingStep.devMode.analyticsName == "dev_mode"`.
- Assert `OnboardingStep.allCases.count == 7`.

## Acceptance criteria

1. Onboarding shows 7 steps; the Dev Mode screen appears after Microphone and
   before All Set, with 7 step dots and the active dot on the correct step.
2. The screen renders the title/body/hint/button copy above, with the green
   `</>` glyph tile.
3. Continue advances to All Set; Back (if reachable) returns to Microphone.
4. Project builds clean; both exhaustive switches in `OnboardingStep.swift`
   compile without warnings.
5. New ordering test passes.
6. `OnboardingDevPanel` (DEBUG) shows a "6 · Dev" jump pill that lands on the
   new step.

## Out of scope (do NOT do)

- No coachmark/tooltip on the selector toolbar.
- No Settings or Help entry.
- No agent-install or folder-setup guidance in this step.
- No gating logic / agent detection.
- No changes to the actual Dev Mode runtime, the area selector, or
  `dev_mode_toggled` analytics.
