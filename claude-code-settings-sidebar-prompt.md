# Task: Convert Zerro Settings to a Wispr-Flow-style sidebar layout

## Goal
Replace the current single-scroll Settings window with a **left-sidebar / detail-pane** layout (like Wispr Flow's settings: a grouped nav list on the left, a content pane on the right that swaps when you select an item). Group the existing seven settings sections into **5 categories**. Keep the window at its current **fixed 720pt width**.

This is primarily a *presentation* change. The seven section views already exist and are self-contained — do **not** rewrite their internals. Only change how they are grouped and navigated.

## Where the code lives
All paths under `Zerro/Surfaces/Settings/`:

- `SettingsView.swift` — the root view. Currently holds `SettingsRoute` enum, `SettingsView`, `SettingsRootView` (the single `ScrollView` stacking all 7 sections), and the `SettingsSubpage` / `BackChevron` chrome for the Recent Prompts push.
- `SettingsWindowChrome.swift` — `SettingsScene` constants (`preferredWidth = 720`, `preferredHeight = 720`, `minimumHeight = 400`) and `applySettingsWindowChrome()` which hard-locks width at the AppKit layer (`window.minSize`/`maxSize`/`setContentSize`).
- `SettingsHeader.swift` — centered logo + "Zerro Settings" title rendered above the content area.
- `SettingsCard.swift` — shared primitives: `SettingsSection`, `SettingsCard`, `SettingsRow`, `SettingsStackedRow`, `SettingsNavigationRow`, `SettingsRowDivider`, button styles, `SettingsStatusPill`. Cards are built assuming ~720pt of horizontal room.
- `Sections/` — the seven section views, each a small SwiftUI `View`:
  `APIAuthSection`, `BillingSection`, `CaptureSection`, `OutputModeSection`, `HistorySection`, `AppBehaviorSection`, `AboutSupportSection`.

The window scene itself is declared in `ZerroApp.swift` (a `Window` with id `SettingsScene.windowID`). Design tokens (`Color.vfPanelBackground`, `vfCardBackground`, `vfHairline`, `vfTextPrimary/Secondary/Tertiary`, `VFSpacing.*`) live in `DesignSystem/`. Reuse these — do not introduce new colors or magic numbers where a token exists.

## The 5 categories (final grouping)
Build the sidebar with two labeled groups, exactly these items, in this order:

**SETTINGS**
1. **General** → `CaptureSection()` then `OutputModeSection()`
2. **History** → `HistorySection(onOpenRecentPrompts:)` (preserve the Recent Prompts subpage navigation — see below)
3. **Advanced** → `AppBehaviorSection()`

**ACCOUNT**
4. **Account & Billing** → `APIAuthSection()` then `BillingSection()`
5. **About** → `AboutSupportSection()`

Each pane is just a `ScrollView` containing a `VStack(alignment: .leading, spacing: 28)` of the section view(s) for that category — i.e. the same composition `SettingsRootView` uses today, sliced into 5 smaller stacks. Keep the existing `.padding(.horizontal, 24)` / `.padding(.bottom, 32)` rhythm on each pane.

## Navigation style: left sidebar (NavigationSplitView-style)
- Use a left sidebar (`NavigationSplitView` is fine, or a custom `HStack` of a sidebar `List` + a detail pane if `NavigationSplitView` fights the chromeless window — your call, but prefer `NavigationSplitView` if it behaves).
- Sidebar shows the two uppercase group headers ("SETTINGS", "ACCOUNT") styled like the existing `SettingsSection` headers (11pt semibold, `.tracking(0.88)`, `vfTextSecondary`, uppercase), with the 5 selectable rows beneath them.
- Selected row gets a subtle highlight consistent with the app's hover/selection treatment already used in `SettingsNavigationRow` (e.g. `Color.white.opacity(...)` fill on a rounded rect). Add a leading SF Symbol icon per row to match Wispr (suggested: General `slider.horizontal.3`, History `clock.arrow.circlepath`, Advanced `gearshape.2`, Account & Billing `person.crop.circle`, About `info.circle` — adjust if a better fit exists).
- Default selection on open: **General**.

## Width: keep it hard-locked at 720pt
The window width is hard-locked in THREE places and must stay 720pt total:
1. `SettingsView`'s `.frame(minWidth/idealWidth/maxWidth: SettingsScene.preferredWidth, ...)`
2. `window.minSize` / `window.maxSize` in `applySettingsWindowChrome()`
3. `window.setContentSize(...)` in the same function

Do **not** widen the window. The sidebar must fit *inside* the existing 720pt. Give the sidebar a fixed width (~180–200pt, matching Wispr's proportion) so the detail pane is ~520–540pt. Because the existing cards were designed for ~720pt of room, verify they still lay out cleanly at the narrower pane width — if any `SettingsRow` trailing control (e.g. the 200pt mic picker, the API key field + eye toggle + status pill on one line in `APIAuthSection`) overflows or clips, adjust the trailing control's width or wrap, but keep all current functionality and labels. Do not let cards clip horizontally.

## Header handling
The current `SettingsHeader` (centered "Zerro Settings") sits above everything. Decide the cleanest placement for a sidebar layout — either keep it as a top bar spanning the full width above the split, or move the Zerro logo/title into the top of the sidebar (Wispr-style). Either is acceptable; pick whichever keeps the traffic-light clearance the header comments describe (~24pt top clearance on the chromeless surface). Preserve `window.isMovableByWindowBackground` drag behavior.

## Preserve the Recent Prompts subpage
`HistorySection` takes `onOpenRecentPrompts` and currently pushes a `SettingsSubpage` wrapping `RecentPromptsView` via the `SettingsRoute` enum. Keep this working. Within the sidebar architecture, the cleanest approach is: when on the History pane, selecting "Recent Prompts" pushes the subpage *within the detail pane* (with the existing `BackChevron` to return). Keep `SettingsSubpage` and `BackChevron`. Keep the Escape-to-go-back keyboard shortcut.

## Constraints / must-nots
- Do not change any section view's internal behavior, labels, bindings, or environment dependencies.
- Do not change `SettingsCard.swift` primitives' public API (other views in the app may use them; verify with a grep before touching).
- Do not change the data layer (`PreferencesStore`, `EntitlementStore`, `KeychainStore`, etc.).
- Reuse existing design tokens and the existing button/pill styles. No new color literals.
- Keep all 7 sections' functionality reachable — nothing dropped.

## Acceptance criteria
1. Settings window opens at 720×720, fixed width, default selection **General**.
2. Left sidebar shows two groups (SETTINGS, ACCOUNT) and 5 rows with icons; selecting a row swaps the detail pane.
3. Each pane scrolls independently; no horizontal clipping of any card or trailing control at the narrower pane width.
4. Recent Prompts still pushes/pops correctly with the back chevron + Escape.
5. The existing previews (`#Preview` blocks) still build; update them as needed so they compile.
6. `xcodebuild` (or building in Xcode) succeeds with no new warnings introduced by this change.

## Verification step (required)
After implementing:
- Build the target and confirm it compiles cleanly.
- Run the app, open Settings, and click through all 5 categories taking a screenshot of each to confirm no clipping and correct grouping.
- Specifically screenshot the **Account & Billing** pane (densest — API key row + status pills) at the narrower pane width to confirm the trailing controls fit.
- Confirm Recent Prompts push/back works.
- Run any existing tests in `ZerroTests/` that touch Settings, if present.
