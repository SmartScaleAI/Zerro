# Task: Re-arm the area-selector overlay's keyboard (ESC) after the app loses and regains focus

## Problem
When the area-selector overlay is open, you can ESC to cancel it — but only until focus
leaves Zerro. The repro:

1. Open the overlay (hotkey) — ESC works, clicks work.
2. ⌘-Tab to another app (the overlay stays visible on top, as designed).
3. Click back onto the Zerro overlay — clicks/drag still work, **but ESC no longer closes it**.

Same dead-keyboard result if you ⌘-Tab *away* and then ⌘-Tab *back* to Zerro: the overlay
is visible and the mouse still drives it, but the keyboard (ESC / Space / Return) is inert.
The only way out is to complete a selection with the mouse (Record) or kill the overlay some
other way.

## Root cause
The overlay is a borderless `.nonactivatingPanel` (`AreaSelectorWindow`, ~line 730 of
`apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift`). All overlay
input is handled by two **local** event monitors installed in `installEventMonitors` (~line
229): a mouse monitor and a `keyDown` monitor. A non-activating panel only receives keyboard
events while it is the **key window** — that's why `present()` calls `win.makeKey()` (~line
153) and why ESC works on first open even though the app is never activated (`.accessory`
policy, no `NSApp.activate` — deliberate, see the comment at ~line 128).

Two things break that key status, and nothing restores it:

1. **⌘-Tab away** makes another app's window key, so the panel **resigns key**. Local
   monitors only fire for events routed to our app's key window, so the `keyDown` monitor
   stops seeing ESC.
2. **Clicking back onto the overlay does NOT re-key it.** Normally a click on a window makes
   it key as a side effect of AppKit's `sendEvent:`. But our mouse monitor consumes the
   `leftMouseDown` by returning `nil` (~line 296/378) *before* `sendEvent:` runs, so the
   panel never goes through its click-to-become-key path. The click drives the selection but
   leaves the panel non-key — keyboard stays dead.
3. **⌘-Tab back to Zerro** reactivates the app but does not restore this transient,
   `isExcludedFromWindowsMenu`, non-restorable panel as key, so again the keyboard is dead.

So the fix is to re-establish key status on the two events that should restore it: a click
into the overlay, and the app becoming active again.

## Desired behavior
The overlay's keyboard stays usable across focus changes for the lifetime of a presentation:

- After ⌘-Tab away + click back into the overlay → ESC (and Space / Return) work again.
- After ⌘-Tab away + ⌘-Tab back to Zerro → ESC works again (clicking first should not be
  required, but if a click is what re-keys it, that's acceptable as long as it's reliable).
- No behavioral regressions: opening the overlay must NOT activate Zerro or raise other Zerro
  windows (Settings, onboarding, menu-bar panel). Re-keying the panel must use `makeKey()` /
  panel-level ordering, **never** `NSApp.activate(ignoringOtherApps:)` — see the load-bearing
  comment at ~line 128. The whole point of the non-activating panel is that the overlay can
  float over another app without stealing app-level focus.

## Where the code lives
Everything is in
`apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift`:

- `present()` ~line 73 — builds the window, calls `win.makeKey()` (~153), installs monitors.
- `installEventMonitors(for:state:)` ~line 229 — the mouse monitor (~237) and `keyDown`
  monitor (~381). The mouse monitor's `.leftMouseDown` branch begins ~line 292 and returns
  `nil` to consume.
- `dismiss()` ~line 211 — tears down both monitors and the screen-change observer; this is
  where any new observer must also be removed.
- `installScreenChangeObserver()` ~line 179 — the existing pattern for a
  `NotificationCenter` observer stored on the controller and cleaned up in `dismiss()`. Copy
  this shape for the new activate observer.
- `AreaSelectorWindow` ~line 730 — `canBecomeKey { true }`, `canBecomeMain { false }`. No
  change needed, but confirms the panel is allowed to be key.

## Implementation
Make the smallest change that re-arms the keyboard. Two complementary pieces:

