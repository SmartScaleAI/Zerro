# Task: Make Space select the full screen (not window mode) in the recording overlay

## Goal
In the area-selector overlay (opened via the recording hotkey), pressing **Space** should
select the **entire display the cursor is on** as the capture target, then surface the
floating toolbar **pinned to the bottom-center of that screen** so the user can press
**Return** (or click Record) to start recording.

Today Space toggles into a CleanShot-style "window" mode (hover a window, click to settle).
That window mode is being **removed entirely** and replaced by this one-way full-screen
selection.

## Decisions already made (do not re-litigate)
1. **Remove window-selection mode entirely** — delete its code paths (mode, hover/settle,
   window candidates, window handles, window-confirm). Do not leave it dangling/unreachable.
2. **Space is one-way into full-screen.** Press Space → full-screen selected. There is no
   Space toggle back to drag mode. The user can still ESC to cancel, or just draw a new drag
   rectangle to return to an area selection (drawing a drag should supersede the full-screen
   selection).
3. **Toolbar pinned bottom-center** of the active display when full-screen is selected
   (floating above the bottom edge with the standard margin), not anchored under the
   (full-screen-sized) selection.
4. **Capture extent: the whole display under the cursor/overlay**, captured cleanly via
   `SCContentFilter(display:excludingWindows:)` — i.e. a new `.fullScreen` capture target,
   NOT a `.area` rect routed through the crop path.

## Where the code lives
All in `apps/desktop/Zerro/Surfaces/AreaSelector/` plus one consumer file:

- **`AreaSelectorState.swift`** — the `Mode` enum (`.area` / `.window`, ~line 47),
  `mode` property, all window-mode state (`windows`, `highlightedWindowID`,
  `settledWindowID`, `activeWindow`, `WindowCandidate`), `confirmableSelectionRect`
  (~line 136), `targetSelection`/`selection(...)` builder (~line 133), and the window-mode
  mutations (`enterWindowMode`, `enterAreaMode`, `hoverWindow`, `settleWindow`, ~line 349+).
- **`AreaSelectorWindowController.swift`** — keyDown monitor `case 49: // Space` →
  `toggleMode(...)` (~line 439–474), `confirmCurrentSelection` / `confirmAreaSelection` /
  `confirmWindowSelection` (~line 483–524), `enumerateWindows(...)`, and the
  view-local↔global conversion helpers.
- **`AreaSelectorView.swift`** — the `switch state.mode` render branch (~line 46),
  `windowModeContent` / `windowHandles`, `instructionText` + `modeToggleHint` (~line 244–260),
  and the floating toolbar geometry: `toolbarFrame(forSelection:in:)` (~line 290) plus the
  per-chip frame helpers and `recordButton` visibility (gated on
  `state.confirmableSelectionRect`).
- **`SelectionRect.swift`** — the `Target` enum (`.area` / `.window`, ~line 31).
- **`apps/desktop/Zerro/Capture/RecordingSession.swift`** — the `SCContentFilter` selection
  block (~line 404–420), which currently has three shapes: window / area-crop / no-selection
  full display.

## Implementation plan

### 1. Capture target — `SelectionRect.swift`
Add a `.fullScreen` case to `SelectionRect.Target`. Remove `.window(id:title:)` (per decision
1). Keep `.area` as the default. Update the doc comment.

### 2. State — `AreaSelectorState.swift`
- Replace the `Mode` enum cases `.area` / `.window` with `.area` / `.fullScreen`.
- Delete all window-mode storage and methods: `WindowCandidate`, `windows`,
  `highlightedWindowID`, `settledWindowID`, `activeWindow`, `enterWindowMode`,
  `enterAreaMode` (replace with whatever minimal mode-setters you need), `hoverWindow`,
  `settleWindow`.
- Add `enterFullScreenMode()` that sets `mode = .fullScreen` and clears any in-flight drag
  state. Add a way to leave full-screen back to `.area` when a new drag begins (e.g. starting
  a mouseDown drag resets `mode = .area`).
- `confirmableSelectionRect`: in `.fullScreen`, return the full overlay bounds rect (the
  whole view). The state will need the overlay bounds — today the view passes `bounds` from
  `GeometryReader`. Either store the overlay size on the state when presenting, or compute the
  full-screen rect in the controller (which already knows the window/contentView size) and
  feed it in. Pick whichever keeps the coordinate story clean (controller already does
  view-local↔global conversion).
- The selection builder (`targetSelection`/`selection(...)`, ~line 133): in `.fullScreen`,
  produce a `SelectionRect` whose `rect` is the full display, `target = .fullScreen`, with the
  correct `screenDisplayID` (the display the overlay is on).

