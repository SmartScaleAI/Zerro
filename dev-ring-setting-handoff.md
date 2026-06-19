# Task: Add a "Developer" settings page with a toggle to enable/disable the pulsing ring effect

## Goal
Add a new **Developer** settings page to the Zerro settings window (in the existing **SETTINGS** sidebar group, alongside General / History / Advanced). On this page, add a single toggle, **"Pulsing Ring Effect"**, that controls whether the green pulsing ring is drawn around the screen edges while the coding agent is making changes.

Requirements:
- Toggle is **ON by default**.
- When the user turns it **off while the ring is currently showing**, the ring must **hide immediately** (fade out). Turning it back on while the agent is still active must re-show the ring.
- Persist the setting like every other preference (via `PreferencesStore`, backed by UserDefaults).

## Relevant files (all under `apps/desktop/Zerro/`)
- Settings nav + category enum + detail pane switch: `Surfaces/Settings/SettingsView.swift`
- Reusable settings UI components: `Surfaces/Settings/SettingsCard.swift` (`SettingsSection`, `SettingsRow`, `SettingsRowDivider`, `VFSwitchToggleStyle`)
- Example section to copy the pattern from: `Surfaces/Settings/Sections/AppBehaviorSection.swift` (it already uses toggles with `VFSwitchToggleStyle`)
- Preferences store (single source of truth, `@Observable @MainActor`): `Preferences/PreferencesStore.swift` — note the central `Keys` enum, the `didSet` persistence pattern, and the `Keys.resettable` set used by `resetToDefaults()`
- Ring controller (AppKit NSWindow overlays): `Surfaces/DevRing/DevRingWindowController.swift` — it runs an observation loop on `AppState.devRingActive`
- Ring trigger: `AppState.swift` — `var devRingActive: Bool` (returns true for `.devAgentDispatching` / `.devAgentRunning`)
- App wiring: `ZerroApp.swift` (where `DevRingWindowController` and `PreferencesStore` are set up)

## Implementation steps

### 1. Add the persisted preference
In `Preferences/PreferencesStore.swift`:
- Add a key to the `Keys` enum, e.g. `static let pulsingRingEnabled = "pulsingRingEnabled"`.
- Add an observable property defaulting to **true**, persisting via `didSet`, and reading the stored value on init. Because the default must be `true`, register a default (e.g. `defaults.register(defaults: [Keys.pulsingRingEnabled: true])`) or read with an explicit "if key missing → true" fallback rather than relying on `bool(forKey:)` (which returns `false` for a missing key). Match whatever existing pattern the store uses for boolean prefs.
  ```swift
  var pulsingRingEnabled: Bool {
      didSet { defaults.set(pulsingRingEnabled, forKey: Keys.pulsingRingEnabled) }
  }
  ```
- Add the key to `Keys.resettable` so "Reset to Defaults" restores it to ON (confirm reset restores it to `true`, not `false`).

### 2. Create the Developer section view
Create `Surfaces/Settings/Sections/DeveloperSection.swift`, following the structure of `AppBehaviorSection.swift`:
- Read the store via `@Environment(PreferencesStore.self)` and use `@Bindable`.
- One `SettingsSection` containing a single `SettingsRow`:
  - Label: **"Pulsing Ring Effect"**
  - Description: something like *"Show a pulsing ring around the screen edges while the coding agent is making changes."*
  - Trailing control: a `Toggle` bound to `$preferences.pulsingRingEnabled` using `VFSwitchToggleStyle` (match the other toggles).

### 3. Add the Developer category to the sidebar + pane
In `Surfaces/Settings/SettingsView.swift`:
- Add a `case developer` to the `SettingsCategory` enum.
- Give it a title (**"Developer"**) and an SF Symbol icon (suggest `hammer` or `chevron.left.forwardslash.chevron.right`; pick one consistent with the existing icon style).
- Place it in the **SETTINGS** group (same group as General / History / Advanced — check how grouping is determined, e.g. a `group` property or array ordering, and insert accordingly; reasonable position is after Advanced).
- Add the `case .developer:` branch to the `pane` switch so it renders `DeveloperSection()`.

### 4. Gate the ring on the preference (with immediate hide)
The ring is driven by `DevRingWindowController` observing `AppState.devRingActive`. The cleanest approach is to make the controller's "should the ring be visible" condition `devRingActive && preferences.pulsingRingEnabled`, AND ensure the controller re-evaluates when the preference changes (not only when `devRingActive` changes) so toggling off hides it immediately.

- Give `DevRingWindowController` access to the `PreferencesStore` (inject it where the controller is constructed in `ZerroApp.swift`).
- In the controller's observation/derivation logic, compute visibility as `appState.devRingActive && preferences.pulsingRingEnabled`. Since both are `@Observable`, ensure the observation loop reads BOTH properties so a change to `pulsingRingEnabled` re-triggers evaluation. (If it uses `withObservationTracking`, make sure `pulsingRingEnabled` is touched inside the tracked closure; if it uses a Combine/async stream, add the preference to what it listens to.)
- Verify the existing show/hide paths handle the transition cleanly: turning the toggle off while active should run the normal fade-out; turning it back on while still active should run show (or rebuild + fade in). Reuse the existing fade logic — do not add a separate hide path.

Do NOT change `AppState.devRingActive`'s meaning (other code may rely on it semantically); gate at the controller layer instead. If on inspection it's clearly simpler and safe to gate inside `devRingActive`, that's acceptable, but the controller must still re-evaluate on preference change for the immediate-hide requirement.

## Verification (please do all of these)
1. Build the app and confirm it compiles with no warnings related to the new code.
2. Launch and open Settings → confirm a **Developer** page appears in the SETTINGS group with the **"Pulsing Ring Effect"** toggle **ON** by default on a fresh install (clear the UserDefaults key first to simulate a fresh install).
3. Trigger a coding-agent run (or simulate the `.devAgentRunning` state) and confirm the ring shows when the toggle is ON.
4. With the ring visible, toggle the setting **OFF** → confirm the ring **fades out immediately**. Toggle it back **ON** while still active → confirm the ring re-appears.
5. With the toggle OFF and no run active, start a run → confirm the ring does **not** appear.
6. Use Settings → Advanced → **Reset to Defaults** and confirm the toggle returns to **ON**.
7. Confirm the setting persists across an app restart.

## Notes
- Match existing code style, naming, and the `PreferencesStore` `didSet` persistence pattern exactly.
- Keep all preference access going through `PreferencesStore` — don't read `UserDefaults.standard` directly in views or the ring controller.
- The toggle should use the existing `VFSwitchToggleStyle` for visual consistency.
