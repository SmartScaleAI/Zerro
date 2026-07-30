# Claude Code handoff — recolor the base background gray to #202022

> **Superseded on 2026-07-30.** Zerro now uses the fixed black palette defined
> in `apps/desktop/Zerro/DesignSystem/Colors.swift`: `#000000` base/pill
> surfaces, unified `#1C1C1E` accent surfaces for cards, controls, artifacts,
> and overlays, plus a `#303030` floating-overlay border. The material below
> is kept only as historical context for the earlier gray-theme migration.

**Goal:** make the app's **main background gray exactly `#202022`** across the pills,
response views, error/failure pills, the overlay (area-selector) pills + toolbar
backgrounds, and the **Settings** and **Onboarding** windows. Keep the existing
**relative depth** — i.e. retarget the *base* background token, and let cards /
dropdown chrome that currently sit *lighter* than the base stay proportionally
lighter, so the visual hierarchy is preserved.

App-only (Swift), UI / design-token change. Small + mostly centralized.

`#202022` = `Color(red: 0.1255, green: 0.1255, blue: 0.1333)` (0x20/0x20/0x22 ÷ 255).

## Where the colors live
Everything funnels through design tokens in
`apps/desktop/Zerro/DesignSystem/Colors.swift`. The surfaces in scope are driven by:

- `vfPillBackground` — pill chrome (`Surfaces/Pill/PillView.swift`), the area-selector
  instruction/overlay pills (`Surfaces/AreaSelector/AreaSelectorView.swift`), the
  onboarding mini-pill, plus pill fills in Settings/Paywall/TrialEmail.
- `vfPanelBackground` — the **main background** for pill response views + toolbars
  (`PillView.swift`, `PillControls.swift`), Settings windows
  (`Surfaces/Settings/**`, incl. `SettingsWindowChrome.swift` window bg), Onboarding
  windows (`Surfaces/Onboarding/OnboardingWindowView.swift`), Recent Prompts, Menu Bar
  panel, Feedback.
- `vfCardBackground` — cards that sit **on top of** the panel (success/response card
  chrome, settings cards, onboarding window card). This is the "lighter for depth"
  layer — keep it relatively lighter (see Step 2).
- `menuFill` (hardcoded in `AreaSelectorView.swift`) — the overlay **toolbar /
  dropdown** chrome (model/mic/dev-settings menus). This is the "overlay toolbar
  background." Currently a one-off literal, not a token.

Current values (for reference):
- `vfPillBackground` = `(0.12, 0.12, 0.14)` ≈ `#1F1F24`
- `vfPanelBackground` = `(0.10, 0.10, 0.12)` ≈ `#1A1A1F`  ← the base, becomes `#202022`
- `vfCardBackground` = `(0.14, 0.14, 0.16)` ≈ `#242429`
- `menuFill` = `(0.15, 0.15, 0.17)` ≈ `#26262B`

## What "keep relative depth" means here
The base background (panel + pill) becomes exactly `#202022`. Cards and the overlay
toolbar/dropdown currently sit a touch **lighter** than the base to read as raised
layers — keep that offset so we don't flatten the hierarchy. Concretely:

| Token | Now | After |
|---|---|---|
| `vfPanelBackground` (base / main bg) | `#1A1A1F` | **`#202022` exactly** |
| `vfPillBackground` (pill chrome) | `#1F1F24` | **`#202022` exactly** |
| `vfCardBackground` (raised cards) | `#242429` | slightly lighter than base, e.g. `#2A2A2C` |
| `menuFill` (overlay toolbar/dropdown) | `#26262B` | slightly lighter than base, e.g. `#2A2A2C` |

The base pair (`vfPanelBackground`, `vfPillBackground`) must be **#202022 exactly** —
that's the explicit ask. The two raised layers just need to stay a bit lighter for
depth; the suggested `#2A2A2C` keeps roughly the same lift they have today. Match the
*amount* of lift, not these exact hexes if you prefer to tune by eye.

## Step 1 — retarget the base tokens (the bulk of the change)
In `apps/desktop/Zerro/DesignSystem/Colors.swift`:

```swift
// Base / main background — was #1A1A1F. Pinned to #202022 (the new base gray)
// for pills, response views, error/overlay pills, overlay toolbars, Settings,
// and Onboarding windows.
static let vfPanelBackground = Color(red: 0.1255, green: 0.1255, blue: 0.1333) // #202022

// Pill chrome — same base gray as the panel so pills and their surrounding
// surface read as one. #202022.
static let vfPillBackground  = Color(red: 0.1255, green: 0.1255, blue: 0.1333) // #202022

// Raised cards sit on the base — kept slightly lighter for depth (was #242429).
static let vfCardBackground  = Color(red: 0.165, green: 0.165, blue: 0.173) // ~#2A2A2C
```

Update the trailing comments on lines 38–41 to reflect the new hexes so the file
stays self-documenting.

## Step 2 — the overlay toolbar `menuFill` (not yet a token)
`menuFill` is a hardcoded literal in
`apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift` (~line 956,
`static let menuFill = Color(red: 0.15, green: 0.15, blue: 0.17)`). It backs the
overlay's dropdown/toolbar chrome (used ~lines 966, 997, 1626, 1646, 1657). This is a
"raised over the base" layer, so set it to the same lighter-than-base value as the
cards:

```swift
static let menuFill = Color(red: 0.165, green: 0.165, blue: 0.173) // ~#2A2A2C, raised over #202022 base
```

(Leaving it as a local literal is fine — just retarget the value. Optionally promote
it to a `vfOverlayToolbar` token in `Colors.swift` if you want one home for it, but
that's not required.)

## Out of scope — do NOT touch these (they're not background grays)
- Status colors (`vfRecordingRed` / `vfWarningAmber` / `vfSuccessGreen` /
  `vfDestructive`), `vfDevAccent`, `vfAccentBlue`, `vfMenuRowHover`,
  `vfPillControlHover`, text/hairline tokens. The error/failure **pill** background
  comes from the panel/card chrome (Step 1); only its red/amber accents stay as-is.
- `PulseLoginBackdrop` in `AreaSelectorView.swift` (~lines 2008–2048) — that's a
  hardcoded **mockup/preview** backdrop (gradient + fake traffic-light window), not a
  live surface. Leave it.
- The `Color(red: 0.10, green: 0.10, blue: 0.12)` literals in
  `MenuBarIconProposals.swift` / `MenuBarIconView.swift` are dev/icon-proposal
  previews — leave unless you want the menu-bar panel base to match too (it currently
  uses `vfPanelBackground`, so the panel itself already moves with Step 1).

## Verify
1. Build the desktop app (`apps/desktop`, Xcode / `xcodebuild`) — must compile clean.
2. Run the snapshot/UI tests that cover these surfaces, e.g.
   `PillCardSnapshotTests`, `DevFailedPillCardTests`, `ChatOnlyResultCardTests`,
   `AreaSelectorToolbarLayoutTests`, `SettingsToggleStyleTests`. Snapshot tests will
   likely need **reference images re-recorded** for the new gray — re-record and
   eyeball the diffs to confirm only the background shifted (no layout/contrast
   regressions).
3. Visually confirm in-app: resting + response + **error/failure** pill, the
   area-selector overlay pill + its toolbar/dropdowns, the Settings window, and the
   Onboarding window all read as `#202022` base with cards/toolbars still slightly
   raised. Sample the base with a color picker → should be exactly `#202022`.
4. Check text contrast (`vfTextSecondary` / `vfTextTertiary`) still reads fine on the
   new base — `#202022` is slightly lighter than the old panel, so secondary text
   contrast drops a hair; confirm it's still legible.
