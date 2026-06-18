# Handoff — Convert error pills to the title + detail card layout

## Goal

Today the `.error` state renders a compact capsule that puts the whole failure
*sentence* on one line and wraps it awkwardly when it's long (the "Error · Long"
and "Error · Retryable" screenshots), and `.paidBlockResume` renders a single line
that overflows off the right edge ("Paid block · Upgrade/Generate"). The
`.failureExpanded` state already renders the layout we want: an amber caution badge,
a short bold **headline** ("Generation failed"), the explanation as wrapped prose
**below** it, and an action button in the footer.

Make **every error-family pill use that card layout** so the text never has to wrap
inside a small capsule. Specifically: `.error` and `.paidBlockResume` should render
the same 760-wide failure card as `.failureExpanded`, each with a short per-reason
title on top and the existing sentence as the detail below.

Decisions already made:
- **Titles:** add a short per-case `headline` to `RecordingFailureReason` (table below).
- **Scope:** convert **both** `.error` and `.paidBlockResume`. Short errors get the card too — all error pills look identical.
- **Width:** match `.failureExpanded` exactly (**760pt**, 18pt corner radius).

## Constraints

1. **State logic and action wiring stay the same.** Only the *associated values* of
   `.error` / `.paidBlockResume` change (to carry headline + detail) and the *rendering*
   changes. The `onRetryError` / `onErrorRetryRegion` / `onResumePaidGeneration` /
   `onDismissError` closures keep their current behavior and call sites.
2. **Reuse the existing card** (`ArtifactCardView` failure configuration) — do not build a
   new card from scratch. This is the "one design system" goal: error, paid-block, and
   generation-failure all render through the same card.
3. Use the shared controls already in `PillControls.swift` (`PillPrimaryButton`,
   `PillSecondaryButton`, `PillLeadingIconBadge`, `PillDismissButton`) for the footer.
4. Compile clean and keep every `#Preview` working — they're the visual regression harness.

## Step 1 — Add `headline` to `RecordingFailureReason`

In `apps/desktop/Zerro/AppState.swift`, directly after the `var userMessage: String`
computed property (ends ~line 329), add a `var headline: String` with an **exhaustive**
switch (one arm per case — the compiler enforces it). The `userMessage` stays exactly as
is and becomes the card's *detail*. Suggested copy (Colin can tweak any string):

| Case | `headline` |
|---|---|
| screenRecordingRevoked | "Screen Recording off" |
| microphoneRevoked | "Microphone off" |
| microphoneUnavailable | "Microphone unavailable" |
| audioSetupFailed | "Microphone problem" |
| microphoneDisconnected | "Microphone disconnected" |
| streamStartFailed | "Couldn't start capture" |
| writerStartFailed | "Couldn't start recording" |
| captureInterrupted | "Recording interrupted" |
| displayUnavailable | "Display unavailable" |
| displayChanged | "Display changed" |
| processingFailed | "Processing failed" |
| recordingTooShort | "Recording too short" |
| diskFull | "Storage full" |
| apiKeyMissing | "API key needed" |
| apiAuth | "API key rejected" |
| networkOffline | "Connection problem" |
| rateLimited | "Rate limited" |
| providerError | "Generation failed" |
| providerUnavailable | "Service unavailable" |
| responseTooLong | "Response too long" |
| artifactUnreadable | "Couldn't read result" |
| outOfCredits | "Out of credits" |
| subscriptionInactive | "Subscription inactive" |
| trialVerificationRequired | "Verify your email" |
| trialCreditsExhausted | "Free trial used up" |

Use the same `\u{2019}`/`\u{2014}` escapes the file already uses for apostrophes/dashes.

## Step 2 — Widen the `.error` and `.paidBlockResume` associated values

In `apps/desktop/Zerro/Surfaces/Pill/PillView.swift` (the `PillState` enum, ~line 41 and
~line 50), change the two cases to carry the headline + detail instead of a single message:

