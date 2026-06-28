# Handoff: add a Copy button to the chat-only result card

**For:** Claude Code · **Repo:** `smartscale-zerro` · **App:** `apps/desktop` (Zerro, SwiftUI/macOS)

## Goal

When a recording produces a chat-only response (an explanation with no
artifact — the card titled **"Response ready"**), the expanded result card
currently shows **no copy action**. Every artifact-bearing result shows a
Copy button. Add a Copy button to the chat-only card so users can copy the
explanation text, matching the artifact behavior.

## Decisions (already settled — do not re-litigate)

- **Button label:** `Copy` (the plain generic label — no new string needed).
- **Scope:** expanded card **only**. Do **not** add copy to the collapsed/
  compact capsule; that stays consistent with how artifacts behave today.

## Key finding: the data layer is already done

The copy payload and the click wiring already handle the chat-only case. The
**only** missing piece is rendering the button. Specifically:

- `AppState.resultCopyPayload` (`Zerro/AppState.swift`, ~line 3045) already
  returns the chat text for a chat-only response:
  ```swift
  guard let artifact = parsed.artifact else {
      return parsed.chatText.isEmpty ? generatedPrompt : parsed.chatText
  }
  ```
- `PillWindowController` (`Zerro/Surfaces/Pill/PillWindowController.swift`,
  ~line 299) already wires `onCopy` to read that payload and write the
  pasteboard — it is artifact-agnostic:
  ```swift
  onCopy: {
      guard let payload = appState.resultCopyPayload, !payload.isEmpty else { return }
      Pasteboard.copy(payload)
  },
  ```

So tapping a copy button on the chat-only card will already copy the right
text. We just need to show the button.

## The one real change

**File:** `Zerro/Surfaces/Pill/ArtifactCardView.swift`

### 1. Footer — render the copy button for chat-only too

The footer currently gates the copy button on `artifact != nil`:

```swift
private var footer: some View {
    HStack(spacing: VFSpacing.md) {
        if let chargeLine, failure == nil {
            Text(chargeLine) ...
        }
        Spacer(minLength: VFSpacing.md)
        if let failure {
            failureFooter(failure)
        } else if devResult != nil {
            undoButton
            acceptButton
        } else if artifact != nil {     // <-- chat-only falls through to nothing
            copyButton
        }
    }
}
```

Change the final branch so chat-only with copyable content also renders
`copyButton`:

```swift
} else if artifact != nil || !chatText.isEmpty {
    copyButton
}
```

Rationale for the `!chatText.isEmpty` guard (don't drop it):

- The card's `chatText` prop is set upstream in `AppState.resultPresentation`
  to `parsed.chatText.isEmpty ? (generatedPrompt ?? "") : parsed.chatText` —
  i.e. it already mirrors exactly what `resultCopyPayload` will return for the
  chat-only case. So `!chatText.isEmpty` is true precisely when there is
  something to copy, and we never show a dead button.
- `failure` and `devResult` are handled in earlier branches, so this branch is
  only reached on the success path. Chat-only = `artifact == nil`,
  `failure == nil`, `devResult == nil`.

### 2. The copy button itself already supports chat-only — verify, don't rewrite

`copyButton` and `handleCopy` already degrade correctly when `artifact` is nil;
no change needed, but confirm these read as below so the chat-only path is
clean:

- Label: `artifact?.type.buttonLabel ?? "Copy"` → renders **"Copy"** for
  chat-only. ✅ (matches the chosen label)
- Analytics: `"artifact_type": artifact?.type.rawValue ?? "chat"` → emits
  `artifact_type: "chat"` for chat-only. ✅ (no change; just note it in the PR
  so analytics owners expect a new value on the existing `artifact_copied`
  event)

## Comment / doc cleanup (the design intent changed — keep comments honest)

Several comments assert chat-only has no copy action. Update them so they don't
mislead the next reader:

1. `Zerro/Surfaces/Pill/ArtifactCardView.swift`, file header block (the
   numbered layout description, item 4 "footer"): it states *"A chat-only
   result has no footer action."* — update to note chat-only now shows the
   plain **Copy** action (charge line still on the left when managed).

2. `Zerro/Surfaces/Pill/PillView.swift`, the `ResultPillContent` doc comment
   (~lines 1038–1052) and the `headerStrip` comment (~line 1141, *"Copying and
   the credits readout live ONLY in the expanded card now"*): the "expanded
   card only" statement is still true, but the bit implying the chat-only
   expanded card renders nothing copyable should be corrected.

(These are comments only — no behavior — but this codebase keeps comments
load-bearing, so update them.)

## Tests

**File:** `apps/desktop/ZerroTests/ChatOnlyResultCardTests.swift` (existing) —
extend it.

The existing tests are `ImageRenderer` render-smoke tests (assert the card
lays out, image size > 0). Keep those. Add coverage for the new behavior at
the two seams that are actually assertable without UI automation:

1. **Payload seam (AppState):** add a test asserting
   `AppState.resultCopyPayload` returns the chat text for a chat-only response
   (and falls back to `generatedPrompt` when `parsed.chatText` is empty). This
   pins the data the button depends on. Follow the state-construction pattern
   in `ZerroTests/DevResultChargeLineTests.swift` (build an `AppState`, drive
   it to the done state, assert the computed property).

2. **Render smoke:** add a chat-only `.resultExpanded` render test that mirrors
   the existing `testChatOnlyExpandedWithChargeLineRenders` but exists to guard
   the footer-with-copy layout (so a future regression that breaks the
   chat-only footer fails here).

Optional but recommended for a crisp visibility assertion: extract the footer's
"should show copy" decision into a small internal computed property on
`ArtifactCardView`, e.g.

```swift
/// Copy is offered for any artifact result, and for a chat-only result that
/// has copyable text. Failure/dev-result footers own their own actions.
var showsCopyAction: Bool {
    failure == nil && devResult == nil && (artifact != nil || !chatText.isEmpty)
}
```

…then use `showsCopyAction` in the footer branch and unit-test it directly
(artifact present → true; chat-only with text → true; chat-only empty → false;
failure → false; devResult → false). This gives a fast, deterministic test
without rendering. Make it `internal` (not `private`) so `@testable import
Zerro` can reach it.

## Out of scope (explicitly)

- The collapsed/compact capsule (`headerStrip` in `PillView.swift`) — no copy
  button there.
- The failure and dev-result footers — unchanged.
- History rows / Recent Prompts / Menu Bar panel copy — those already have
  their own copy paths (`RecentPrompt.copyPayload`) and are unaffected.

## Verification checklist

- [ ] Build `apps/desktop` (Xcode / `xcodebuild`) — no warnings introduced.
- [ ] Run `ZerroTests` — `ChatOnlyResultCardTests` (extended) and any
      `showsCopyAction` test pass; existing artifact/dev/failure footer tests
      still pass (no regression to those branches).
- [ ] Manual: trigger a chat-only response, expand the card → **Copy** button
      shows bottom-right; tap → flips to the green **"Copied"** confirmation,
      reverts after ~1.6s; pasteboard holds the explanation text.
- [ ] Manual: an artifact response still shows its per-type label (e.g. "Copy
      Prompt", "Copy snippet") — unchanged.
- [ ] Confirm `artifact_copied` analytics fires with `artifact_type: "chat"`
      for the chat-only copy.

## Effort

Small. One functional line in `ArtifactCardView.footer` (plus the optional
`showsCopyAction` extraction), a couple of comment edits, and ~2 tests. No
new strings, no plumbing — the payload and pasteboard wiring already exist.
