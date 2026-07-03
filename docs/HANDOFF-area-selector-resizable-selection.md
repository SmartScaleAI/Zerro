# Handoff: Resizable / Movable Area Selection (CleanShot-style edit handles)

## Goal

After the user draws a region in the area-selector overlay, let them **adjust it
before recording** instead of being forced to redraw:

1. **Resize** — drag any of the 8 handles (4 corners + 4 edge midpoints) to grow
   or shrink the region. Corners move two edges at once; edge midpoints move one.
2. **Move** — drag the **interior** of the region to reposition the whole
   rectangle without changing its size.
3. **Cursor feedback** — hovering a handle shows the matching resize cursor;
   hovering the interior shows a move (open-hand) cursor; everywhere else stays
   the crosshair. This is the discoverability signal that the region is editable.

This matches CleanShot X / macOS Screenshot (`⇧⌘5`) behavior. **Out of scope for
this pass:** arrow-key nudging (deferred — easy follow-up once the resize state
exists), and multi-display selections (already a documented Phase 7 deferral).

---

## Why this is cheaper than it looks (read before coding)

The **visual scaffolding already exists** and the **event plumbing is already
centralized** — this feature is almost entirely "make the handles that are
already on screen actionable."

- `AreaSelectorView` **already renders all 8 handles** once a selection settles
  (`selectionHandles(at:)`, corners always + edge midpoints when
  `!isDragging`). The code comment there literally says they are *"not actionable
  yet … would be the resize affordance when resize lands."* This is that.
- **Every mouse event already flows through one place.** The SwiftUI tree is
  hit-test-disabled (`AreaSelectorRootView.allowsHitTesting(false)`), and
  `AreaSelectorWindowController.installEventMonitors` runs a single
  `NSEvent.addLocalMonitorForEvents` monitor that owns `leftMouseDown /
  leftMouseDragged / leftMouseUp / mouseMoved / scrollWheel`. We add the
  resize/move/hover logic **inside that existing monitor**, ahead of the
  existing "drag-to-select" branch — exactly the same pattern the toolbar
  controls already use (hit-test a frame, act, `return nil`).
- **Coordinates already line up.** The monitor converts every event to
  view-local **top-left** points (`y' = contentH - y`). The handle positions in
  the view are in the *same* space (`cornerHandlePositions` /
  `edgeMidpointHandlePositions`). So a handle hit-test is a plain
  point-in-rect test in coordinates we already compute every event.
- **The selection is two points.** `AreaSelectorState` stores `dragOrigin` and
  `dragCurrent`; `selectionRect` is the normalized `CGRect` derived from them.
  Resize and move are just principled mutations of those two points (details
  below), so `selectionRect`, `confirmableSelectionRect`, the dim cutout, the
  dimensions readout, and every existing test keep working unchanged.

**Key constraint to respect:** `AreaSelectorState.minimumSelectionSize = 100`
(points, per axis). Resize must clamp to this so the region can never be dragged
below the confirmable floor (today an over-shrunk region silently disables
Record; with live resize the user would see it "stick" at the minimum, which is
the correct CleanShot feel).

---

## Files in play

| File | Role | Change |
|---|---|---|
| `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorState.swift` | Selection model | **New:** active-interaction enum, handle enum, grab/resize/move mutations, min-size clamp. |
| `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift` | Renders rect + handles (read-only) | **New:** static hit-test helpers + enlarged hit slop; optionally widen handle hit targets. Existing rendering unchanged. |
| `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift` | Owns the event monitor | **New:** hit-test handles/interior on `mouseDown`, route `dragged`/`up` to resize/move, set `NSCursor` on `mouseMoved`. |
| `apps/desktop/ZerroTests/AreaSelectorResizeTests.swift` | — | **New test file** (pure state + frame-math, mirrors `AreaSelectorFullScreenTests`). |

