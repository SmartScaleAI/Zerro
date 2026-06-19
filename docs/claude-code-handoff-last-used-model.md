# Task: Replace the "Default model" setting with "last used model"

## Goal
Remove the explicit **Default model** preference and the menu-bar Model picker. The model a
new recording starts on should simply be the **last model the user actually recorded with** —
no separate "default" to configure. The capture toolbar's model chip becomes the single place
to choose a model, and that choice now *persists*.

## Background: how model selection works today
`PreferencesStore.selectedModelID` is the single persisted key for the generation model. The
generation path reads it fresh at request time and sends it as the `model` field of
`/generate`. Today **three** surfaces touch it:

1. **Settings → General → "Default model"** (`ModelSection.swift`) — WRITES `selectedModelID`.
2. **Menu-bar "Model" submenu** (`ModelPickerSubmenu.swift`, wired in `MenuBarPanelView.swift`)
   — WRITES `selectedModelID`.
3. **Capture toolbar model chip** (`AreaSelectorState` / `AreaSelectorView` /
   `AreaSelectorWindowController`) — SEEDS from `selectedModelID` but is a deliberate
   **per-recording override**: a pick here is handed to `onConfirm` and **never written back**,
   so the next recording reverts to the persisted default.

The decision: collapse this to one persisting surface (the capture toolbar). `selectedModelID`
keeps the same storage key and validation/fallback behavior, but its *meaning* changes from
"the configured default" to "the last model recorded with."

## Desired behavior
- The capture toolbar model chip is the only model picker. Picking a model there and starting
  a recording makes that model stick — the next recording (and the seed shown in the chip) uses
  it.
- There is no "Default model" row in Settings and no "Model" row in the menu-bar panel.
- First-run / invalid-id behavior is unchanged: when nothing valid is persisted,
  `selectedModelID` falls back to `ModelRegistry.defaultModelID` (the Recommended model). BYOK
  key-gating in the toolbar chip is unchanged.
- The generation path is unchanged — it still reads `preferences.selectedModelID` at request
  time.

## Changes

### 1. Persist the toolbar pick (the core change)
`apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift`

In `present()`, the `state.onConfirm` closure (~line 114) reads the toolbar's chosen `modelID`
right before starting the recording. Write it back so it persists as "last used":

```swift
state.onConfirm = { [weak self] rect in
    let modelID = self?.state?.selectedModelID ?? preferences.selectedModelID
    preferences.selectedModelID = modelID   // NEW: persist as last-used
    self?.dismiss()
    onConfirm(rect, modelID)
}
```

Persist at **confirm** (record-start), not on every `selectModel` tap — only models actually
used to record should become the new last-used. Update the load-bearing comment block above
`state.setModels(...)` (~line 105, "a dropdown pick here is a PER-RECORDING override ... NEVER
written back") and the mouse-monitor comment (~line 355, "PER-RECORDING override: state only,
never PreferencesStore") to reflect that the pick now persists at confirm. Fire the existing
`model_changed` analytics on a real change here if you want parity with the old surfaces
(`surface: "capture_toolbar"`); confirm with the desired analytics taxonomy first.

### 2. Remove the Settings "Default model" control
- Delete `apps/desktop/Zerro/Surfaces/Settings/Sections/ModelSection.swift`.
- In `apps/desktop/Zerro/Surfaces/Settings/SettingsView.swift` (~line 162, `.general` case),
  remove the `ModelSection()` call and its preceding comment. Check the surrounding
  `VStack(spacing: 28)` still reads well with just `CaptureSection()`.

### 3. Remove the menu-bar Model picker
- Delete `apps/desktop/Zerro/Surfaces/MenuBarPanel/ModelPickerSubmenu.swift`.
- In `apps/desktop/Zerro/Surfaces/MenuBarPanel/MenuBarPanelView.swift`:
  - Remove the `MenuRow(label: "Model", ...)` block, its `.onHover`, and its
    `.submenuFlyout { ModelPickerSubmenu() ... }` (~lines 210–243).
  - Remove the now-unused `@State` vars `showModelPicker`, `modelRowHovered`,
    `modelPanelHovered` (~lines 105–107) and any other references to them.
  - Verify the `menuDivider` / row layout around the removed block still looks right.

### 4. Update doc comments / semantics
- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` (~lines 73–79): reword the
  `selectedModelID` doc comment from "last-selected ... default" framing to "the last model the
  user recorded with; seeds the capture toolbar and is read by the generation path." Keep the
  storage key, the registry validation, and the `ModelRegistry.defaultModelID` fallback exactly
  as-is.
- Scan for any remaining "Default model" copy or comments referencing the removed surfaces
  (e.g. the comment in `AreaSelectorState.swift` ~line 233 that points at the "Preferences
  'Default model'").

## Acceptance / verification
- Build the desktop app; resolve any references to the deleted `ModelSection` /
  `ModelPickerSubmenu` types.
- Manual: pick model A in the capture toolbar, record. Reopen the overlay → chip seeds to A.
  Pick model B, record → next overlay seeds to B. Confirm Settings has no "Default model" row
  and the menu-bar panel has no "Model" row.
- First-run (clear `selectedModelID` from defaults): toolbar seeds to the Recommended model.
- BYOK: gated models still render disabled with the "add key" hint in the toolbar chip.
- Update/remove affected tests: search `ZerroTests` for `ModelSection`, `ModelPickerSubmenu`,
  and `selectedModelID` expectations (e.g. `ModelRegistryTests.swift`) and adjust any that
  asserted the old default-write behavior.

## Out of scope
No change to `ModelRegistry`, the `/generate` contract, BYOK routing, or the model wire ids.
