# Claude Code handoff — fix the intermittent missing toggle knob in Settings

**Bug:** opening Settings sometimes shows a toggle as just the green track with **no
white knob** (reported on "Redact Detected Secrets"). It's intermittent and resolves
on interaction.

**Cause:** the Settings toggles use the **native `.toggleStyle(.switch)`**, which is
backed by an AppKit `NSSwitch`. When the Settings window first appears (before it's
key/main, mid appearance), the native switch can draw its track but the knob layer
lags a frame / doesn't draw until a redraw is forced — hence "green background, no
knob, intermittent." There is no custom ToggleStyle in the app today (the two
`makeBody` styles in `SettingsCard.swift` are **ButtonStyles**).

**Fix:** replace the native switch with a **custom `ToggleStyle` that draws the knob
as a SwiftUI shape**, so it renders deterministically in the SwiftUI layout (no
native layer timing). This also unifies the toggle look with the app's design
language (and matches the "one home for shared chrome" pattern the Settings button
styles already follow).

App-only (Swift), UI. Small + self-contained.

## Affected toggles (all three — fix consistently)
- `Surfaces/Settings/Sections/CaptureSection.swift:149` — "Redact Detected Secrets"
  (the reported one).
- `Surfaces/Settings/Sections/AppBehaviorSection.swift:62` — "Send Anonymous Usage
  Data & Crash Reports".
- `Surfaces/Settings/Sections/AppBehaviorSection.swift:84` — "Launch at Login".
All three are `Toggle(…).toggleStyle(.switch)` — same latent bug; fix all.

## Part 1 — a custom `ToggleStyle`
Add a shared `VFSwitchToggleStyle: ToggleStyle` in `SettingsCard.swift` (alongside
the existing shared button styles — "a single home so every section uses the same
chrome"). `makeBody`:
- A **Capsule track** (~fixed size matching the native switch, e.g. 38×22) filled
  **green** (`Color.vfSuccessGreen`) when `configuration.isOn`, neutral
  (`Color.white.opacity(~0.18)`) when off — animated.
- A **white `Circle()` knob** (~18pt, ~2pt inset) offset to the trailing edge when
  on, leading edge when off — `.animation(.easeInOut(duration: 0.18), value:
  configuration.isOn)`. The knob is a SwiftUI shape, so it ALWAYS renders.
- The whole switch is the tap target: `.onTapGesture { configuration.isOn.toggle() }`
  (and keep it accessible — `.accessibilityRepresentation` / an `AccessibilityValue`
  for VoiceOver, since we're leaving the native control).
- Render `configuration.label` + `Spacer()` + the switch so the style is general; the
  Settings rows that hide the label (`.labelsHidden()` or row-provided label +
  description) keep working — preserve whatever label handling each row already does;
  only the **switch visual** changes.
- A subtle hover/press affordance is optional; keep it consistent with the Settings
  card surface.

Match the visual weight of the app's other green toggles (the dev-settings switches)
so it reads as the same family — green on, neutral off, white knob.

## Part 2 — apply it
Replace `.toggleStyle(.switch)` with `.toggleStyle(VFSwitchToggleStyle())` on all
three toggles above. No binding/logic changes — the `isOn` bindings
(`preferences.redactSecrets`, the crash-reports binding, the launch-at-login binding)
stay exactly as they are.

## Verification
- **Repeat-open test:** open and close Settings many times (and right after launch,
  before the window is key) — the knob renders **every** time. This is the actual
  repro, so do it in the running app, not just a snapshot.
- Toggling flips the underlying preference (redact/crash/launch all still work);
  the on/off colors + knob position animate correctly.
- VoiceOver still announces the control as a switch with its on/off value.
- A render smoke test for the style in both on/off states.

## Acceptance criteria
- All three Settings toggles use the custom `VFSwitchToggleStyle`; the knob always
  renders on open (the intermittent native-switch bug is gone).
- Bindings/behavior unchanged; the toggles read as the app's green design family;
  accessible as switches.
- Build + tests green.

## Notes
- Why custom over a native-redraw hack (`.id()` flip on appear, etc.): those are
  fragile and don't address the root (native layer timing). A SwiftUI-shape knob
  renders deterministically and looks on-brand — strictly better.