No new permissions, no new windows, no capture-pipeline changes. `SelectionRect`
(the Phase 7 handoff type) is untouched — confirm still reads `state.selectionRect`.

---

## Design

### 1. State: model the active interaction (`AreaSelectorState.swift`)

Today the only interaction is "creating a new drag." Add an explicit notion of
*what the current left-drag is doing*, plus a stable handle identity.

```swift
/// Which part of an existing selection a press grabbed. Drives both the
/// resize math and the hover cursor. Corners move two edges; edges move one.
enum Handle: Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// What the in-flight left-drag is doing. `.none` between gestures.
enum DragInteraction: Equatable {
    case none
    case creating                 // the existing draw-a-new-rect behavior
    case resizing(Handle)         // dragging a handle of a settled rect
    case moving                   // dragging the interior of a settled rect
}

private(set) var interaction: DragInteraction = .none

/// Anchor captured at grab time so resize/move are computed as deltas from the
/// gesture start rather than absolute cursor position (prevents the rect
/// "jumping" so its corner snaps under the cursor on first move).
private var dragAnchorRect: CGRect?      // selection rect at mouseDown
private var dragAnchorPoint: CGPoint?    // cursor location at mouseDown
```

**Why keep the two-point (`dragOrigin`/`dragCurrent`) model instead of switching
to a stored `CGRect`?** Everything downstream (`selectionRect`,
`confirmableSelectionRect`, the cutout path, all current tests) reads through the
computed `selectionRect`. Keeping that contract means zero churn there. The trick
is to **normalize the two points to known corners at grab time** so edge resizes
can move exactly one axis:

```swift
/// Begin editing an existing, settled selection. Normalizes the stored points
/// so dragOrigin == top-left and dragCurrent == bottom-right, which lets the
/// resize math touch one coordinate per moved edge.
func beginEdit(_ kind: DragInteraction, at point: CGPoint) {
    guard let rect = selectionRect else { return }   // normalized CGRect
    dragOrigin  = CGPoint(x: rect.minX, y: rect.minY) // top-left
    dragCurrent = CGPoint(x: rect.maxX, y: rect.maxY) // bottom-right
    dragAnchorRect = rect
    dragAnchorPoint = point
    interaction = kind
    isDragging = true        // reuse the existing "live" flag (see note below)
    mode = .area             // editing is only meaningful in area mode
}
```

> **`isDragging` note.** Today `isDragging == true` collapses the 8 handles back
> to 4 and the toolbar uses `confirmableSelectionRect` (nil while dragging) to
> hide Record. We want the same "hide chrome while actively adjusting" behavior
> during resize/move, so reusing `isDragging` is correct — Record reappears on
> mouseUp exactly as it does after an initial draw. The one wrinkle: while the
> 8→4 handle collapse during edit is acceptable, if you'd rather keep all 8
> visible mid-resize, branch the view on `interaction` instead. Recommended:
> keep the existing `isDragging`-based collapse for consistency.

**Resize** updates only the coordinate(s) the grabbed handle owns, clamped so
each axis stays ≥ `minimumSelectionSize`. Because `selectionRect` re-normalizes
with `min`/`max`, dragging a handle *past* the opposite edge flips naturally
(CleanShot does the same), and the next gesture re-grabs cleanly.

```swift
func updateResize(to p: CGPoint) {
    guard case .resizing(let h) = interaction,
          var o = dragOrigin, var c = dragCurrent else { return }
    let minS = Self.minimumSelectionSize
    // o = top-left, c = bottom-right (from beginEdit normalization).
    switch h {
    case .left, .topLeft, .bottomLeft:   o.x = min(p.x, c.x - minS)
    case .right, .topRight, .bottomRight: c.x = max(p.x, o.x + minS)
    default: break
    }
    switch h {
    case .top, .topLeft, .topRight:       o.y = min(p.y, c.y - minS)
    case .bottom, .bottomLeft, .bottomRight: c.y = max(p.y, o.y + minS)
    default: break
    }
    dragOrigin = o; dragCurrent = c
}
```

