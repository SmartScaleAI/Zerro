# Task: Let pill warning/error messages fully expand instead of truncating

## Problem
In the macOS app, warning/error toasts shown in the pill get cut off with an
ellipsis. For example the trial-credits warning —

> "You've used all your free trial credits — subscribe or add your own API keys to keep going."

— renders as "You've used all your free trial credits — subscribe or add your own API keys to kee…" because the toast text is capped at two lines. The user can't read the full message.

## Desired behavior
- **All** pill warning/error messages (everything rendered by `ErrorPillContent`) should display their **full text** — never truncated.
- The pill must keep the **same locked width (392px)** and grow with **dynamic height**, exactly like the successful response view already does. Do **not** widen the pill or add a click/hover-to-expand interaction — the text should simply always be shown in full, wrapping to as many lines as it needs.

## Where the code lives
All in `apps/desktop/Zerro/Surfaces/Pill/PillView.swift`:

- `ErrorPillContent` (struct starting ~line 319) renders the message. Line ~343 has the offending `.lineLimit(2)` on `Text(message)`. The text already uses `.multilineTextAlignment(.leading)` and `.fixedSize(horizontal: false, vertical: true)`.
- The pill sizing already supports this: `lockedCapsuleWidth` (~line 172) returns the fixed `capsuleWidth` (392) for `.error`, and `lockedCapsuleHeight` (~line 181) returns `nil` for `.error` so height is content-driven. `capsuleWidth = 392`, `capsuleHeight = 50` (~line 196–197).

The message strings themselves are defined in `apps/desktop/Zerro/AppState.swift` (e.g. `trialCreditsExhausted` at ~line 275) — **do not change the copy**, only the rendering.

## Implementation
1. In `ErrorPillContent`, remove the `.lineLimit(2)` constraint on the message `Text` so it wraps to its full height. Keep `.multilineTextAlignment(.leading)` and `.fixedSize(horizontal: false, vertical: true)`.
2. Confirm `ErrorPillContent` still floors its height at the 50pt `capsuleHeight` so short messages keep rendering as the familiar single-line capsule (there is an existing comment around line 188–190 describing this floor — verify the implementation still holds after the change; if the floor lived implicitly in the 2-line cap, add an explicit `.frame(minHeight: PillView.capsuleHeight)` so a one-word message doesn't shrink the pill).
3. Make sure the amber warning icon and the Retry/Dismiss controls stay vertically aligned sensibly with multi-line text — top-align the `HStack` (e.g. `HStack(alignment: .top, ...)`) if the icon/buttons look off-center once the text grows tall. Use your judgment to keep it visually clean.
4. Update the explanatory comments near the `.lineLimit(2)` and the `lockedCapsuleHeight` `.error` case to reflect that the message now wraps fully rather than capping at two lines.

## Verification
- Build the app (`xcodebuild` or open `apps/desktop/Zerro.xcodeproj` and build the `Zerro` scheme) and confirm it compiles.
- Use the SwiftUI previews in `PillView.swift` (or add one) to render `ErrorPillContent` with:
  - the long trial-credits string (`AppState.swift:275`) — confirm it shows in full, wrapping to multiple lines, at 392px width.
  - a short error string — confirm the pill still renders at the ~50pt single-line height.
- Visually confirm the pill width stays 392px and only the height changes.
- Run the existing test target (`ZerroTests`) to make sure nothing regresses.

## Constraints
- Touch only what's needed for this fix; don't refactor unrelated pill states.
- Don't change any user-facing message copy.
