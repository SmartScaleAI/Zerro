# Claude Code handoff — every error/warning pill uses the expanded layout

Error messages are getting **truncated** in the pill. The dev-dispatch failure that
prompted this showed `ActionRequiredError: Named models unavailable Free plans…`
clipped to a few words. Make **every error/warning pill render the full message in
the expanded failure-card layout** — and audit all of them for consistency, not just
the one that bit us.

App-only (Swift), UI. Small but do the full sweep.

## The pattern (already exists — make everything use it)
`Surfaces/Pill/ArtifactCardView.swift` has a `FailureConfig(headline:detail:)` that
renders the **expanded failure card**: amber caution badge, the short `headline` in
bold, and the `detail` as **wrapped, scrollable prose** (no truncation) + a footer
button row. In `PillView.swift` these states already use it correctly:
- `.error(headline:detail:retryable:)` (~41) — Cancel + Retry.
- `.paidBlockResume(headline:detail:entitled:)` (~52) — Discard + primary.
- `.failureExpanded(headline:detail:)` (~59) — the reference "scrollable prose" card.

The **outlier** is `.devFailed(detail:canRevert:)` (~87, rendered via
`DevResultPillContent` at ~502): its `detail` is treated as a **single line**, so a
long reason clips. That's the bug.

## Part 1 — route `.devFailed` through the expanded failure card
Render `.devFailed` via `ArtifactCardView` + a `FailureConfig`, exactly like
`.error`/`.failureExpanded`, instead of the compact `DevResultPillContent`:
- **headline** = a short label for the failure (derive from `DevDispatchFailure` —
  e.g. "Couldn't apply changes" / "Agent stopped"); **detail** = the **full**
  message (the agent's error text / `userMessage`), wrapped + scrollable, never
  truncated.
- Footer buttons: keep the dev-failure actions — **Revert** (when `canRevert`) +
  **Retry** — in the card's footer slots (mirror how `.error` puts Cancel + Retry
  there; `FailureConfig` already supports a footer button row).
- Always-expanded (these are errors — show them fully, like the other failure
  cards); no collapse-by-default.
- The `×` dismiss stays.

So `.devFailed` should look and behave like `.error`, just with Revert/Retry.

## Part 2 — audit EVERY error/warning pill (the real ask)
Go through all of `PillState` and confirm each state that conveys an
**error/warning/caution** uses the expanded `FailureConfig` card with the full
message — fix any that truncate or render a compact single-line variant. At minimum:
- `.error` — verify (should already be expanded).
- `.paidBlockResume` — verify.
- `.failureExpanded` — the reference; verify.
- `.devFailed` — fixed in Part 1.
- Any **recording-failure** path (the capture-interrupted / generation-failed states)
  — confirm it routes to `.error`/`.failureExpanded`, not a compact pill.
- Any **warning/caution notice** pills (e.g. the localhost-permission-denied note,
  any non-blocking caution) — if they carry a message the user must read, confirm
  it's fully shown (wrapped), not clipped.
Produce a short list in the report: each error/warning state → which layout it uses →
"full message shown? yes/no" → fix applied if no. The acceptance bar is **no error or
warning message is ever truncated in the pill**.

While you're in there: grep for `lineLimit(` / `.truncationMode(` on any
failure/error/detail text and remove/relax them so messages wrap fully (the card can
scroll for very long ones).

## Part 3 — verify the case that started this
Reproduce/trigger `.devFailed` with the long
`ActionRequiredError: Named models unavailable. Free plans can only use Auto.`
message → it now shows **in full** in the expanded card, readable, with Revert/Retry.

## Tests
- `.devFailed` renders the expanded `FailureConfig` card (headline + full detail +
  Revert/Retry), not the compact single-line content; a long `detail` is not
  truncated (assert no `lineLimit` clipping / the snapshot shows full text).
- A render/snapshot check for each error/warning state showing a long message in full.

## Acceptance criteria
- Every error/warning pill uses the expanded failure-card layout — full, wrapped,
  scrollable message, no truncation — `.devFailed` included with Revert/Retry.
- The audit list in the report covers every error/warning `PillState` and confirms
  full-message display.
- Build + tests green; success/result pills and non-error states unchanged.

## Out of scope (separate, but worth noting to the product owner)
The *text* of that specific error is the raw `ActionRequiredError` from `cursor-agent`
on a Free plan. Making it a friendly message ("This model needs a paid Cursor plan —
switch to Auto") is the **Cursor Free-plan backstop** from the Cursor handoff — a
different change (error-string remapping), still open. This handoff only fixes the
*layout* so whatever the message is, it's fully readable.
