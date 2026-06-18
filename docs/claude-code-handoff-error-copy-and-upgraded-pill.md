# Handoff — Elaborate error copy + blue "upgrade complete" pill

Two changes, both building on the error-card layout that already shipped:

1. The error cards now have room, so give every `RecordingFailureReason` a richer,
   actionable **detail** message (what happened + how to fix), instead of the current
   one-line `userMessage`.
2. The `paidBlockResume` pill in its **entitled** state (shown *after* the user upgrades,
   with a held recording ready) should switch from the amber "Free trial used up" warning to
   a **blue, professional "you're all set" confirmation**.

## Constraints

- Pure copy + presentation. Don't change billing/entitlement logic, the held-recording
  flow, or any action closures (`onRetryError`, `onResumePaidGeneration`, `onDismissError`).
- The entitled pill keeps its current **Discard** button and its existing action (it still
  discards the held recording) — no behavior change, just color + copy.
- Compile clean; keep all `#Preview`s working.

---

## Part 1 — Richer error detail copy

### 1a. Add a `detail` property to `RecordingFailureReason`

In `apps/desktop/Zerro/AppState.swift`, after the existing `var headline: String` (~line
335), add `var detail: String` with an **exhaustive** switch (one arm per case). Keep
`userMessage` and `headline` as they are — `userMessage` stays the terse one-liner for any
non-card surface; `detail` is the new elaborate body the card shows.

Style: **what happened, then the fix**, 1–2 sentences, professional and calm. For the
retryable / API-stage failures the recording is still on disk, so the copy says "your
recording is saved / press Retry"; for capture-stage failures the copy says "start a new
recording." Suggested copy (Colin can tweak any string — use the file's `\u{2019}` / `\u{2014}`
escapes for apostrophes and em-dashes):

| Case | `detail` |
|---|---|
| screenRecordingRevoked | "Zerro no longer has permission to capture your screen, so the recording couldn't be made. Re-enable it under System Settings › Privacy & Security › Screen Recording, then start a new recording." |
| microphoneRevoked | "Microphone access is turned off, so your narration couldn't be captured. Turn it back on under System Settings › Privacy & Security › Microphone and record again." |
| microphoneUnavailable | "The microphone you selected isn't available right now. Choose a different input in Settings or reconnect the device, then start a new recording." |
| audioSetupFailed | "Zerro couldn't start capturing audio from your microphone. Make sure no other app is using it, then try recording again." |
| microphoneDisconnected | "Your microphone disconnected partway through, so the recording stopped early. Reconnect it — or pick another input in Settings — and record again." |
| streamStartFailed | "Zerro couldn't start screen capture. This is usually temporary — start a new recording, and if it keeps happening, restart the app." |
| writerStartFailed | "Zerro couldn't create the file to save your recording. Make sure you have free disk space, then start a new recording." |
| captureInterrupted | "Your recording was interrupted before it finished — this can happen when the app quits or your Mac goes to sleep mid-capture. Start a new recording to try again." |
| displayUnavailable | "The display you were recording is no longer connected. Reconnect it or choose another screen, then start a new recording." |
| displayChanged | "Your display setup changed while recording — a screen was added, removed, or rearranged — so capture stopped. Start a new recording on your current setup." |
| processingFailed | "Zerro couldn't turn your recording into a prompt. Press Retry to run it again; if it keeps failing, record the screen once more." |
| recordingTooShort | "Your recording was under \(Int(ProcessingConfig.minRecordingSeconds)) seconds — too short to capture enough context. Record again, narrating the change you want as you go." |
| diskFull | "Your Mac ran out of storage while saving the recording, so it couldn't finish. Free up a few gigabytes, then start a new recording." |
| apiKeyMissing | "Generating a prompt needs an API key, and none is set. Add one under Settings — an OpenAI key is required for transcription — then start a new recording." |
| apiAuth | "Your API key was rejected. Check it under Settings — it may be expired, revoked, or missing the right access — then try again." |
| networkOffline | "Zerro couldn't reach the generation service. Check your internet connection and press Retry — your recording is saved, so it'll run again without re-recording." |
| rateLimited | "The service is temporarily limiting requests. Wait a minute, then press Retry — your recording is saved and ready to run." |
| providerError | "The generation service ran into an error while creating your prompt. Your recording is saved — press Retry to run it again." |
| providerUnavailable | "The generation service is temporarily unavailable. This is usually brief — press Retry in a moment and your saved recording will run without re-recording." |
| responseTooLong | "The response grew too long to finish. Try a shorter recording, or one focused on a single change, so it can complete." |
| artifactUnreadable | "Zerro couldn't read the result that came back from the service. Press Retry to run your saved recording again." |
| outOfCredits | "You're out of credits to finish this recording. Top up from the menu bar or wait for your monthly reset — your library and this recording stay available." |
| subscriptionInactive | "Your subscription isn't active right now, so this recording can't be generated. Reactivate under Settings › Billing, then try again." |
| trialVerificationRequired | "Verify your email to unlock your free trial generations. Check your inbox for the verification link, then start a new recording." |
| trialCreditsExhausted | "You've used all your free trial generations. Subscribe, or add your own API keys under Settings, to keep generating prompts." |