```swift
case error(headline: String, detail: String, retryable: Bool)
case paidBlockResume(headline: String, detail: String, entitled: Bool)
```

Update the doc comments accordingly (they currently describe a single `message`).

## Step 3 — Generalize the card's failure config to carry footer buttons

In `apps/desktop/Zerro/Surfaces/Pill/ArtifactCardView.swift`, the `FailureConfig` today is
`{ headline, detail }` and the footer hardcodes a single amber Retry (`retryButton`, ~line
297) plus the header dismiss X. Extend it so the same card can render the error pill's
**Cancel + Retry** pair and the paid-block's **Discard + Upgrade/Generate** pair:

```swift
struct FailureConfig {
    let headline: String
    let detail: String
    /// Quiet left button (Cancel / Discard). nil → no secondary (the
    /// .failureExpanded card keeps its header-X-only treatment).
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil
    /// Filled right button. Defaults to the existing amber Retry.
    var primaryTitle: String = "Retry"
    var primaryIcon: String? = "arrow.clockwise"
    var primaryRole: PillPrimaryButton.Role = .warning
}
```

- Rename/repoint the footer so when `failure != nil` it renders:
  `if let secondaryTitle, let onSecondary { PillSecondaryButton(title: secondaryTitle, action: onSecondary) }`
  then `PillPrimaryButton(title: primaryTitle, systemImage: primaryIcon, role: primaryRole, action: onRetry)`.
  (`onRetry` is the existing primary-action closure — reuse it as the single primary action.)
- **Header X:** show the dismiss X only when `secondaryTitle == nil` (i.e. keep it for
  `.failureExpanded`, drop it for error/paid-block where the Cancel/Discard button already
  dismisses). In `header` (~line 164) gate `PillDismissButton` on that condition.

This keeps `.failureExpanded` pixel-identical (it passes no secondary, default Retry).

## Step 4 — Render `.error` and `.paidBlockResume` as the card in `PillView`

In `PillView.swift`:

**4a. `content` switch** — replace the two cases (~line 343 and ~line 350). Mirror the
existing `.failureExpanded` block (~line 357: `ArtifactCardView(...).frame(width: 760)
.fixedSize(horizontal: false, vertical: true).clipShape(RoundedRectangle(cornerRadius: 18 …))`).

```swift
case .error(let headline, let detail, let retryable):
    ArtifactCardView(
        artifact: nil, chatText: "", chargeLine: nil,
        noNarration: false, stoppedBySleep: false, conversion: .hidden,
        onCopy: {}, onCollapse: {}, onDismiss: onDismissError, onConvert: {},
        failure: ArtifactCardView.FailureConfig(
            headline: headline,
            detail: detail,
            secondaryTitle: "Cancel",
            onSecondary: onDismissError,
            primaryTitle: "Retry",
            primaryIcon: "arrow.clockwise",
            primaryRole: .warning
        ),
        onRetry: retryable ? onRetryError : onErrorRetryRegion
    )
    .frame(width: 760)
    .fixedSize(horizontal: false, vertical: true)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

case .paidBlockResume(let headline, let detail, let entitled):
    ArtifactCardView(
        artifact: nil, chatText: "", chargeLine: nil,
        noNarration: false, stoppedBySleep: false, conversion: .hidden,
        onCopy: {}, onCollapse: {}, onDismiss: onDismissError, onConvert: {},
        failure: ArtifactCardView.FailureConfig(
            headline: headline,
            detail: detail,
            secondaryTitle: "Discard",
            onSecondary: onDismissError,
            primaryTitle: entitled ? "Generate" : "Upgrade",
            primaryIcon: nil,
            primaryRole: .warning
        ),
        onRetry: onResumePaidGeneration   // primary action; label set above
    )
    .frame(width: 760)
    .fixedSize(horizontal: false, vertical: true)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
```

**4b. Sizing switches** — these states are now content-driven 760 cards, not locked capsules:
- `lockedCapsuleWidth` (~line 248): move `.error` out of the `return Self.capsuleWidth`
  arm and into the `return nil` arm (alongside `.failureExpanded`). `.paidBlockResume` is
  already in the `nil` arm — leave it.
