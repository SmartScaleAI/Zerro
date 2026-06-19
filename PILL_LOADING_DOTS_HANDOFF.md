# Handoff: Replace the processing spinner with an animated loading-dots indicator

## Goal
In the pill view, while a response is generating, the spinner (`ProgressView()`) should be replaced with a three-dot "typing" animation — three small dots that pulse/bounce in sequence, like the classic chat loading indicator.

## Where the change lives
`apps/desktop/Zerro/Surfaces/Pill/PillView.swift` — the private `ProcessingPillContent` view (around lines 888–947). It currently renders:

```swift
HStack(spacing: VFSpacing.sm) {
    ProgressView()
        .controlSize(.small)
        .tint(Color.vfTextSecondary)

    Text(phrasePart)
    ...
}
```

The `ProgressView()` is the only thing to replace. This `ProcessingPillContent` view is shared by BOTH the `.processing` state (response generation) and the `.devProgress` state (Dev Mode dispatch), so the new indicator will correctly appear in both progress flows — that's the desired behavior; do not fork it.

## What to build
1. Create a new reusable SwiftUI view, e.g. `LoadingDots`, in `PillView.swift` (place it near `PulsingDot`, around line 768, and follow that view's style — it's the existing animated-indicator pattern in this file).
2. `LoadingDots` should render three `Circle()`s in an `HStack` with a small fixed spacing (≈4pt). Each dot ≈5–6pt diameter.
3. Animate them with a staggered loop so they read as "···" cycling — match the attached reference GIF (a gentle sequential pulse). Two common approaches, pick whichever reads cleanest:
   - **Opacity/scale pulse:** each dot animates opacity (e.g. 0.3 ↔ 1.0) and/or scale on a repeating `easeInOut` loop, with a per-dot phase delay (≈0.2s between dots) via `.delay()` on the animation.
   - **Vertical bounce:** each dot offsets up a few points on a staggered loop.
   The reference GIF shows a soft pulse, so prefer the opacity/scale variant unless bounce matches better on screen.
4. Parameters: accept a `color` (default `Color.vfTextSecondary`, matching the spinner's current tint) and optional `size`. Mirror `PulsingDot`'s API shape (`let color: Color; var size: CGFloat = …; @State private var animating = false`) and kick the animation off in `.onAppear` with `.repeatForever(autoreverses: true)`.
5. Swap `ProgressView().controlSize(.small).tint(Color.vfTextSecondary)` for `LoadingDots()` (default tint already matches, so no extra modifiers needed). Keep the surrounding `HStack(spacing: VFSpacing.sm)`, the `Text(phrasePart)`, the elapsed-time part, and the `Cancel` button exactly as they are.

## Design tokens to use (don't hardcode)
- Dot color: `Color.vfTextSecondary` (= white @ 55% opacity) — same as the spinner today.
- Spacing between the indicator and the label is already `VFSpacing.sm` (8) in the parent HStack — leave it.
- Internal dot spacing ≈4pt (you can use `VFSpacing.xs`).

## Constraints
- The indicator sits inside a **fixed-width, fixed-height locked capsule** (440×50, see `lockedCapsuleWidth`/`lockedCapsuleHeight`). The `LoadingDots` view must have a small, stable intrinsic size — use `.fixedSize()` if needed so it never pushes the label, timer, or Cancel button around. Roughly match the spinner's current footprint (~16pt wide).
- Animation must run continuously while the state is active and not leak timers — `.onAppear` + `repeatForever` (the same pattern `PulsingDot` uses) is sufficient; no manual `Timer`.
- Pure-renderer rule: `ProcessingPillContent` and `PillView` take no new external state. The animation is fully self-contained in `LoadingDots`.

## Verification
- Build the desktop target (Xcode / `xcodebuild`) and confirm it compiles.
- Use the existing SwiftUI preview `#Preview("Processing")` (around line 1202) to visually confirm the three dots animate in place of the spinner. Add a second preview if helpful (e.g. a longer phrase label) to confirm layout stays locked.
- Confirm the `.devProgress` flow still renders correctly (it reuses the same view).
- Confirm nothing shifts in the capsule: phrase truncates, timer stays pinned, Cancel stays on the trailing edge.

## Out of scope
Don't touch the recording waveform, result cards, or any other state. Only the processing/progress indicator changes.
