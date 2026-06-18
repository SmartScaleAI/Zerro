# Handoff — Unify the Pill design system (buttons, icons, spacing, tokens)

## Goal

The pill surface (`apps/desktop/Zerro/Surfaces/Pill/`) has grown to ~12 states that each
hand-roll their own buttons, icons, and spacing. The chrome is already shared, but the
controls inside have drifted: primary buttons use four different fills, secondary buttons
have three different treatments, leading icons are sometimes badged and sometimes bare, and
the hover-gray color is copy-pasted as a literal in ~5 places.

Refactor the **entire pill family** onto **one set of shared components and tokens**, using a
**semantic-by-intent** color rule. This is a *visual-consistency + deduplication* refactor —
**do not change any state logic, bridge mapping, layout structure, or the locked capsule
widths/heights.** Only the control rendering (color, text weight/size, padding, hover, icon
treatment) and the tokens behind it should change.

## Files in scope

- `apps/desktop/Zerro/Surfaces/Pill/PillView.swift` (primary — all the inline pill content views)
- `apps/desktop/Zerro/Surfaces/Pill/ArtifactCardView.swift` (result/failure/dev-result card buttons)
- `apps/desktop/Zerro/DesignSystem/Colors.swift` (add tokens)
- `apps/desktop/Zerro/DesignSystem/Spacing.swift` (add metric tokens)
- New file: `apps/desktop/Zerro/Surfaces/Pill/PillControls.swift` (the shared components)

## Hard constraints (read before touching anything)

1. **Do not alter the locked capsule sizing.** `PillView.capsuleWidth (440)` /
   `capsuleHeight (50)`, the `lockedCapsuleWidth`/`lockedCapsuleHeight` switches, and the
   `fixedSize` / `frame(width:)` patterns exist to keep `NSHostingView` from entering an
   update-constraints loop that AppKit aborts by crashing (see the comments in
   `ResultPillContent.body` and `.resultCompact`). Swap colors/padding **inside** the existing
   structure; do not restructure the frames or remove `fixedSize` calls.
2. **Do not touch `PillState`, `PillStateBridge`, `PillWindowController`, or any `onX`
   closures / action wiring.** Pure renderer changes only.
3. **Preserve every existing `#Preview` block** and make sure they all still render. They are
   the visual regression harness for this work.
4. Keep `vfAccentBlue` semantics intact — it is the deliberate "reversible per-recording
   choice" accent (recovery Generate, mode-switch). It is *not* the generic primary.

## Step 1 — Add tokens

In `Colors.swift`, add:

```swift
/// Hover fill for quiet pill controls (secondary buttons, the dismiss "x"
/// circle). Replaces the literal Color(red: 0.28, green: 0.28, blue: 0.30)
/// that was copy-pasted across the pill content views.
static let vfPillControlHover = Color(red: 0.28, green: 0.28, blue: 0.30)
```

In `Spacing.swift`, add a `PillMetrics` enum for the values currently inlined as bare numbers:

```swift
enum PillMetrics {
    static let contentHPad: CGFloat = VFSpacing.lg   // 16 — horizontal inset of pill content
    static let contentVPad: CGFloat = 10             // vertical inset of pill content
    static let controlHeight: CGFloat = 30           // primary + secondary button height
    static let primaryHPad: CGFloat = 16             // filled-button horizontal padding
    static let primaryVPad: CGFloat = 7              // filled-button vertical padding
    static let iconBadge: CGFloat = 30               // leading status-icon badge diameter
    static let dismissBadge: CGFloat = 26            // corner "x" badge diameter
}
```

## Step 2 — Build the shared components (`PillControls.swift`)

Create four reusable views. These replace every hand-rolled button/icon in the pill family.

### `PillPrimaryButton` — the one filled button