- `lockedCapsuleHeight` (~line 258): move `.paidBlockResume` out of the
  `return Self.capsuleHeight` arm into the `return nil` arm. `.error` is already `nil` —
  leave it.
- `cornerRadius` (~line 447): add `.error` and `.paidBlockResume` to the `case … : return 18`
  group with `.failureExpanded` (they're cards now, not 28pt capsules).

**4c. Delete the now-dead views:** `ErrorPillContent` (~line 659) and
`PaidBlockResumePillContent`. Confirm nothing else references them.

## Step 5 — Update the bridge

In `apps/desktop/Zerro/PillStateBridge.swift`:
- Line ~86: `.paidBlockResume(headline: reason.headline, detail: reason.userMessage, entitled: …)`.
- Line ~91: `.error(headline: reason.headline, detail: reason.userMessage, retryable: false)`.
- Search the file for every other `.error(` / `.paidBlockResume(` constructor (there may be
  a retryable `.error(…, retryable: true)` site) and give each the new arguments.
- Optional but recommended for consistency: line ~74 currently hardcodes
  `headline: "Generation failed"` for `.failureExpanded` — change it to `reason.headline`
  so the retryable expanded card also gets the specific title.

## Step 6 — Update any other destructuring sites

Grep the whole `apps/desktop` tree for `case .error(` and `case .paidBlockResume(` and
update each binding to the 3-tuple. Known sites beyond the bridge/PillView:
- `PillWindowController.swift` — check whether it pattern-matches these states when binding
  closures; update the bindings if so.
- `ZerroTests/PillFailureCardBridgeTests.swift` lines ~72, ~88, ~104 — these destructure
  `.error(let message, …)` / `.paidBlockResume(let message, …)`. Update to
  `.error(let headline, let detail, let retryable)` etc. and assert on `detail ==
  reason.userMessage` and `headline == reason.headline` (e.g. for the trial-credits case,
  detail is the long sentence, headline is "Free trial used up").

## Step 7 — Update the previews

In `PillView.swift`, the `#Preview` blocks at lines ~1286, ~1297, ~1307 (`.error`) and
~1318, ~1329 (`.paidBlockResume`) pass `message:`. Update them to `headline:` + `detail:`.
Pull realistic pairs from the reason table, e.g.:

```swift
#Preview("Error · Short") {
    PillView(state: .error(
        headline: "Recording interrupted",
        detail: RecordingFailureReason.captureInterrupted.userMessage,
        retryable: false
    )).padding(40).background(Color.vfPanelBackground)
}

#Preview("Error · Long") {
    PillView(state: .error(
        headline: RecordingFailureReason.trialCreditsExhausted.headline,
        detail: RecordingFailureReason.trialCreditsExhausted.userMessage,
        retryable: false
    )).padding(40).background(Color.vfPanelBackground)
}
```

Do the same for the retryable and paid-block previews (Upgrade = entitled false,
Generate = entitled true).

## Step 8 — Verify

1. `cd apps/desktop && xcodebuild -scheme Zerro build` — clean compile (the enum change
   will surface every un-updated site as an error; fix them all).
2. Run `ZerroTests` (at minimum `PillFailureCardBridgeTests`, `PaywallCopyTests`,
   `MenuBarBillingActionTests`).
3. Open each affected `#Preview` and confirm:
   - title sits on top in bold, the sentence wraps as prose **below** it, never inside a
     one-line capsule,
   - error card shows **Cancel + Retry**, paid-block shows **Discard + Upgrade/Generate**,
     no redundant header X on either,
   - `.failureExpanded` is unchanged (Retry + header X),
   - all three card types are the same 760-wide / 18pt-radius chrome.

## Out of scope

The recording/processing/result/recovery/dev-mode states, the copy of `userMessage`,
billing/entitlement logic, and the `onRetry`/`onResume` behaviors. Pure presentation +
the headline data plumbing only.
