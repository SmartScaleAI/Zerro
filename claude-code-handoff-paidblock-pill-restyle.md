# Task: Restyle the paid-block (trial-exhausted) pill like the sleep-recovery pill, with a dynamic Upgrade→Generate button

## Goal
When generation is blocked for a PAID reason and a held recording exists (the
`canResumePaidGeneration` case added in M5), render the failure pill in the same
visual style as the sleep-recovery confirmation pill — a circular badge icon, the
message, a plain "Discard" button, and a filled primary button — but **amber**
instead of blue. The primary button is **Upgrade** (opens the purchase window)
until the user is entitled, then flips to **Generate** (resumes the held recording).

This replaces the current plain `ErrorPillContent` + "Continue" treatment for the
paid-block resumable case ONLY. All other failures keep the existing
`ErrorPillContent`.

## Visual reference (mirror this, in amber)
`ConfirmRecoveryPillContent` in `apps/desktop/Zerro/Surfaces/Pill/PillView.swift`
(~line 661) is the exact layout to copy:
- `HStack(spacing: VFSpacing.md)` → `iconBadge` + message `Text` + `Spacer(minLength:)` + discard button + primary button.
- `iconBadge`: an SF Symbol in a 30×30 circle filled with the accent color at 0.20 opacity.
- discard button: plain text, `Color.vfTextSecondary`, size 12.
- primary button: filled `Capsule`, white text, size 13 semibold, `.padding(.horizontal, 16).padding(.vertical, 6)`.
- container padding: `.padding(.horizontal, VFSpacing.lg).padding(.vertical, 10)`.

Differences for our version:
- Use `Color.vfWarningAmber` everywhere `ConfirmRecoveryPillContent` uses `Color.vfAccentBlue` (the badge fill/tint AND the filled button background).
- Icon: use `exclamationmark.triangle.fill` (the existing error-pill warning icon) in the amber badge.
- Message: the real paid-block copy, `reason.userMessage` (e.g. the trial-credits string). It's longer than the recovery copy — match the recovery pill's content-sized width (the `.error`/`.confirmRecovery` states are not width-locked), and let it sit on one line like the recovery pill (`.fixedSize()`); if it makes the pill uncomfortably wide, allow it to wrap to two lines instead, your call — keep it tidy.

## Behavior
- **Discard** button → `appState.dismissFailure()` (for a paid block this already
  discards the held recording: deletes the working dir + clears the pending
  pointer — verified in M5).
- **Primary button** → `appState.resumePaidGeneration()`. This method already
  refreshes entitlement and then either resumes (if `canGenerate`) or opens the
  paywall (if not), so a single action handles both cases — no new action needed.
- **Dynamic label** — drive purely off entitlement so it flips live:
  - `entitlements?.canGenerate == true` → label **"Generate"**.
  - otherwise → label **"Upgrade"**.
  The pill observes `AppState`/`EntitlementStore` (both `@Observable`), so when the
  user activates a license and entitlement flips to `.byok`/`.managed`, the label
  re-renders from "Upgrade" to "Generate" automatically. Make sure the label is
  derived from an entitlement read that happens during the bridge/view evaluation
  so Observation tracks it (see wiring note below).

## Implementation steps

### 1. New PillState case
In `PillView.swift` (`enum PillState`), add a case for this surface, e.g.:
```swift
case paidBlockResume(message: String, entitled: Bool)
```
`entitled` carries `entitlements?.canGenerate == true` so the view picks the label
without reaching back into AppState. Sizing: treat it like `.confirmRecovery` —
content-sized width (return `nil` from `lockedCapsuleWidth`/`lockedCapsuleHeight`
for this case, matching how `.confirmRecovery` is handled at ~lines 186–203).

### 2. New content view
Add `PaidBlockResumePillContent` (model it on `ConfirmRecoveryPillContent`) with:
```
let message: String
let entitled: Bool
let onPrimary: () -> Void   // resumePaidGeneration
let onDiscard: () -> Void   // dismissFailure
```
Amber badge + message + Discard + a filled amber button whose `Text` is
`entitled ? "Generate" : "Upgrade"`.

### 3. Render it
In `PillView.content` (the `switch state`), add:
```swift
case .paidBlockResume(let message, let entitled):
    PaidBlockResumePillContent(
        message: message,
        entitled: entitled,
        onPrimary: onResumePaidGeneration,
        onDiscard: onDismissError
    )
```
`onResumePaidGeneration` and `onDismissError` are already injected into `PillView`
(added in M5 / pre-existing). Reuse them — no new closures needed.

### 4. Bridge
In `PillStateBridge.swift`, the `.failed(reason)` branch currently returns
`.error(message:, retryable:, resumable: canResumePaidGeneration)`. Change it so:
- if `canResumePaidGeneration` → return
  `.paidBlockResume(message: reason.userMessage, entitled: entitlements?.canGenerate == true)`
- else → return the existing `.error(...)` (drop the now-unused `resumable` route,
  or keep `resumable: false` — see step 6).

Reading `entitlements?.canGenerate` here is what makes the label reactive.

### 5. Remove the now-dead "Continue" affordance
The M5 "Continue" button in `ErrorPillContent` (the `onContinue`/`resumable` path)
is superseded by this pill. Either:
- remove the `onContinue` parameter + the Continue button from `ErrorPillContent`
  and the `resumable` associated value from `.error`, OR
- leave `.error`'s `resumable` in place but always pass `false` now.
Prefer fully removing it (cleaner) — update `PillView.content`'s `.error` case, the
`#Preview`s, `PillWindowController` (the `onContinue` wiring, if any), and
`PillFailureCardBridgeTests` accordingly so everything compiles.

### 6. Wiring (no new closures expected)
`PillWindowController.swift` already wires
`onResumePaidGeneration: { appState.resumePaidGeneration() }` and
`onDismissError: { appState.dismissFailure() }` (M5). The new content view reuses
both, so no controller change should be needed beyond confirming they're passed
through.

### 7. Previews
Add `#Preview`s for `.paidBlockResume`: one with `entitled: false` ("Upgrade") and
one with `entitled: true` ("Generate"), using
`RecordingFailureReason.trialCreditsExhausted.userMessage`.

## Verification
- Build the `Zerro` scheme → must compile.
- Canvas-render both new previews: confirm amber badge + filled amber button, with
  the label "Upgrade" vs "Generate".
- Run `PillFailureCardBridgeTests` + `PendingPaidGenerationTests` → green (update
  the bridge test if it asserted on `.error(... resumable ...)` for a paid block;
  it should now expect `.paidBlockResume`).
- Manual: force entitlement `.expired` via the DEBUG menu-bar entitlement picker,
  trigger a paid-block pill → button reads **Upgrade** and opens the paywall on
  tap; force entitlement to `.managed`/`.byok` (simulating activation) → the same
  pill's button flips to **Generate** and resumes the held recording on tap.
  (NOTE: with the dev license key present the user computes to `.managed`, so the
  button shows "Generate" immediately — use the picker to force `.expired` to see
  the "Upgrade" state.)

## Constraints / notes
- Don't change `resumePaidGeneration()`'s logic — it already does refresh →
  resume-or-paywall. We're only changing the pill's appearance and making the
  label reactive.
- Keep `Discard` semantics exactly as `dismissFailure()` (discards the held
  recording for a paid block).
- Amber is `Color.vfWarningAmber`; blue was `Color.vfAccentBlue`. Use existing
  design-system colors only.
- This only affects the paid-block resumable failure. Transient retryable failures
  and all other errors keep `ErrorPillContent` unchanged.