> The clamp above intentionally **pins** at the minimum rather than flipping when
> the cursor crosses, because pinning is the behavior users expect from a
> deliberate edge drag. If you prefer true flip-through (macOS Screenshot allows
> it), drop the `c.x - minS` style guards and clamp the *result* rect instead.
> Pick one and pin it with a test — don't leave it ambiguous.

**Move** translates both points by the gesture delta, then clamps the whole rect
inside the overlay bounds (`overlaySize`) so the region can't be shoved
off-screen:

```swift
func updateMove(to p: CGPoint) {
    guard interaction == .moving,
          let anchorRect = dragAnchorRect, let anchorPt = dragAnchorPoint else { return }
    var r = anchorRect.offsetBy(dx: p.x - anchorPt.x, dy: p.y - anchorPt.y)
    // Clamp inside the overlay (overlaySize is set by the controller at present).
    let maxX = max(0, overlaySize.width  - r.width)
    let maxY = max(0, overlaySize.height - r.height)
    r.origin.x = min(max(0, r.origin.x), maxX)
    r.origin.y = min(max(0, r.origin.y), maxY)
    dragOrigin  = CGPoint(x: r.minX, y: r.minY)
    dragCurrent = CGPoint(x: r.maxX, y: r.maxY)
}

func endEdit() {
    isDragging = false
    interaction = .none
    dragAnchorRect = nil
    dragAnchorPoint = nil
}
```

`beginDrag`/`updateDrag`/`endDrag` (the create path) stay, but `beginDrag` should
set `interaction = .creating` and `endDrag` should reset it to `.none`, so the
monitor can always tell the three gestures apart.

### 2. View: hit-test helpers with hit slop (`AreaSelectorView.swift`)

The handles render at 8×8 pt — too small to grab reliably. Add **static** helpers
(so the controller can call them the same way it calls `recordButtonFrame` etc.)
that hit-test with a generous slop. Reuse the existing private
`cornerHandlePositions`/`edgeMidpointHandlePositions` math (promote to `static`
or duplicate the 8 points in the helper).

```swift
/// Hit slop around each handle's center — the grabbable square is larger than
/// the 8pt visual. ~22pt matches the comfort of CleanShot's targets.
static let handleHitSlop: CGFloat = 22

/// Which handle (if any) is under `point`, given the settled selection rect in
/// view-local top-left coords. Corners win ties over edges (checked first).
static func handleHitTest(at point: CGPoint, selection rect: CGRect) -> AreaSelectorState.Handle? { … }

/// True when `point` is inside the selection but not on a handle — the
/// drag-to-move region. (Use the rect inset by a few pt so edge handles win.)
static func isInteriorHit(_ point: CGPoint, selection rect: CGRect) -> Bool { … }
```

Edge handles should also be grabbable **along the edge**, not just at the exact
midpoint dot — i.e. a press within `handleHitSlop` of an edge segment (between the
corner zones) counts as that edge. CleanShot lets you grab anywhere along an
edge; replicate that so the midpoint dot is a hint, not the only target.

No change to the existing render path — the dots stay where they are; we're only
adding the *interaction* geometry.

### 3. Controller: route the gesture (`AreaSelectorWindowController.swift`)

All edits live in the existing `mouseMonitor` closure in `installEventMonitors`.
The `point` (view-local, top-left) is already computed there.

**On `leftMouseDown`** — insert handle/interior hit-testing **after** the
toolbar-control and menu-open blocks (so toolbar clicks still win) but **before**
the existing `state.beginDrag(at:)` create path:

