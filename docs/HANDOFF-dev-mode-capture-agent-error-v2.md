# Claude Code handoff — capture agent errors DYNAMICALLY across all three CLIs

The first error-capture PR (`HANDOFF-dev-mode-capture-agent-error.md`, now merged)
only reliably surfaces a detailed error for **Claude Code**. We support **Claude
Code, Codex, and Cursor**, and each reports failures *differently*. This handoff
makes the capture correct and dynamic for all three, grounded in each CLI's
**verified** output contract (sources at the bottom).

App-only (Swift), no UI. This is purely the error-**content** capture; the
expanded-card **layout** is the separate handoff.

## Why the current code is Claude-Code-only (the bug)
The merged `parseResultError` reads the agent's error from the terminal stream-json
`result` event. But that event only carries the error for **one** of our three CLIs:

| CLI | Zerro `outputFormat` (`DevAgentRegistry`) | Where a FATAL error actually goes | Captured today? |
|-----|-------------------------------------------|-----------------------------------|-----------------|
| **Claude Code** | `.streamJSON` | terminal `result` event: `is_error:true`; text in **`error`** (the `result` string is usually `""` on error) + a structured `permission_denials[]` | partial — gets `error`, **misses** `permission_denials` |
| **Cursor** | `.streamJSON` | **stderr** — *"the stream may end early without a terminal event; an error message is written to stderr"* (Cursor docs). So there is **often NO `result` event at all** | only via the `stderrTail` fallback |
| **Codex** | `.text` (we deliberately don't parse Codex JSON) | plain **text lines** on stdout and/or **stderr** | **neither** — the `.text` branch keeps no "last line", so a stdout-printed error is dropped; only stderr survives |

So: Claude Code mostly works (modulo `permission_denials`), Cursor leans entirely on
stderr, and Codex can silently lose a stdout-printed error. The fix is to capture
the **best available detail per output format**, not assume the `result` event.

## The change

### A. Claude Code — also read `permission_denials` — `DevAgentRunner.swift`
Edits-only is our default posture (`--disallowedTools Bash` / sandbox), so the
**most common** Claude Code failure is a denied shell command. Its `result` event
looks like (verified, takopi cheatsheet / SDK):
```json
{"type":"result","subtype":"error","is_error":true,"result":"",
 "error":"Permission denied",
 "permission_denials":[{"tool_name":"Bash","tool_use_id":"…",
   "tool_input":{"command":"git fetch origin main"}}]}
```
`error` alone ("Permission denied") is true but useless — the actionable detail is
*which command*. In `parseResultError`, after the existing `result`→`error`→
`message`→`subtype` scan, before returning, enrich when `permission_denials` is a
non-empty array: append the denied tool + command, e.g.
`"Permission denied — Bash: git fetch origin main"`. Keep it defensive (array of
dicts; `tool_name` String; `tool_input.command` String — any miss → fall back to the
plain `error`). One line per denial, cap at the first 3 so the pill stays sane.

### B. Cursor — make the stderr path first-class — `DevAgentRunner.swift`
Cursor emits **no `result` event on failure** (docs, verbatim above), so
`resultError` is correctly nil for it and the `stderrTail` fallback is the ONLY
detail. That fallback already exists (good) — but two robustness fixes:

1. **Cursor can also emit a top-level `error` *event*** mid-stream
   (`{"type":"error", ...}` / `{"type":"system","subtype":"api_retry"...}` per its
   event union). In `parseStreamJSONLine` these currently parse to nil (skipped). Add
   a capture (NOT a render): if a line is `type=="error"`, stash its `message`/`error`
   string into `resultError` (last one wins) so a stream that dies after an error
   event still has detail even if stderr was empty. Do this in `processStreamLine`
   alongside the `.done` handling — a small `parseStreamErrorEvent(line)` sibling.
2. Confirm `stderrTail` survives a stream that "ends early": it does (stderr is
   drained independently in `ingestStderr`), but add a test (below) so a Cursor-shaped
   failure — non-zero exit, stderr text, no `result` event — surfaces the stderr text.

### C. Codex — keep the last meaningful text line for the failure detail — `DevAgentRunner.swift`
Codex runs as `.text` in Zerro, so `processStreamLine`'s `.text` branch
(~578) is the only stdout parser. It emits each line as a `.message` event but keeps
nothing for the failure detail. Codex prints its fatal error as a normal text line
(and/or stderr). Add a `lastTextLine` capture in the `.text` branch:
```swift
case .text:
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lastTextLine = trimmed          // remember for the failure detail
    emit(DevAgentEvent(kind: .message, detail: trimmed))
```
Then in `handleTermination`'s non-zero branch, extend the fallback chain so text-format
agents prefer their last printed line over (or alongside) stderr.

### D. One unified, format-aware fallback — `DevAgentRunner.swift`
Replace the current `resultError ?? stderrTail` with an explicit, documented chain in
`handleTermination` (non-zero branch). Order = most-specific-wins:
```
detail =
   resultError                       // A+B: stream-json error (Claude result / Cursor error event)
   ?? nonEmpty(stderrTail)           // Cursor & Codex fatal errors, Claude rare
   ?? lastTextLine                   // C: Codex error printed to stdout
   // else nil → DevDispatchFailure.userMessage floors to the generic line
```
(Trim each; treat empty as nil. `nonEmpty` helper already exists in this file.)
The associated value stays named `stderrTail` (renaming ripples into
`DevDispatchFailure` + tests — out of scope); it's now "best available detail" and
`DevDispatchCoordinator.userMessage` already shows whatever non-empty string it gets.
**No change in `DevDispatchCoordinator.swift`.**

> Design note: order matters. stderr is preferred over `lastTextLine` because a
> non-zero Codex exit with real stderr is a truer error than the last chatty stdout
> line; `lastTextLine` is the floor before the generic message. If you'd rather a
> Codex run prefer its own stdout summary, flip C and stderr — flag it to the product
> owner, don't guess. (Recommended: stderr first, as above.)

## Out of scope (flag to product owner)
- **Friendly remaps** (e.g. Cursor Free-plan `ActionRequiredError` →
  "This model needs a paid Cursor plan — switch to Auto") sit ON TOP of this capture.
  Ship truthful raw text first.
- **Parsing Codex JSON** (`codex exec --json`: `turn.failed.error.message` /
  top-level `error.message`) would give Codex structured errors like the others, but
  Zerro intentionally runs Codex as `.text` today (registry comment). Switching Codex
  to JSON is a bigger change (new parser branch) — note it, don't do it here. The
  `lastTextLine` capture is the pragmatic fix within the current `.text` contract.

## Privacy / telemetry
Unchanged and important: the captured detail rides ONLY into `userMessage` (logged
`.private`). The analytics site (`AppState.swift` ~3288) matches `.nonZeroExit`
**without binding the associated value** — keep it that way so no error string (which
can echo file contents / repo paths / denied commands) reaches analytics.

## Tests (add to `DevAgentRunnerTests.swift`)
Parser units:
- **Claude Code permission denial**: a `result` event with `is_error:true`,
  `error:"Permission denied"`, and a `permission_denials` array → detail includes the
  denied command (`"…Bash: git fetch origin main"`), not just "Permission denied".
- **Claude Code** plain error (`error`/`message`/`subtype` variants) → unchanged from v1.
- **Cursor error event**: `{"type":"error","message":"…"}` mid-stream → captured into
  `resultError`.
- `parseResultError` still returns nil for `subtype:"success"` and non-result lines.

End-to-end (spawn a script, like the existing `makeScript` tests):
- **Cursor-shaped failure**: stream-json agent prints some events, writes an error to
  **stderr**, emits **no `result` event**, exits non-zero → `userMessage` is the
  stderr text, not the generic line.
- **Codex-shaped failure**: a `.text`-format agent prints a final error line to
  **stdout**, empty stderr, exits non-zero → `userMessage` is that last line.
- **Codex-shaped failure via stderr**: `.text` agent, error on stderr → stderr wins
  (documents the ordering in D).
- **Graceful floor**: non-zero exit, no result error, no stderr, no text line →
  generic "The agent exited with an error."

## Acceptance criteria
- A failed run shows the agent's real error for **all three** CLIs:
  Claude Code (incl. the denied-command detail), Cursor (stderr / error event),
  Codex (last stdout line or stderr) — falling back to the generic line only when
  genuinely nothing is available.
- No analytics payload carries the raw error string.
- Build + tests green; success paths + result-card summary unchanged.

## Sources (verified June 2026)
- **Claude Code** stream-json `result` error shape (`is_error`, `error`,
  `permission_denials`): Claude stream-json cheatsheet (takopi.dev) + Agent SDK
  `ResultMessage` (`subtype: success | error_during_execution | error_max_turns`).
- **Cursor** failure = stderr, no result event; `error` event type; `result`/
  `tool_call` shapes: Cursor docs — Output format & Headless CLI (cursor.com/docs).
- **Codex** `exec --json` `turn.failed.error.message` / `error.message`, and that
  Zerro runs Codex as `.text`: Codex exec-json cheatsheet (takopi.dev) +
  `DevAgentRegistry.makeCodex` (`outputFormat: .text`).
