# Claude Code handoff — Review-before-apply (Phase 4)

An **opt-in** mode: when on, a Dev Mode recording generates its prompt and then
**pauses to show you that prompt before dispatching** — Approve sends it to the
agent, Cancel aborts with nothing touched. Off by default (the auto-apply "talk →
watch it change" magic is preserved); cautious users turn it on to see exactly
what will be sent before any file changes.

The clean build: this is the **same gate shape as the existing `confirmAnchors`
step** — it suspends the dispatch and waits for the user. Mirror that gate/state/
pill rather than inventing a new mechanism. App-only (Swift), build + tests, then
a manual check.

## The insertion point (already perfect for this)
`AppState.beginDevDispatch()` (~2800) dispatches behind a `confirmGate` closure
(~2874) that runs **after the checkpoint, before the agent**, returning true →
dispatch / false → abort (on false the coordinator discards the checkpoint —
nothing was edited). Today it's just `awaitAnchorConfirmation`. Compose the review
gate in **after** it:
```swift
confirmGate: { [weak self] in
    guard await self?.awaitAnchorConfirmation(gen: gen) ?? false else { return false }
    return await self?.awaitReviewApproval(gen: gen) ?? false
}
```
Order matters: anchors first (resolve any ambiguous element), THEN review (approve
the final prompt — which already reflects the confirmed anchor). Either gate
returning false aborts cleanly with the checkpoint discarded — no new teardown.

## Read first
- `AppState.swift`: `beginDevDispatch` (~2800) + the `confirmGate` (~2874); the
  gate to mirror — `awaitAnchorConfirmation(gen:)` (~2974), `confirmAnchorsAndProceed`
  (~2989), `declineAnchors` (~3012); the `.confirmAnchors` state (~88); the
  dispatched prompt is `parsedResponse?.artifact.body` (~2804/2850); the resolved
  target labels are `devConfirmAnchorSummaries`; and the teardown's
  `resolvePendingAnchorConfirmation(false)` (the continuation-cancel to mirror).
- `PillStateBridge.swift` (~123, the `.confirmAnchors` → pill-state mapping).
- `Surfaces/Pill/PillWindowController.swift` (~344, `onConfirmAnchors`/
  `onDeclineAnchors` wiring) and the confirmAnchors pill content in `PillView.swift`
  (the card to mirror) + `ArtifactCardView` (its monospace prompt-body rendering to
  reuse for showing the prompt text).
- `Preferences/PreferencesStore.swift` (`Keys`, ~42–62) and the App Behavior
  settings section (where the existing behavior toggles like redact-secrets live).

## Part 1 — the setting (default OFF)
`PreferencesStore`: add `Keys.devReviewBeforeApply` (`vf.dev.reviewBeforeApply`),
`Bool` **defaulting to false**, in `resettable`. Surface it as a labeled toggle —
**"Review prompt before applying changes"** — in App Behavior settings (it's a
behavior preference, not agent/model/project-specific). *(Placement call: Settings
keeps the dev-settings menu uncluttered; if you'd rather it sit in the dev-settings
menu next to Auto-Detect for consistency, that's a trivial move — flag for the
product owner.)*

## Part 2 — the review gate
Add `awaitReviewApproval(gen: Int) async -> Bool`, mirroring `awaitAnchorConfirmation`:
- `guard preferences.devReviewBeforeApply else { return true }` — off ⇒ instant pass
  (byte-identical to today).
- else stash the generation token, set `state = .reviewingPrompt`, store the prompt
  text (`artifact.body`) + the target labels (`devConfirmAnchorSummaries`) for the
  card, and SUSPEND on a `CheckedContinuation<Bool, Never>` (a
  `pendingReviewContinuation`), exactly like the anchor gate.
- `gen`-guard the resume (a superseded/reset recording must not dispatch).
- `approveReviewAndProceed()` → resume(true); `cancelReview()` → resume(false).
  Both no-op outside `.reviewingPrompt` / when the continuation is already cleared
  (double-tap safe), mirroring `confirmAnchorsAndProceed`/`declineAnchors`.

## Part 3 — teardown safety (mirror the anchor gate)
Wherever the anchor continuation is force-resolved on teardown
(`resolvePendingAnchorConfirmation(false)` in the reset/cancel/quit paths), also
resolve the review continuation false, and add a `prepareForTermination` arm so a
quit at `.reviewingPrompt` aborts cleanly (agent never ran → discard the checkpoint,
same as the `.confirmAnchors` quit branch). The review gate must never be able to
hang the dispatch.

## Part 4 — the review state + pill
- Add `case reviewingPrompt` to `RecordingState`; audit the exhaustive `switch`es
  (the `prepareForTermination` arm above; treat it like `.confirmAnchors` in
  sweep/idle guards — NOT idle, recovery/etc. no-op while it's shown).
- A review pill/card (clone the confirmAnchors pill): a header naming the target
  agent ("Send to Claude Code?"), the **resolved target label(s)** ("Targeting: the
  'Get started' button") from `devConfirmAnchorSummaries`, and the **prompt body**
  in the monospace well (reuse `ArtifactCardView`'s prompt rendering, scroll/cap for
  a long prompt). Two buttons: **Approve** (green `vfSuccessGreen`/`vfDevAccent`) →
  `approveReviewAndProceed()`; **Cancel** (red `vfDestructive`) → `cancelReview()`.
- `PillStateBridge`: map `.reviewingPrompt` → a `.reviewPrompt(agent:targets:prompt:)`
  pill state. `PillWindowController`: wire `onApproveReview`/`onCancelReview`.

## Scope (v1): Approve / Cancel only — NOT edit
Show-and-approve, no in-pill editing. Editing the prompt is out of scope: the
dispatched `body` is captured before the gate runs (~2850), so editing would need
the edited text plumbed past the gate into the coordinator — a separate change.
Note it as a future extension; don't build it now. (Same for an agent "plan"
preview — future, agent-specific.)

## Part 5 — tests
- Gate: with the pref OFF, `awaitReviewApproval` returns true without entering
  `.reviewingPrompt` (no behavior change — assert the dispatch path is unchanged).
  With it ON, it enters `.reviewingPrompt`; `approveReviewAndProceed()` →
  dispatch proceeds; `cancelReview()` → aborts, checkpoint discarded, no agent run.
- Composition: both gates ON (low-confidence anchor + review) → confirmAnchors
  resolves first, then reviewingPrompt; approving both dispatches; cancelling
  either aborts.
- Teardown: a reset/quit while `.reviewingPrompt` resolves the continuation false
  (no hang) and discards the checkpoint.
- Pref defaults false + persists + resettable.

## Part 6 — manual check
With the toggle ON: record a Dev change → after generation the review card shows the
prompt + target + agent. **Approve** → the agent runs and edits (the normal dev
tail follows). **Cancel** → nothing changes, working tree clean, back to idle. With
the toggle OFF → auto-dispatch exactly as today (no card). Try the ambiguous-anchor
case with review on → confirmAnchors card, then the review card.

## Acceptance criteria
- With the setting ON, every Dev dispatch pauses on a review card showing the exact
  prompt (+ target + agent) before any file change; Approve dispatches, Cancel
  aborts with the working tree untouched and the checkpoint discarded.
- With the setting OFF (default), behavior is byte-identical to today — no card, no
  extra state, the auto-apply path unchanged.
- The gate composes after `confirmAnchors`; neither gate can hang the dispatch
  (teardown resolves both); build + tests green; normal/artifact mode unaffected.

## Notes
- This leans entirely on the proven confirmAnchors machinery (gate + continuation +
  state + pill + teardown-resolve) — it should be a close clone, not new plumbing.
- Default-off keeps the headline "talk → watch it change" experience intact; review
  is the opt-in for users who want a look first. The strong undo model (cancel /
  in-session undo / cross-launch undo) is the safety net; this is about control.
