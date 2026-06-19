# Follow-up: Make LoadingDots a true traveling wave + slightly smaller dots

This refines the `LoadingDots` view you just added to `apps/desktop/Zerro/Surfaces/Pill/PillView.swift` (placed right after `PulsingDot`, ~line 805). Two changes: (1) make the dots a true continuous left-to-right wave, and (2) make each dot a touch smaller.

## Problem with the current version
All three dots animate off a single shared `animating` boolean with a per-dot `.delay()`. With `autoreverses: true`, that `.delay()` only offsets the FIRST half-cycle — after that the dots drift toward pulsing in unison instead of holding a clean rolling stagger. The result reads as a soft collective pulse, not a traveling "···" wave.

## What to change

### 1. Drive a continuous, phase-offset wave
Replace the shared-boolean + `.delay()` approach with one where each dot holds a permanent phase offset for the life of the animation, so the wave keeps traveling left→right forever. Use `TimelineView(.animation)` and compute each dot's brightness/scale from a continuous phase. Something along these lines:

```swift
struct LoadingDots: View {
    var color: Color = .vfTextSecondary
    var size: CGFloat = 4   // was 5 — see change #2

    private let dotCount = 3
    private let period: Double = 1.1      // seconds for one full wave cycle
    private let phaseStep: Double = 0.18  // fraction-of-cycle offset between adjacent dots

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: VFSpacing.xs) {
                ForEach(0..<dotCount, id: \.self) { index in
                    // Each dot is the same sine wave shifted by a fixed phase, so the
                    // bright crest travels left→right and never converges.
                    let phase = (t / period) - (Double(index) * phaseStep)
                    let wave = (sin(phase * 2 * .pi) + 1) / 2   // 0…1
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .opacity(0.3 + 0.7 * wave)      // 0.3 ↔ 1.0
                        .scaleEffect(0.7 + 0.3 * wave)  // 0.7 ↔ 1.0
                }
            }
        }
        .fixedSize()
    }
}
```

Notes:
- Drop the `@State private var animating` / `.onAppear` — `TimelineView(.animation)` drives the redraws itself, so there's no boolean to flip and no manual `Timer`.
- Keep the same visual range as before (opacity 0.3↔1.0, scale 0.7↔1.0) so only the *motion character* changes, not the look of an individual dot.
- Tune `period` / `phaseStep` so the stagger is clearly visible but gentle — roughly matching the reference GIF's pace. The values above are a sensible starting point; adjust if it feels too fast or too subtle.
- Keep `.fixedSize()` so the locked processing capsule layout (phrase truncation, pinned timer, trailing Cancel) is unaffected.

### 2. Slightly smaller dots
Reduce the default dot `size` from `5` to `4`. Keep the `VFSpacing.xs` (4pt) inter-dot spacing as-is — at 4pt dots that spacing still reads cleanly. (If 4pt looks too tight against the spacing, `4.5` is acceptable, but try `4` first.)

## Keep unchanged
- The `LoadingDots()` call site inside `ProcessingPillContent` — no args needed, the new defaults apply. Both `.processing` and `.devProgress` continue to share it.
- The `color` default (`.vfTextSecondary`) and the `VFSpacing.xs` HStack spacing.
- Everything else in the file.

## Update the doc comment
The current `// MARK: - LoadingDots` comment still says "opacity+scale pulse ... staggered by a per-dot phase delay." Update it to describe the new mechanism: a continuous `TimelineView`-driven sine wave with a fixed per-dot phase offset, so the bright crest travels left→right indefinitely (no shared boolean, no `.delay()`, no manual `Timer`).

## Verification
- Build the Zerro scheme (`xcodebuild ... -scheme Zerro`) and confirm BUILD SUCCEEDED, including the existing `#Preview("Processing")` and `#Preview("Processing · Long")` previews.
- Open `#Preview("Processing")` in the Xcode canvas and confirm the dots now read as a clean, continuous left-to-right traveling wave (the bright dot moves across and repeats) rather than a unison pulse, and that the dots are visibly a bit smaller.
- Confirm the `· Long` preview still shows the phrase truncating with `…`, the timer pinned, and Cancel on the trailing edge — i.e. the smaller dots and `TimelineView` didn't change the locked capsule footprint.

## Out of scope
Only `LoadingDots` and its doc comment change. Don't touch `ProcessingPillContent`, the result cards, the recording waveform, or anything else.