```swift
// Only when there's a settled selection to edit, no menu open, in area mode.
if !anyMenuOpen, state.mode == .area, let rect = state.confirmableSelectionRect {
    if let handle = AreaSelectorView.handleHitTest(at: point, selection: rect) {
        state.beginEdit(.resizing(handle), at: point)
        return nil
    }
    if AreaSelectorView.isInteriorHit(point, selection: rect) {
        state.beginEdit(.moving, at: point)
        return nil
    }
}
// …falls through to the existing `state.beginDrag(at: point)` to draw a new rect.
```

> Use `confirmableSelectionRect` (nil while dragging, nil below min size) as the
> gate so we only offer editing on a real, settled region — never mid-create.

**On `leftMouseDragged` / `leftMouseUp`** — branch on `state.interaction` instead
of the current single `isDragging` path:

```swift
case .leftMouseDragged:
    switch state.interaction {
    case .creating: if state.isDragging { state.updateDrag(to: point) }
    case .resizing: state.updateResize(to: point)
    case .moving:   state.updateMove(to: point)
    case .none:     break
    }
case .leftMouseUp:
    switch state.interaction {
    case .creating: if state.isDragging { state.endDrag(at: point) }
    case .resizing, .moving: state.endEdit()
    case .none: break
    }
```

**On `mouseMoved`** — set the cursor from a hit-test (add alongside the existing
hover-flag updates). Only when a settled selection exists and no menu/toolbar
control is hovered:

```swift
if state.mode == .area, !anyMenuOpenOrToolbarHover, let rect = state.confirmableSelectionRect {
    if let h = AreaSelectorView.handleHitTest(at: point, selection: rect) {
        Self.resizeCursor(for: h).set()
    } else if AreaSelectorView.isInteriorHit(point, selection: rect) {
        NSCursor.openHand.set()
    } else {
        NSCursor.crosshair.set()
    }
} else {
    NSCursor.crosshair.set()   // default overlay cursor
}
```

