# Handoff: Dev-Mode Green Recording Cursor + Glow

## Goal

While the user is recording a **Dev Mode** clip, replace the normal macOS pointer
with a custom cursor whose outline is the Dev Mode green (`#34E27A`,
`Color.vfDevAccent`) instead of the default white, and add a small soft green
glow beneath the pointer. The effect is **screen-wide** for the full duration of
the recording and must **revert to the default macOS cursor the instant the
recording stops** (or fails / auto-stops). Add an Appearance setting to disable
the effect.

This is the cursor analogue of the existing pulsing green screen-edge ring
(`DevRingWindowController`) — same "Dev Mode is active right now" signal, same
opt-out pattern.

## Scope decisions (already settled — do not re-litigate)

- **Trigger:** ONLY while `appState.isRecordingActive` AND the active recording
  is a Dev Mode session (`appState.recordingIsDevMode == true`). Not during the
  dev agent *run* afterward — only during the recording itself.
- **Scope:** whole screen (all displays), not just the captured region. The user
  accepts that the green cursor only appears *in the resulting clip* where the
  capture is pointed; on-screen it is everywhere.
- **Approach:** **Hide the real OS cursor and draw a fully custom green-outlined
  replacement cursor + glow** in an overlay window that tracks the pointer.
  Rationale: the white system outline cannot be recolored in place; an overlay
  that merely *follows* the real cursor would leave the white pointer visible
  underneath (white + green together), which is exactly the look we're avoiding.
  Hiding the system cursor and drawing our own is the only way to actually remove
  the white outline.

## Architecture — mirror the existing DevRing pattern

Study and closely mirror these existing files; the new feature is intentionally
parallel to them:

- `apps/desktop/Zerro/Surfaces/DevRing/DevRingWindowController.swift` — the
  overlay window controller pattern: borderless, transparent, `.screenSaver`
  level, `ignoresMouseEvents = true`, `.canJoinAllSpaces/.fullScreenAuxiliary/
  .stationary`, one window per `NSScreen`, an observation `Task` loop over
  AppState + preferences, fade in/out, rebuild on
  `didChangeScreenParametersNotification`. **Copy this structure.**
- `apps/desktop/Zerro/Capture/CursorTracker.swift` — the ~30Hz polling approach
  using `NSEvent.mouseLocation`. Note its rationale for polling over a move
  monitor and that a global mouse poll needs **no permission**. The new cursor
  overlay needs higher-frequency position updates than 30Hz to not feel laggy
  (see "Tracking" below) — do NOT reuse this class, but follow its
  permission-free `NSEvent.mouseLocation` philosophy.
- `apps/desktop/Zerro/Surfaces/RecordingFocus/RecordingFocusWindowController.swift`
  — another overlay controller driven by `appState.isRecordingActive`. Good
  reference for the recording-lifecycle observation.
- `apps/desktop/Zerro/AppState.swift` — `isRecordingActive` (line ~954) and
  `recordingIsDevMode` (set in `startRecording`, line ~1043). These two together
  are the trigger condition.
- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` — the
  `pulsingRingEnabled` pref is the exact pattern to copy for the new toggle
  (Keys enum entry ~line 38, the stored property, UserDefaults backing,
  default ON).
- `apps/desktop/Zerro/Surfaces/Settings/Sections/AppearanceSection.swift` — add
  the new toggle here, right under "Pulsing Ring Effect".
- `apps/desktop/Zerro/DesignSystem/Colors.swift` — use `Color.vfDevAccent`
  (`#34E27A`) for the outline + glow. Do not introduce a new color.
- `apps/desktop/Zerro/ZerroApp.swift` — where `DevRingWindowController` is
  instantiated and held; instantiate the new controller the same way (same
  lifetime, passed `appState` + `preferences`).

## What to build

### 1. New AppState derived flag

Add a derived property mirroring `devRingActive`:

```swift
/// True while the custom Dev-Mode green recording cursor should be shown:
/// a Dev Mode recording is actively in progress. Single source of truth for
/// `DevCursorWindowController`. Deriving it from the recording state means
/// every start/stop/auto-stop/fail path drives it for free.
var devCursorActive: Bool {
    isRecordingActive && recordingIsDevMode
}
```

Confirm `recordingIsDevMode` is set true at recording start and reset false on
every teardown path (it is set at ~line 1043; verify it returns to false in the
`.idle`/stop/fail transitions so the cursor can never outlive the recording).

### 2. New preference