1. **Re-key on click.** In the mouse monitor (`installEventMonitors`), when an
   `event.type == .leftMouseDown` is confirmed to belong to the overlay window
   (`event.window === window`), re-assert key status before the existing handling — e.g. at
   the top of the leftMouseDown handling, `if !window.isKeyWindow { window.makeKey() }`. Do
   this for the click regardless of where it lands (toolbar control, drag start, dropdown
   row) so any click into the overlay restores the keyboard. The monitor still returns `nil`
   to consume the event as today; we're just doing explicitly what `sendEvent:` would have
   done. Verify `makeKey()` on a background-app non-activating panel actually routes
   subsequent keyDown to our monitor (it does on first `present()`, which is the same
   situation — app not active, panel made key).

2. **Re-key when Zerro reactivates.** Add an `NSApplication.didBecomeActiveNotification`
   observer, mirroring `installScreenChangeObserver()` exactly:
   - Store it in a new `private var didBecomeActiveObserver: Any?` (or `NSObjectProtocol?`)
     property alongside `screenChangeObserver` (~line 52).
   - Install it in `present()` (next to `installScreenChangeObserver()` at ~line 168), or add
     an `installActivationObserver()` helper next to the existing one.
   - In the handler, if `window` exists and is not key, call `window.makeKey()` (hop to
     `@MainActor` like the screen handler does). Guard on `self.window != nil` so a
     stale-after-dismiss notification is a no-op.
   - Remove it in `dismiss()` (~line 214) right where `screenChangeObserver` is removed, and
     nil it out.

Keep the change scoped to focus/keying. Do not touch the selection logic, the coordinate
flip, the model/mic dropdown handling, or the present-time fade.

### Notes / gotchas
- Do **not** add `NSApp.activate(...)` anywhere in this controller — it would re-order every
  Zerro window and defeat the non-activating design (line 128 comment).
- `makeKey()` (not `makeKeyAndOrderFront`) is enough — the window is already ordered front at
  `.screenSaver` level; we only need key status, and ordering-front again is harmless but
  unnecessary.
- Don't drop `becomesKeyOnlyIfNeeded = false` or `hidesOnDeactivate = false` (~line 679/682)
  — they're part of why the panel can hold key status while inactive.
- If, in testing, ⌘-Tab-back-to-Zerro still doesn't re-key via the activate observer alone
  (panel ordering quirks), the click-to-re-key path (#1) is the guaranteed fallback and is
  the more important of the two. Prioritize #1; #2 is the nicety that avoids requiring a
  click first.

## Verification
- Build the `Zerro` scheme (open `apps/desktop/Zerro.xcodeproj` or `xcodebuild`) and confirm
  it compiles.
- Manual repro on the two paths above:
  1. Open overlay → ⌘-Tab to another app → click back on the overlay → press ESC → overlay
     closes. Repeat for Space (mode toggle) and Return (confirm) to confirm full keyboard
     restore, not just ESC.
  2. Open overlay → ⌘-Tab away → ⌘-Tab back to Zerro → press ESC → overlay closes.
- Regression checks:
  - Opening the overlay still does NOT raise Settings / onboarding / the menu-bar panel.
  - First-open ESC/Space/Return still work (no change to the happy path).
  - The first-press-closes-dropdown / second-press-cancels ESC behavior for the mic/model
    dropdowns (keyDown monitor ~388–399) still holds.
  - Unplug-external-display path (`handleScreenParametersChanged`, ~192) still dismisses
    cleanly — confirm the new observer's teardown in `dismiss()` didn't disturb it.
- Run the `ZerroTests` target. If practical, add a unit test asserting the controller
  registers/removes the activation observer across `present()`/`dismiss()` (mirroring how
  `FrameSelectorTests` / `AreaSelectorToolbarLayoutTests` exercise this area), though the core
  re-key behavior is key-window state that's best confirmed by the manual repro above.

## Constraints
- Touch only `AreaSelectorWindowController.swift` unless a test file needs adding.
- No new app activation, no change to overlay visuals, no refactor of the monitor/selection
  logic beyond the re-key calls and the new observer.