### 3. Controller — `AreaSelectorWindowController.swift`
- `case 49: // Space` → call a new `enterFullScreen(window:state:)` instead of `toggleMode`.
  It sets `state.enterFullScreenMode()`. No window enumeration, no hover seeding.
- Delete `toggleMode`, `confirmWindowSelection`, `enumerateWindows`, and any window-only
  helpers. Keep `confirmAreaSelection`.
- `confirmCurrentSelection`: switch on mode → `.area` uses `confirmAreaSelection`;
  `.fullScreen` builds a full-display `SelectionRect` (target `.fullScreen`, whole-display
  global rect) and calls `state.confirm(with:)`. Reuse the existing view-local→global
  conversion for the full bounds, or just use the screen's full frame directly.
- Make sure starting a drag (mouseDown) flips `mode` back to `.area` so drawing a rectangle
  after pressing Space supersedes the full-screen selection (decision 2).

### 4. View — `AreaSelectorView.swift`
- Replace the `switch state.mode` branch: keep `areaModeContent`; replace `windowModeContent`
  with `fullScreenModeContent` that renders the whole-display selection (the dim cutout should
  show the entire screen as "selected" — i.e. no dimming, or a thin full-screen border —
  match the existing visual language; an undimmed full screen with a 1.5pt brand-accent border
  around the display edge reads well). Delete `windowHandles`.
- `instructionText`: `.area` keeps "Drag to select an area to narrate"; `.fullScreen` →
  something like "Full screen selected · press return to record".
- Remove `modeToggleHint`'s "window" wording. The Space hint in the instruction pill should
  now read "full screen" (e.g. `space` `full screen`). Once already in full-screen mode, the
  Space hint can be hidden or left as-is — but since Space is one-way, prefer hiding the Space
  hint in `.fullScreen` mode (keep only `esc` `cancel`).
- **Toolbar position (decision 3):** when `mode == .fullScreen`, override the toolbar origin
  to bottom-center of `bounds`: `x = (bounds.width - toolbarWidth) / 2`,
  `y = bounds.height - toolbarHeight - toolbarMargin` (use the existing `toolbarMargin`).
  Do NOT feed the full-screen selection rect through `toolbarFrame(forSelection:in:)` (it
  would flip awkwardly). Cleanest approach: add a `fullScreenToolbarFrame(in:)` and branch on
  mode where the toolbar + record button + model/mic chips compute their frames. The record
  button stays gated on `confirmableSelectionRect != nil`, which is now always true in
  full-screen mode.

### 5. Capture — `RecordingSession.swift`
In the `SCContentFilter` block (~line 404): add a branch for `case .fullScreen? = selection?.target`
that captures the whole display — `config.width = display.width`, `config.height = display.height`,
`filter = SCContentFilter(display: display, excludingWindows: [])`, and **no** `sourceRect`
crop. (The display is already resolved earlier from `selection.screenDisplayID`; the existing
"no selection → full display" branch is the template, but the `.fullScreen` branch must run
even though a selection IS present.) Remove the now-dead `.window` branch
(`desktopIndependentWindow`).

## Acceptance criteria
- Open overlay → drag-to-select area still works exactly as before (record via toolbar/Return).
- Open overlay → press **Space** → entire display the overlay is on is selected; toolbar
  appears pinned bottom-center; pressing **Return** or clicking Record starts a full-screen
  recording of that display.
- After Space, drawing a new drag rectangle returns to a normal area selection.
- ESC still cancels the overlay.
- The recorded output for full-screen covers the whole display (including menu bar) with no
  crop, captured via `SCContentFilter(display:)`.
- No references to window-selection mode remain (no `WindowCandidate`, `enterWindowMode`,
  `settledWindowID`, `.window` target, `windowHandles`, "window" instruction copy).
- Builds clean; update/extend any `ZerroTests` that referenced window mode or
  `confirmableSelectionRect` window behavior.

## Tests / verification
- Update existing area-selector tests under `apps/desktop/ZerroTests/` that exercise
  `Mode.window`, `enterWindowMode`, `settleWindow`, or the `.window` target — replace with
  `.fullScreen` equivalents (Space enters full-screen; `confirmableSelectionRect` returns full
  bounds; the built `SelectionRect.target == .fullScreen` with the display's `screenDisplayID`).
- Add a test that the `.fullScreen` selection's `rect` equals the overlay/display bounds.
- Manually verify on a multi-display setup: Space selects the display the overlay/cursor is on,
  and the recording captures that exact display (matched by `CGDirectDisplayID`).