```swift
struct PillPrimaryButton: View {
    enum Role {
        case positive     // forward "go" action  → vfBrandAccent (white) fill, vfOnBrand text
        case warning      // error / upgrade       → vfWarningAmber fill, vfOnBrand text
        case destructive  // stop / delete         → vfDestructive fill, white text
        case reversible   // recovery / mode-switch→ vfAccentBlue fill, white text
    }
    let title: String
    var systemImage: String? = nil   // leading SF symbol, 11pt semibold, 6pt gap
    let role: Role
    let action: () -> Void
    // 13pt semibold label; padding PillMetrics.primaryHPad / primaryVPad; Capsule fill; no border.
    // Foreground: vfOnBrand for .positive/.warning (light fills); .white for .destructive/.reversible.
}
```

### `PillSecondaryButton` — the quiet text button (Cancel / Discard / Revert)

```swift
struct PillSecondaryButton: View {
    let title: String
    let action: () -> Void
    // 13pt regular; foreground vfTextSecondary → vfTextPrimary on hover;
    // gray hover capsule fill vfPillControlHover (fades in on hover, 0.15s easeInOut);
    // padding .horizontal 12 / .vertical 6; height matches PillMetrics.controlHeight.
    // NO leading icon (drops the xmark currently on the recording/processing Cancel).
}
```

### `PillDismissButton` — the corner "x"

```swift
struct PillDismissButton: View {
    let action: () -> Void
    // xmark 10pt semibold; frame dismissBadge×dismissBadge (26);
    // glyph vfTextSecondary → vfTextPrimary on hover; Circle hover fill vfPillControlHover
    // (opacity 0→1 on hover, 0.15s). This is the ResultPillContent.dismissButton spec —
    // make it canonical and replace DevResultPillContent's padding(6) variant with it.
}
```

### `PillLeadingIconBadge` — the badged status icon

```swift
struct PillLeadingIconBadge: View {
    let systemImage: String
    let tint: Color
    // SF symbol 13pt semibold, foreground tint; frame iconBadge×iconBadge (30);
    // Circle fill tint.opacity(0.20). This is the ConfirmRecovery/PaidBlock badge spec —
    // make it canonical. (Decision: ALL leading status icons get the circle badge.)
}
```

## Step 3 — Canonical semantic color map

Apply this rule everywhere. Most assignments are already correct; the changes are noted.

| Action / context | Component | Role / tint | Change from today |
|---|---|---|---|
| Stop (recording/wrappingUp) | PillPrimaryButton | `.destructive` (red) | no color change; route through component |
| Retry (error pill) | PillPrimaryButton | `.warning` (amber) | drop the fixed 92×30 pair, use standard padding |
| Upgrade / Generate (paid-block) | PillPrimaryButton | `.warning` (amber) | route through component |
| Generate (recovery) | PillPrimaryButton | `.reversible` (blue) | keep blue; route through component |
| Confirm (anchors) | PillPrimaryButton | `.positive` (white) | **was a gray ghost capsule → now filled** |
| Retry (dev failed) | PillPrimaryButton | `.positive` (white) | **was a gray ghost capsule → now filled** |
| Copy / Retry (result + failure card) | PillPrimaryButton | `.positive` (white) | route through component (already `vfBrandAccent`) |
| Cancel / Discard / Revert (all) | PillSecondaryButton | — | unify: gray hover capsule, no icon |
| Undo (dev result) | PillSecondaryButton | — | was a ghost capsule → quiet secondary |
| Convert ("Write agent prompt") | keep as the existing outlined ghost | — | leave as-is (intentionally distinct affordance) |
| Corner "x" (every dismiss) | PillDismissButton | — | unify; replace dev variant |
| Leading status icon (every state) | PillLeadingIconBadge | amber=error/warning/paid-block; blue=recovery; green=success/result-check; amber=anchors | **wrap the currently-bare icons (error pill, confirmAnchors, devFailed) in the badge** |

Notes:
- "Light fill" buttons (`.positive` white, `.warning` amber) take **`vfOnBrand`** text (near-black),
  not pure `.black` — standardize the amber Retry/Upgrade from `Color.black` to `vfOnBrand`.
