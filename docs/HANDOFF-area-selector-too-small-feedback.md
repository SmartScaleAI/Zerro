# Handoff: Area-selector "selection too small" feedback

## Goal

When the user draws an area selection smaller than the minimum on **either axis**, the
overlay currently just hides the toolbar and silently ignores Return — which reads as a
bug. Add explicit feedback:

1. Turn the **selection border red** while the current selection is below the minimum.
2. Show a **message** explaining why (and what size is required).
3. Keep Return/Enter from starting a recording on an undersized region — and make that
   refusal *visible* instead of a silent no-op.

## Background (already in place — do not duplicate)

- `AreaSelectorState.minimumSelectionSize` = `100` (pt, applied per-axis).
- `AreaSelectorState.confirmableSelectionRect` returns `nil` in `.area` mode unless the
  settled selection is `>= minimumSelectionSize` on **both** width and height. This is why
  the floating toolbar (`floatingToolbar(in:)`) and the Record button already don't appear
  for small regions — leave that gate as is.
- The Return/Enter path is **already guarded**: `keyDown` case `36, 76` →
  `confirmCurrentSelection(...)` → `confirmAreaSelection(...)`, which early-returns when
  `selectionRect` is below `minimumSelectionSize` on either axis. So recording already
  cannot start on a too-small region. The remaining work for requirement #3 is only to give
  the user *feedback* when that guard fires, not to add a new block.

All files below are under `apps/desktop/Zerro/Surfaces/AreaSelector/`.

## Changes

### 1. State — add a "too small" flag (`AreaSelectorState.swift`)

Add a computed property that is true when there is a real area selection that is under the
minimum on either axis. Make it independent of `isDragging` so the border can go red live as
the user drags:

```swift
/// True in `.area` mode when there IS a selection but it's below
/// `minimumSelectionSize` on either axis — i.e. drawn/settled but not yet large
/// enough to record. Drives the red border + "too small" message. The inverse of
/// what makes `confirmableSelectionRect` non-nil (minus the `!isDragging` clause,
/// so feedback shows live while the user is still sizing the rect).
var isSelectionTooSmall: Bool {
    guard mode == .area, let rect = selectionRect else { return false }
    return rect.width < Self.minimumSelectionSize || rect.height < Self.minimumSelectionSize
}
```

### 2. View — red border + message (`AreaSelectorView.swift`)

**Border color.** In `selectionBorder(at:)` (currently strokes
`state.isDevMode ? .vfDevAccent : .vfBrandAccent`), make "too small" win over both the brand
and dev accents (red = error regardless of mode). Use the existing token `Color.vfRecordingRed`
(#FF453A):

```swift
let strokeColor: Color = state.isSelectionTooSmall
    ? .vfRecordingRed
    : (state.isDevMode ? .vfDevAccent : .vfBrandAccent)
```

Apply the same red to the dimensions readout in `dimensionsLabel(at:)` (fill/background) so the
size numbers themselves read as the problem. Keep `.devBreathingPulse(...)` as is.

**Message.** Add a new `@ViewBuilder` function — model it closely on the existing
`devValidationBanner(in:)` (search for it in this file) for the pill styling, and on
`instructionPill(in:)` for the capsule chrome. Render it in the top-level `ZStack` in `body`
(next to the other overlay children like `devValidationBanner(in: bounds)`), gated on
`state.isSelectionTooSmall`:

```swift
@ViewBuilder
private func tooSmallMessage(in bounds: CGSize) -> some View {
    if state.isSelectionTooSmall, let rect = state.selectionRect {
        // capsule: exclamationmark.triangle.fill (Color.vfRecordingRed) + text.
        // Copy — interpolate the constant so it can't drift:
        //   "Selection too small — drag at least 100 × 100 to record"
        // Anchor it centered on the selection, hanging `toolbarGap` below rect.maxY,
        // flipping above if it would clip the bottom, and clamping X into `bounds`
        // (mirror the fallback-positioning math in `toolbarFrame(...)`). This puts it
        // where the toolbar would otherwise be, so it reads as the toolbar's stand-in.
    }
}
```

Copy string (build from the constant, don't hardcode `100`):

```swift
let m = Int(AreaSelectorState.minimumSelectionSize)
Text("Selection too small — drag at least \(m) \u{00D7} \(m) to record")
```

### 3. Controller — make the Return refusal visible (`AreaSelectorWindowController.swift`)

`confirmAreaSelection(...)` already `return`s early when the selection is under the minimum.
In that early-return branch (only in `.area` mode; full-screen is always confirmable), instead
of silently bailing, surface feedback so the user understands nothing happened. Reuse the same
message channel the too-small message uses (or briefly emphasize/pulse it). This ties
requirement #3's silent no-op to visible feedback without adding a second gate.

If you prefer to keep the message state on `AreaSelectorState` (recommended, mirroring
`devValidationMessage`), have the controller call into state here; otherwise just ensure the
existing too-small message is already on-screen (it will be, since the border/message follow
`isSelectionTooSmall`) and let the early return stand.

## Design notes / decisions

- Red overrides the green dev accent too — error state takes precedence over mode color.
- Border + message show **live during the drag** as well as after release, so the user gets
  "keep going, it's too small" guidance in real time. If this feels too naggy mid-drag, gate
  only the *message* (not the border) on `!state.isDragging` so it appears once the user
  releases an undersized rect.
- Don't touch `minimumSelectionSize` or the per-axis rule unless you also want to revisit the
  earlier idea of an area-based threshold — out of scope here.

## Verification

- Add unit tests alongside the existing `AreaSelector*Tests` in `apps/desktop/ZerroTests/`:
  - `isSelectionTooSmall` boundaries: a 99×200 rect and 200×99 rect are too small; exactly
    100×100 is **not** (the guard is `>=`); 150×150 is not.
  - `isSelectionTooSmall` is false in `.fullScreen` mode and when `selectionRect == nil`.
  - Confirm path: a too-small selection does **not** call `state.confirm(...)` (assert the
    onConfirm callback never fires); a >= min selection does.
- Build the app and manually check: draw a wide-but-short region (like 494×43) → red border +
  message, Return does nothing but the message is visible; expand past 100 on both axes →
  border returns to brand/dev accent, toolbar appears, Return records.
- Run the existing area-selector test suite to confirm no regressions in toolbar layout /
  hit-testing.
