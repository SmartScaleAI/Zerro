# Dev Ring — make it thinner + soften the retract (Claude Code handoff)

## Goal

Two small visual tweaks to the green Dev Mode pulsing ring:

1. **Decrease the width** of the ring — make the band noticeably thinner/sleeker.
2. **Soften the pulse retract** — right now, at the low point of the breathe the glow recedes almost all the way back to the screen edge. Make it retract only *a little bit*, so a steady visible band always remains and just breathes gently inward/outward. This matches how **Claude in Chrome** draws its border while it's acting on a tab.

Everything else about the ring (color, lifecycle, click-through, multi-display, perf approach) stays exactly as-is. This is presentation-only tuning of numbers in one view — do **not** re-architect anything.

## The one file to change

`apps/desktop/Zerro/Surfaces/DevRing/DevRingWindowController.swift`

All the relevant values live in the `DevRingView` struct near the bottom. Current tuning constants:

```swift
private let cornerRadius: CGFloat = 14
private let crispLineWidth: CGFloat = 9
private let glowLineWidth: CGFloat = 22
private let glowBlur: CGFloat = 34

private let minOpacity: CGFloat = 0.45
private let maxOpacity: CGFloat = 1.0
private let pulseDuration: TimeInterval = 1.9
```

## Why these two knobs do what we want

Read `DevRingView.body` before changing anything. The ring is two concentric rounded-rect strokes (a wide blurred `glowLineWidth` glow + a crisp `crispLineWidth` line), centered on the window-bounds path so their outer half is clipped off-screen and the inner half + blur reads as a band fading inward from the edge. The whole thing is flattened once with `.drawingGroup()`, and the pulse animates **opacity only** (`.opacity(pulsedUp ? maxOpacity : minOpacity)`) on a `repeatForever(autoreverses: true)` loop. Keep it opacity-only — that's the whole reason this doesn't pin the CPU the way the web box-shadow version did.

- **Width** is set by `crispLineWidth`, `glowLineWidth`, and `glowBlur`. Shrink all three to make the band thinner. (Only the inner ~half of each stroke is visible on-screen, plus the blur falloff, so effective on-screen thickness ≈ half the line widths + the blur radius.)

- **The "retract"** is a side effect of the opacity-only pulse: at the `minOpacity` trough, the softest/widest part of the blurred falloff drops below visibility first, so the band appears to pull back toward the crisp edge line. **Raising `minOpacity`** keeps more of the inward glow present at the trough, so it recedes only slightly instead of collapsing to the edge — i.e. a gentle breathe with a constant visible border, which is the Claude-in-Chrome look. The distance it retracts is essentially `maxOpacity − minOpacity`; smaller gap = smaller retract.

## Suggested starting values (tune by eye)

```swift
private let cornerRadius: CGFloat = 14   // unchanged
private let crispLineWidth: CGFloat = 5  // was 9  — thinner crisp line
private let glowLineWidth: CGFloat = 14  // was 22 — thinner glow band
private let glowBlur: CGFloat = 22       // was 34 — tighter falloff

private let minOpacity: CGFloat = 0.70   // was 0.45 — retract only a little
private let maxOpacity: CGFloat = 1.0    // unchanged
private let pulseDuration: TimeInterval = 1.9  // unchanged (bump to ~2.1 if you want it calmer)
```

Feel free to nudge: if it's still retracting too far, raise `minOpacity` toward `0.8`; if the breathe becomes too subtle to notice, drop it back toward `0.6`. If it reads too thin, bump `glowLineWidth`/`glowBlur` back up a few points together. Keep `crispLineWidth` ≤ `glowLineWidth` and keep the corner radius so the four edges still meet cleanly at the corners.

## Reference: what Claude in Chrome actually does (for the target feel)

Claude in Chrome renders a `.claude-agent-glow-border` overlay with a `claude-pulse` animation while the agent controls a tab — a soft glowing border that breathes but **always keeps a visible border**; the intensity/spread modulates slightly rather than the border disappearing. (Its web implementation animated layered inset `box-shadow`s every frame, which isn't GPU-composited and pinned Chrome Helper at ~50% CPU on M1 — see anthropics/claude-code#20070. This desktop ring deliberately avoids that by animating opacity on a rasterized layer, so **do not** switch to animating blur/shadow radius to get the effect.)

## Constraints / do not touch

- Keep the pulse **opacity-only** on the `.drawingGroup()`-flattened layer. Do not animate `glowBlur`/shadow radius or drive the pulse from a `Timer`/`TimelineView`.
- Don't change the ring's color (`Color.vfDevAccent`), lifecycle (`AppState.devRingActive` / `preferences.pulsingRingEnabled` gating), window config, click-through, or multi-display logic.
- No new files, no new infrastructure — just adjust the constants in `DevRingView` (and only touch `body` if a tiny tweak is needed to hit the look).

## Acceptance

- The ring is visibly thinner than before.
- Through a full breathe cycle a green band stays present at all times — it only recedes slightly at the low point instead of pulling back to the screen edge.
- CPU/GPU cost while pulsing stays negligible (still opacity-only; verify in Activity Monitor during an active Dev run).
- Start/stop, click-through, and per-display behavior are unchanged.
