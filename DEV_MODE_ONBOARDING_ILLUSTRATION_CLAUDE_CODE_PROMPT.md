# Claude Code handoff prompt — Add a toolbar illustration to the Dev Mode onboarding step

Copy everything below the line into Claude Code, running from the repo root.

---

You are adding a small illustration to the **Dev Mode onboarding step** in the
Zerro macOS app (`apps/desktop`, Swift/SwiftUI). The step already ships (Welcome
→ Consent → Email → Screen → Mic → **Dev Mode** → All Set). Right now it shows a
`</>` glyph tile, a title/body/hint, and a Continue button. Add a picture of the
selector toolbar with the Dev switch turned ON, so users can recognize the
control the copy refers to. Read this whole brief, then open the file before
editing.

## Goal (decisions are locked)

- Add a **static, native SwiftUI illustration** of the selector toolbar with the
  Dev mode switch active. NOT a bitmap/PNG asset, and NOT a reuse of the live
  `AreaSelectorView` (it depends on `AreaSelectorState`, geometry, scaling, and
  hit-testing — do not import any of that). Build a small self-contained mock.
- It mirrors the real switch's look using the SAME SF Symbols + color token, so
  it stays theme-correct and recognizable. It is a representative mock, not a
  pixel-perfect copy.
- Place it in the step layout's existing `accessory` slot (between the hint text
  and the Continue button). KEEP the existing `</>` header glyph tile.
- Static only — no animation (do NOT use `devBreathingPulse` or any pulse).
- Scope: this touches ONLY
  `apps/desktop/Zerro/Surfaces/Onboarding/OnboardingSteps.swift`. No new logic,
  no analytics, no enum/flow changes.

## Reference — match the real switch

In `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift`,
`modeSegment(...)` (~line 1778) is the source of truth for the switch styling.
Mirror it:

- Two segments inside a recessed well (`Capsule().fill(Color.black.opacity(0.18))`,
  inner padding 3).
- Left = Artifact, SF Symbol `wand.and.stars`, INACTIVE here → icon
  `Color.vfTextTertiary`, no knob fill.
- Right = Dev, SF Symbol `chevron.left.forwardslash.chevron.right`, ACTIVE here →
  green knob `Color.vfDevAccent.opacity(0.22)` + icon `Color.vfDevAccent`.
- `Color.vfDevAccent` is `#34E27A`, defined in `DesignSystem/Colors.swift`.
- Design tokens you may use (from `DesignSystem/Spacing.swift`): `VFSpacing.xs/sm/md`
  (4/8/12), `VFRadius.sm/md/lg` (6/10/14).

## Implementation — `OnboardingSteps.swift`

### 1. Add the illustration view (place near `DevModeStepView`)

```swift
// MARK: - Dev Mode toolbar illustration

/// A static, non-interactive picture of the selector toolbar with the Dev mode
/// switch turned ON — so the onboarding step shows users exactly what to look
/// for and where. Mirrors `AreaSelectorView.modeSegment` styling (same SF
/// Symbols + `vfDevAccent`) but is fully self-contained: no `AreaSelectorState`,
/// no geometry/hit-testing, no animation. Hand-kept mock — if the real mode
/// switch is restyled, update this to match.
private struct DevModeToolbarIllustration: View {
    var body: some View {
        miniToolbar
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The selector toolbar, with the Dev mode switch turned on at its left end.")
    }

    private var miniToolbar: some View {
        HStack(spacing: VFSpacing.sm) {
            modeSwitch
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 18)
            ghostChip(system: "slider.horizontal.3")   // model (representative)
            ghostChip(system: "mic.fill")               // mic
            recordPill                                  // record affordance
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    /// Two-segment mode switch in a recessed well: Artifact (dimmed, inactive) |
    /// Dev (active, green). A soft green ring rings the well to pull the eye.
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment(system: "wand.and.stars", active: false, isDev: false)
            segment(system: "chevron.left.forwardslash.chevron.right", active: true, isDev: true)
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.vfDevAccent.opacity(0.55), lineWidth: 1.5)
        )
    }

    private func segment(system: String, active: Bool, isDev: Bool) -> some View {
        let fill: Color = active
            ? (isDev ? Color.vfDevAccent.opacity(0.22) : Color.white.opacity(0.12))
            : .clear
        let iconColor: Color = active
            ? (isDev ? Color.vfDevAccent : Color.vfTextPrimary)
            : Color.vfTextTertiary
        return Image(systemName: system)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 30, height: 26)
            .background(Circle().fill(fill))
    }

    private func ghostChip(system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextTertiary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }

    private var recordPill: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red.opacity(0.9)).frame(width: 9, height: 9)
            Text("Record")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vfTextSecondary)
        }
        .padding(.horizontal, VFSpacing.sm)
        .frame(height: 26)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
    }
}
```

If a record/danger color token already exists in `DesignSystem/Colors.swift`,
prefer it over `Color.red` for the record dot. If not, `Color.red` is fine.

### 2. Wire it into `DevModeStepView` via the `accessory` slot

`OnboardingStepLayout` already has an `accessory:` parameter (defaults to
`EmptyView`, rendered between `content` and `actions`) — use it. KEEP the glyph
tile and the existing title/body/hint copy unchanged. Only add the `accessory:`
closure:

```swift
struct DevModeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepLayout {
            DevModeGlyphTile()
        } content: {
            // ...title + body + hint stay exactly as they are now...
        } accessory: {
            DevModeToolbarIllustration()
        } actions: {
            OnboardingPrimaryButton("Continue") { onboarding.advance() }
        }
    }
}
```

Do not modify `OnboardingStepLayout` itself — the slot already exists.

## Acceptance criteria

1. The Dev Mode onboarding step renders the toolbar illustration between the
   hint text and the Continue button, with the glyph tile, title, body, and hint
   all unchanged above it.
2. The illustration shows the two-segment switch with the **Dev** segment active
   (green `</>` knob + green ring) and the **Artifact** (`wand.and.stars`)
   segment dimmed, plus the dimmed model/mic chips and a Record pill to its
   right — so the switch reads as the leftmost control of a toolbar.
3. No animation; colors come from `vfDevAccent` / design tokens (verify it looks
   right in the app's dark card background).
4. The illustration has the accessibility label above and is ignored as a
   decorative group (no per-shape VoiceOver noise).
5. Project builds clean; `DevModeToolbarIllustration` and `DevModeGlyphTile` are
   both `private`. The existing `OnboardingStepTests` (3 assertions) still pass —
   this change adds no logic, so no test changes are required.

## Out of scope (do NOT do)

- No PNG/asset-catalog image; no importing or refactoring `AreaSelectorView` /
  `AreaSelectorState`.
- No animation / breathing pulse.
- No copy changes, no enum/flow/analytics changes, no other files.
- No new snapshot test required (optional: the repo's `ImageRenderer` PNG harness
  used by the pill family could later point at `DevModeStepView`, but leave it
  out of this change).
```
