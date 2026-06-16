# Task: Make the "Error · Long" pill preview reference the real message string

## Context
In a recent change, the `#Preview("Error · Long")` in
`apps/desktop/Zerro/Surfaces/Pill/PillView.swift` was updated to exercise the
longest production warning (the trial-credits-exhausted copy). It currently
**hardcodes a duplicate copy** of that string as a literal:

```swift
#Preview("Error \u{00B7} Long") {
    PillView(state: .error(
        message: "You\u{2019}ve used all your free trial credits \u{2014} subscribe or add your own API keys to keep going.",
        retryable: false
    ))
        .padding(40)
}
```

The problem: this literal is a copy of the real string. The source of truth lives
in `apps/desktop/Zerro/AppState.swift` — `RecordingFailureReason.userMessage`
(the enum is `public enum RecordingFailureReason` at ~line 64; `userMessage` is a
computed `var` at ~line 226; the `.trialCreditsExhausted` case returns this exact
copy at ~line 275). If the copy ever changes, the preview silently drifts.

## Fix
In the `#Preview("Error · Long")` block in `PillView.swift`, replace the
hardcoded `message:` literal with a reference to the source of truth:

```swift
message: RecordingFailureReason.trialCreditsExhausted.userMessage
```

`RecordingFailureReason` is public and `userMessage` is module-internal, so it is
accessible from `PillView.swift` (same `Zerro` module) — no visibility changes
needed. Update the preview's comment to note it pulls the real string from
`RecordingFailureReason.trialCreditsExhausted.userMessage` rather than duplicating it.

## Constraints
- Only touch this one preview. Do not change the message copy in `AppState.swift`,
  the `ErrorPillContent` rendering, or any other preview.
- If `RecordingFailureReason.userMessage` turns out NOT to be reachable from the
  preview (e.g. an access-level issue surfaces at build time), do not widen its
  access just for a preview — instead report back and leave the literal in place.

## Verification
- Build the `Zerro` scheme (`xcodebuild` or Xcode) → must compile.
- Confirm the "Error · Long" SwiftUI preview still renders the full trial-credits
  message wrapping to multiple lines at the locked 392px width.