In `PreferencesStore`:
- `Keys.devCursorEnabled = "devCursorEnabled"` (follow the existing key style).
- A stored `var devCursorEnabled: Bool` backed by UserDefaults, **default ON**,
  exactly like `pulsingRingEnabled`.

### 3. New overlay controller: `DevCursorWindowController`

New file:
`apps/desktop/Zerro/Surfaces/DevCursor/DevCursorWindowController.swift`.

Responsibilities, copied structurally from `DevRingWindowController`:

- `shouldShow` = `appState.devCursorActive && preferences.devCursorEnabled`.
- Observation `Task` loop tracking BOTH `appState.devCursorActive` and
  `preferences.devCursorEnabled` via `withObservationTracking`, so flipping the
  pref off mid-recording hides the cursor immediately and back on re-shows it.
- One overlay window per `NSScreen`, rebuilt on
  `didChangeScreenParametersNotification` while active.
- Window config identical to DevRing: borderless, `isOpaque = false`,
  clear background, no shadow, `animationBehavior = .none`,
  `level = .screenSaver` (must float above app windows and fullscreen apps),
  `ignoresMouseEvents = true`, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary]`, excluded from windows menu, not released
  when closed.

**Hide / restore the system cursor — the critical correctness requirement:**

- On activate: hide the OS cursor screen-wide. Use `NSCursor.hide()`. Because
  `NSCursor.hide()`/`unhide()` are reference-counted and only take effect when
  our app is active, the robust approach is `CGDisplayHideCursor(kCGNullDirectDisplay)`
  / `CGDisplayShowCursor(kCGNullDirectDisplay)` which hide the cursor system-wide
  regardless of which app is frontmost. Use the CoreGraphics calls. Pair every
  hide with exactly one show.
- On deactivate (recording stopped/failed/auto-stopped, OR pref toggled off, OR
  controller teardown): restore the cursor with `CGDisplayShowCursor`. This MUST
  be bulletproof — guarantee restore in:
  - the normal hide() path,
  - `deinit`,
  - and defensively on app termination / `applicationWillTerminate`, so a crash
    or unexpected teardown can never leave the user with no cursor.
  Track hidden-state with a bool so show/hide stay balanced (never call show
  without a matching hide, never double-hide).

**Tracking the pointer (smoothness matters):**

- Drive cursor position from a `CVDisplayLink` or a high-frequency
  (`~120Hz`/`.milliseconds(8)`) `Task` sleep loop reading `NSEvent.mouseLocation`,
  OR — preferred for smoothness — a global `NSEvent.addGlobalMonitorForEvents`
  for `.mouseMoved`/`.leftMouseDragged`/`.rightMouseDragged` to update position
  immediately, combined with reading `NSEvent.mouseLocation` so the rendered
  cursor is glued to the real pointer with no perceptible lag. (A pure 30Hz poll
  like `CursorTracker` will look laggy for a *rendered* cursor — that class is
  fine for sampling but not for live display.)
- `NSEvent.mouseLocation` is global, bottom-left origin. Convert to the
  containing screen and to that window's top-left view space, same coordinate
  math as `RecordingFocusWindowController.windowLocalRect`. Only the window whose
  screen currently contains the pointer renders the cursor visibly; the others
  render nothing (or move their cursor view off-bounds). Avoid drawing duplicate
  cursors across displays.

**Cursor appearance (the rendered replacement):**

- Default macOS arrow shape, redrawn with:
  - a **green outline** (`vfDevAccent`) where the system cursor's white outline
    would be, and a dark/black interior (mirror the standard arrow's
    black-fill-with-white-edge, but swap white → green). A hand-built SwiftUI
    `Path` of the standard arrow pointer is acceptable and simplest; size it to
    match the real arrow (~roughly 20–24pt tall) with the hotspot at the
    tip (top-left point of the arrow), so the drawn tip sits exactly on
    `NSEvent.mouseLocation`.
  - a **small soft green glow beneath the cursor**: a blurred `vfDevAccent`
    radial/circle behind the arrow, subtle (small radius, modest opacity, e.g.
    ~10–14pt blur). Flatten the glow with `.drawingGroup()` for cheap
    compositing (same perf lesson called out in `DevRingWindowController`'s
    header comment — do NOT animate blur radius). A gentle constant glow is
    fine; no pulsing required (but a very subtle breathing opacity, reusing the
    DevRing pulse approach, is acceptable if it looks good — keep it optional and
    cheap).
- **Cursor shape changes:** for v1 it is acceptable to always draw the arrow
  pointer even when the system would show an I-beam/resize/etc. Note this as a
  known v1 limitation in the file header (mirroring how RecordingFocus documents
  its window-move limitation). Do NOT block on matching every system cursor
  shape. If trivially feasible, query the current `NSCursor.current` to vary the
  drawn shape, but treat that as a stretch goal, not a requirement.

**Show / hide visuals:**

- Fade the overlay window alpha in/out (≈0.18–0.25s) exactly like DevRing/
  RecordingFocus, using the same "order in while invisible inside a disabled-
  actions `CATransaction`, then ramp `alphaValue`" trick to avoid the Core
  Animation `onOrderIn` zoom.

### 4. Wire it up in ZerroApp

Instantiate and retain `DevCursorWindowController` wherever
`DevRingWindowController` is created, with the same lifetime, passing `appState`
and `preferences`.

### 5. Appearance setting

In `AppearanceSection.swift`, add a second `SettingsRow` directly below the
Pulsing Ring Effect row:

- Label: `"Recording Cursor Highlight"` (or similar — match the existing copy
  voice).
- Description: something like `"Show a green-outlined cursor with a glow while
  recording a Dev Mode clip."`