- The result-compact check and the `ArtifactCardView` header check should both use the 30pt
  green `PillLeadingIconBadge` so the success indicator matches the warning badges' weight.
  (Today they're a bare 14pt glyph and a smaller 0.18-opacity badge respectively.)

## Step 4 — Per-view refactor checklist (in `PillView.swift` unless noted)

- [ ] `RecordingPillContent` — `stopButton` → `PillPrimaryButton(.destructive)`; `cancelButton` → `PillSecondaryButton`. Keep the pulsing dot, timer, and waveform untouched.
- [ ] `ProcessingPillContent` — `cancelButton` → `PillSecondaryButton`. Keep spinner + label split logic.
- [ ] `ErrorPillContent` — add a `PillLeadingIconBadge("exclamationmark.triangle.fill", tint: .vfWarningAmber)`; Cancel → `PillSecondaryButton`; Retry → `PillPrimaryButton(.warning)`. Remove the `actionButtonWidth/Height` 92×30 equal-pair sizing.
- [ ] `PaidBlockResumePillContent` — keep badge (already correct, via component); Discard → `PillSecondaryButton`; primary → `PillPrimaryButton(.warning)` with `vfOnBrand` text.
- [ ] `ConfirmRecoveryPillContent` — badge via component; Discard → `PillSecondaryButton`; Generate → `PillPrimaryButton(.reversible)`.
- [ ] `ConfirmAnchorsPillContent` — wrap the `scope` glyph in `PillLeadingIconBadge(tint: .vfWarningAmber)`; Cancel → `PillSecondaryButton`; Confirm → `PillPrimaryButton(.positive)`.
- [ ] `DevResultPillContent` (devFailed) — badge the `exclamationmark.triangle.fill`; Revert → `PillSecondaryButton`; Retry → `PillPrimaryButton(.positive)`; dismiss → `PillDismissButton`.
- [ ] `DevResultSummaryPill` — check → green `PillLeadingIconBadge`; dismiss → `PillDismissButton`; keep the View toggle.
- [ ] `ResultPillContent` — compact check → green `PillLeadingIconBadge`; dismiss → `PillDismissButton`; keep `expandToggle` (it's a tertiary toggle, leave as the chevron text button).
- [ ] `ArtifactCardView.swift` — header check → green `PillLeadingIconBadge`; `retryButton`/`copyButton` → `PillPrimaryButton(.positive)`; `undoButton` → `PillSecondaryButton`; failure-config retry → `PillPrimaryButton(.warning)`; dismiss → `PillDismissButton`; leave the `conversionButton` ghost as-is.
- [ ] Delete the now-unused literal `Color(red: 0.28, green: 0.28, blue: 0.30)` occurrences (replaced by `vfPillControlHover` inside the components).

## Step 5 — Verify

1. `cd apps/desktop && xcodebuild -scheme Zerro build` — must compile clean.
2. Run the pill-related tests: `PillFailureCardBridgeTests`, `PaywallCopyTests`,
   `MenuBarBillingActionTests` (and the full `ZerroTests` suite if quick). No behavior should change.
3. Open each `#Preview` in `PillView.swift` (Recording, Wrapping up, Processing, Result compact/
   expanded/snippet/chat-only/no-narration/convert, Error short/long/retryable, Paid block
   Upgrade/Generate, Failure expanded, Dev result expanded/compact) and confirm:
   - every primary button matches its semantic role color and `vfOnBrand`/white text,
   - every Cancel/Discard/Revert is the same quiet secondary with the gray hover capsule,
   - every leading status icon is a 30pt tinted circle badge,
   - every corner "x" is the 26pt circle dismiss,
   - no capsule changed width/height and nothing truncates or overflows.
4. Sanity-check the four error/warning states against the reference screenshots Colin provided
   (error short/long/retryable, paid-block upgrade) — same layout, now with badged icons and
   the standardized amber primary.

## Out of scope

State logic, bridge/controller wiring, copy text, the Convert ghost button's style, capsule
geometry, and anything outside `Surfaces/Pill/` + the two DesignSystem token files.