> Note: `providerError` and `providerUnavailable` share a `userMessage` today but get
> distinct `detail` copy above — keep them as separate switch arms.

### 1b. Feed `detail` into the cards (bridge)

In `apps/desktop/Zerro/PillStateBridge.swift`, swap the detail source from
`reason.userMessage` to `reason.detail` everywhere a card is built:
- the `.error(headline: reason.headline, detail: reason.detail, retryable: …)` site (~line 91),
- the `.failureExpanded(headline: reason.headline, detail: reason.detail)` site (~line 73–75),
- the non-entitled `.paidBlockResume` site (see Part 2 for the entitled branch).

Leave `lastFailureDetail` (the raw underlying error string) as the override it already is —
only the generic fallback changes from `userMessage` to `detail`.

---

## Part 2 — Blue "upgrade complete" pill (entitled `paidBlockResume`)

Today both the not-entitled and entitled `paidBlockResume` render amber with the failure
copy; only the primary label flips Upgrade → Generate. Make the **entitled** state a blue
success confirmation instead.

### 2a. Add badge controls to `FailureConfig`

In `apps/desktop/Zerro/Surfaces/Pill/ArtifactCardView.swift`, extend `FailureConfig` (~line
92) so the badge tint and glyph are configurable (default to today's amber caution):

```swift
var badgeTint: Color = .vfWarningAmber
var badgeSymbol: String = "exclamationmark.triangle.fill"
```

Then in the card's `badge` view (~line 176–183), replace the hardcoded
`PillLeadingIconBadge(systemImage: "exclamationmark.triangle.fill", tint: .vfWarningAmber)`
in the `failure != nil` branch with `PillLeadingIconBadge(systemImage: failure.badgeSymbol,
tint: failure.badgeTint)`. (Leave the success-result green-check branch untouched.)

### 2b. Bridge: success copy when entitled

In `PillStateBridge.swift`, where `.paidBlockResume` is built (~line 85–89), branch on
entitlement:

```swift
if canResumePaidGeneration {
    let entitled = entitlements?.canGenerate == true
    if entitled {
        return .paidBlockResume(
            headline: "You\u{2019}re all set",
            detail: "Your subscription is active and the recording you set aside is ready to generate. Pick up right where you left off.",
            entitled: true
        )
    }
    return .paidBlockResume(
        headline: reason.headline,
        detail: reason.detail,
        entitled: false
    )
}
```

(Headline/detail copy is my recommendation — tweak freely. Keep it warm and professional;
avoid exclamation marks beyond none, no emoji.)

### 2c. PillView: theme the entitled card blue

In `PillView.swift`, the `.paidBlockResume` case (~line 388–397) currently hardcodes the
amber config. Branch its config on `entitled`:

```swift
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
            primaryRole: entitled ? .reversible : .warning,   // blue vs amber
            badgeTint: entitled ? .vfAccentBlue : .vfWarningAmber,
            badgeSymbol: entitled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        ),
        onRetry: onResumePaidGeneration
    )
    .frame(width: 760)
    .fixedSize(horizontal: false, vertical: true)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
```

Result: entitled = blue checkmark badge, blue "Generate" button, "You're all set" copy;
not-entitled = unchanged amber "Free trial used up" warning with "Upgrade".

---

## Part 3 — Previews & verify

- Update the `.paidBlockResume` previews (~line 1318, 1329) so the **Generate** one passes
  the new success `headline`/`detail`, and the **Upgrade** one keeps `reason.headline` /
  `reason.detail`. Refresh the `.error` previews to use `reason.detail` for realistic body
  length.
- `cd apps/desktop && xcodebuild -scheme Zerro build` — clean compile (the new exhaustive
  `detail` switch will error until every case is filled).
- Run `ZerroTests` (esp. `PillFailureCardBridgeTests`, `PaywallCopyTests`). If any test
  asserts on the old `userMessage` as the card detail, point it at `detail`.
- Eyeball the previews: every error card reads as title + a helpful 1–2 sentence body with a
  clear next step; the entitled paid-block card is blue with the checkmark badge, blue
  Generate, and the upgrade-complete copy; the not-entitled one is unchanged.

## Out of scope

Other pill states, `userMessage`/`headline` strings, billing logic, and the discard
behavior (stays as-is).