- A `Toggle` bound to `$preferences.devCursorEnabled` with `.labelsHidden()` and
  `.toggleStyle(VFSwitchToggleStyle())`, identical to the ring toggle.

Update the file header comment (currently says "One toggle") to reflect two.

## Tests

Follow the existing test style in `apps/desktop/ZerroTests/` (there are
`RestingPillGuardTests`, `DevRing`-adjacent guard tests, etc.). Add a lightweight
test target file, e.g. `DevCursorActivationTests.swift`, covering:

- `AppState.devCursorActive` is true only when `isRecordingActive &&
  recordingIsDevMode`, and false for: idle, a non-Dev recording, and after stop.
- `shouldShow` gating respects `preferences.devCursorEnabled` (true only when
  both the state flag and the pref are on).
- Cursor hide/show balance: a unit test (or a small injectable seam around the
  `CGDisplayHideCursor`/`ShowCursor` calls — inject a counter closure pair like
  `CursorTracker` injects its clock/location) proving every hide is matched by
  exactly one show across activate→deactivate, deinit, and pref-toggle-off.

Make the hide/show calls injectable (closure pair, defaulting to the real
CoreGraphics calls) precisely so this balance is testable without touching the
real display — mirror how `CursorTracker` injects `now`/`location`.

## Acceptance criteria

1. Starting a **Dev Mode** recording (with the pref ON) hides the white system
   cursor and shows a green-outlined cursor + small green glow that tracks the
   pointer smoothly across all displays, with no white outline visible.
2. A **non-Dev** recording shows the normal cursor (no effect).
3. Stopping the recording (normal stop, auto-stop, or failure) restores the
   default macOS cursor immediately and completely. The cursor is NEVER left
   hidden after a recording ends, even on crash/terminate.
4. Toggling **Appearance → Recording Cursor Highlight** off hides the effect
   immediately mid-recording (system cursor restored); toggling it back on
   re-applies it. Default is ON.
5. No measurable idle CPU cost from animating blur/shadow (follow the DevRing
   perf note: rasterize the glow once, animate only opacity if at all).
6. The pulsing edge ring and this cursor effect coexist without interfering.

## Watch out for

- **Never leave the user without a cursor.** This is the #1 risk. Belt-and-
  suspenders the restore (hide path, deinit, app-termination). Reference-count
  the hidden state.
- `.screenSaver`-level + `ignoresMouseEvents = true` so the overlay is purely
  decorative and never eats clicks.
- The drawn arrow's **hotspot/tip** must land exactly on `NSEvent.mouseLocation`
  or the green cursor will feel offset from where clicks actually register.
- Multi-display: only one screen's window should render the cursor at a time
  (the one containing the pointer); rebuild windows on screen-config changes.
- Keep all green sourced from `Color.vfDevAccent` — no new hardcoded hex.
- Don't reuse `CursorTracker` for live rendering (too slow at 30Hz); it stays
  dedicated to its deixis sampling job.

## Files to create
- `apps/desktop/Zerro/Surfaces/DevCursor/DevCursorWindowController.swift`
- `apps/desktop/ZerroTests/DevCursorActivationTests.swift`

## Files to edit
- `apps/desktop/Zerro/AppState.swift` (add `devCursorActive`)
- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` (add `devCursorEnabled` key + property)
- `apps/desktop/Zerro/Surfaces/Settings/Sections/AppearanceSection.swift` (add toggle)
- `apps/desktop/Zerro/ZerroApp.swift` (instantiate controller)