Call `.set()` on **every** `mouseMoved` (don't push/pop). The system resets the
cursor as the pointer moves, so re-asserting each move is the robust pattern for a
borderless overlay with no `NSTrackingArea`. On `endEdit` and at `present()`,
default the cursor to `.crosshair` so the overlay reads as "draw here" before any
selection. On `dismiss()`, restore with `NSCursor.arrow.set()`.

> **Where do you currently set the overlay cursor?** Nowhere — there's no
> `NSCursor` usage in the app today. Set `NSCursor.crosshair.set()` once after the
> window is keyed in `present()` so the initial overlay shows the crosshair, then
> let `mouseMoved` take over.

#### Cursor caveat (decide explicitly)

AppKit's **public** `NSCursor` has axis resize cursors
(`.resizeLeftRight`, `.resizeUpDown`) and `.openHand`/`.closedHand` for move, but
**no public diagonal** ("↘↖" / "↗↙") cursor. Options, in order of recommendation:

1. **Public-only (recommended, App-Store-safe):** corners use the nearest axis
   cursor — top-left/bottom-right → `.resizeUpDown` (or `.resizeLeftRight`); pick
   one convention. Honest, ships clean, slightly less precise than CleanShot.
2. **Private diagonal cursors:** AppKit exposes undocumented
   `_windowResizeNorthWestSouthEastCursor` / `…NorthEastSouthWest` via selectors.
   CleanShot-grade fidelity, but it's private API — gate it behind a `respondsTo`
   check with the public fallback, and weigh App Store risk.
3. **Custom image cursor:** ship two diagonal `NSImage`s and build
   `NSCursor(image:hotSpot:)`. Full control, no private API, a little asset work.

Switch the move cursor to `.closedHand` while `interaction == .moving` (grab feel)
and back to `.openHand` on hover — matches the macOS direct-manipulation idiom.

---

## Interaction edge cases to handle (and test)

- **Min size pin.** Shrinking any edge/corner stops at `minimumSelectionSize`;
  the rect never disappears and Record never flickers off mid-resize.
- **Move stays on-screen.** Dragging the interior clamps inside `overlaySize`;
  the region can't be lost off an edge.
- **Corners beat edges beat interior** in hit-test priority (a press in the
  overlap zone resizes the corner, not the edge or the body).
- **Space → full-screen** still works: full-screen mode has no editable rect, so
  the new `mouseDown` block is gated on `state.mode == .area`. Drawing/editing
  then dropping back is already handled (`beginDrag` resets `mode = .area`).
- **A brand-new drag after editing** still supersedes: a `mouseDown` that misses
  every handle and the interior falls through to `beginDrag` (draw fresh), exactly
  as today.
- **Toolbar/menu precedence preserved.** The new hit-test sits after the
  toolbar-control and menu-open blocks, so clicking Record / a chip / a dropdown
  row over the selection still acts on the control, never the resize.
- **Trailing drag/up after a consumed mouseDown.** The `interaction == .none`
  default in the dragged/up switch means a press that started on a control (no
  `beginEdit`/`beginDrag`) can't accidentally resize — same guard the current
  `isDragging` check provides.

---

## Test plan (`AreaSelectorResizeTests.swift`)

Mirror `AreaSelectorFullScreenTests` — pure `@MainActor` state + static
frame-math, no live `NSWindow` (the view-local→global handoff is already
hardware-verified). Cover:

- **Handle hit-testing:** each of the 8 handles resolves at its expected point;
  hit slop catches a near-miss; edge-segment presses resolve to that edge;
  corners win over edges in the overlap; interior hit is true inside / false on a
  handle / false outside.
- **Resize math:** dragging `.right` moves only `maxX`; `.top` moves only `minY`;
  `.bottomRight` moves both; the opposite edge stays put (anchor correct).
- **Min-size clamp:** shrinking past `minimumSelectionSize` pins at the floor on
  each axis; `confirmableSelectionRect` stays non-nil throughout.
- **Move math:** interior drag translates the rect by the delta, size unchanged;
  clamps at each overlay edge; can't go negative or past `overlaySize`.
- **Gesture bookkeeping:** `beginEdit` sets `interaction`/`isDragging`; `endEdit`
  clears them and re-exposes `confirmableSelectionRect`; a fresh `beginDrag`
  after an edit resets `interaction = .creating` and starts a new rect.
- **Mode gating:** entering full-screen then back to area leaves edit state sane;
  resize methods are no-ops when `interaction == .none`.

Cursor selection (`resizeCursor(for:)`) can be unit-tested as a pure
handle→`NSCursor` mapping if you factor it out as a static function.

Run: `xcodebuild test -scheme Zerro -only-testing:ZerroTests/AreaSelectorResizeTests`
(plus the existing `AreaSelector*Tests` to confirm no regression). Manual pass on
hardware for the actual cursor glyphs and drag feel.

---

## Suggested commit slicing

1. **State** — `Handle`/`DragInteraction` enums + `beginEdit`/`updateResize`/
   `updateMove`/`endEdit` + clamps, with `AreaSelectorResizeTests` for the math.
   (No behavior change yet — nothing calls them.)
2. **View** — static `handleHitTest` / `isInteriorHit` + hit slop, with tests.
3. **Controller wiring** — mouseDown routing + dragged/up branch (resize + move
   become live, no cursor yet).
4. **Cursor feedback** — `mouseMoved` cursor set + present/dismiss defaults +
   `resizeCursor(for:)` mapping.

Slices 1–3 are independently testable; cursor (4) is the only part needing
hardware verification.

---

## Deferred / non-goals (call out in the PR)

- **Arrow-key nudge** (and Shift = larger step). The `interaction` state makes
  this a small follow-up: handle key events in the existing `keyMonitor` when a
  settled selection exists. Left out of this pass per scope.
- **Multi-display selections.** Unchanged — still the documented Phase 7
  deferral; a selection lives on one overlay/one display.
- **Aspect-ratio lock / fixed-size presets.** Not requested.
