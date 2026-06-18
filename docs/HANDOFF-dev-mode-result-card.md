# Claude Code handoff — Dev Mode result card (UI)

Make the Dev Mode **success** state (`.devDone`) render as an expandable card that
reuses `ArtifactCardView`, instead of the compact "N files changed · Revert · Done"
capsule. Target, per the product owner:

- **Compact pill** (collapsed): a one-line summary; expands like the artifact result.
- **Expanded card**, top → bottom:
  1. **Human-readable summary** of what changed (where the artifact card shows its
     chat text / title) — natural language describing the edits.
  2. **Body well = a readable git diff** (the monospace code block that normally
     holds the agent_prompt/snippet) — the actual per-file diff hunks since the
     checkpoint.
  3. **Footer button = "Undo"** (in the Copy button's slot) → reverts to the
     checkpoint (`onDevRevert`). No Copy button.
  4. **X at top-right** (`dismissButton`) closes the card and **keeps** the changes
     (the existing `onDismissResult`). This replaces the "Done" button.
- **No Retry** on the success card.

Out of scope: `.devFailed` stays as-is (Revert + Retry). Managed path is unaffected
(same pill). Normal-mode artifact result card unchanged.

## Read first
- `Surfaces/Pill/ArtifactCardView.swift` — the expandable card. Note `FailureConfig`,
  which already swaps the footer Copy→Retry and is the exact pattern to follow for a
  new dev-result config (summary header + diff body + Undo footer + X dismiss).
- `Surfaces/Pill/PillView.swift` — `.devDone` currently builds `DevResultPillContent`
  with Revert/Done (lines ~364–373).
- `Services/Dev/DevAgentRunner.swift` — `parseStreamJSONLine` already handles the
  `result` event; capture its summary text here.
- `Services/Dev/DevDispatchCoordinator.swift` — `Success` carries checkpoint/service/diff.
- `Services/Dev/GitCheckpoint.swift` — `diffStat(since:)` exists; add a diff-text method.
- `AppState.swift` — `.devDone` construction + `devCheckpoint`/`devDiffStat` storage.

## Ground rules
- Gated behind a Dev Mode recording; normal mode + the normal artifact card stay
  byte-identical. Build + test after each part. Adversarial-review the teardown
  paths if you touch them (you shouldn't need to — Undo reuses `onDevRevert`).

## Part A — capture the agent's summary text
`Services/Dev/DevAgentRunner.swift`: the stream-json `result` event carries the
agent's final message (`obj["result"]` string). Capture it and thread it out via
`DevRunResult.succeeded(summary: String?)`. Fallback when absent/empty: nil (the UI
falls back to a generated line — Part C). Keep parsing defensive.

## Part B — produce the readable diff
`Services/Dev/GitCheckpoint.swift`: add `diff(since checkpoint:) throws -> String`
returning the unified diff (`git diff <restoreRef>` over the worktree). **Cap it**
(e.g. ~400 lines / ~24KB) with a trailing "… (truncated, N more lines)" note so a
huge diff can't bloat the pill. Run off-main like `diffStat`. The coordinator's
`Success` gains `summary: String?` (from Part A) and `diffText: String`.

## Part C — the UI
1. `AppState`: on `.devDone`, store the summary + diff text (alongside the existing
   `devDiffStat`). The summary shown = the agent's text (Part A) if present, else a
   generated fallback: e.g. "Updated N files (+x −y)." from `devDiffStat`.
2. `ArtifactCardView`: add a `DevResultConfig` (mirror `FailureConfig`):
   - header title + the **human summary** in the text region;
   - **body well = the diff text**, monospace (reuse the snippet/monospace branch);
   - footer single button **"Undo"** in the Copy slot → its action;
   - the existing **X dismiss** kept (keeps changes); collapse/expand kept.
   Success-only chrome not wanted here (Copy capsule, convert affordance, charge
   line) is suppressed under this config, exactly as `FailureConfig` suppresses it.
3. `PillView`: route `.devDone` to render the `ArtifactCardView` dev-result config
   (compact pill = the summary line; expanded = the full card). Wire `Undo`→`onDevRevert`,
   `X`→`onDismissResult`. Drop the Revert/Done `DevResultPillContent` for `.devDone`.
   (`.devFailed` keeps its current content.)

## Acceptance
- A completed Dev Mode run shows a compact summary pill that **expands** to: the
  human-readable summary on top, the **readable diff** in the code block, an **Undo**
  button at the bottom, and an **X** to close (keeping the changes). No Retry, no Done.
- **Undo** restores the working tree to the checkpoint (reuses the verified
  `onDevRevert`/`GitCheckpointService.revert`); **X** dismisses and keeps the changes.
- Agent-summary fallback works when the `result` event has no text.
- Diff is capped for large changes; `.devFailed`, normal mode, and the normal
  artifact card are unchanged. Tests + a quick manual check on a real run.
