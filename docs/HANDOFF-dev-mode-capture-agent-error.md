# Claude Code handoff — capture the agent's real error text on a failed dev run

When a Dev Mode run fails, the pill shows the generic **"The agent exited with an
error."** instead of *what actually went wrong* (e.g. `ActionRequiredError: Named
models unavailable. Free plans can only use Auto.`). The real error text **is** in
the agent's output — we just throw it away on the failure path. Capture it and
thread it through to the pill so the user sees a detailed reason.

App-only (Swift), no UI work. This is the **content** fix; the **layout** fix
(expanded scrollable failure card) is the separate
`HANDOFF-dev-mode-expanded-error-pills.md` — they're complementary: layout makes a
long message readable, this makes there *be* a real message. Ship both.

## Root cause
The agents we run in `stream-json` mode (Claude Code, cursor-agent) report their
fatal error in the **terminal `result` event on stdout**, *not* on stderr. But:

- `DevAgentProcessExecution.ingestStderr` (`DevAgentRunner.swift` ~568) only fills
  `stderrTail` — which is empty for these agents on a clean-process / error-result
  exit.
- `processStreamLine` (~549) captures the `result` event's text into `resultSummary`
  **only to ride out on `.succeeded`**. On a non-zero exit that text is never read.
- `handleTermination` (~578) builds `.nonZeroExit(code:, stderrTail:)` from
  `stderrTail` alone.
- `DevDispatchFailure.userMessage` (`DevDispatchCoordinator.swift` ~79) then does:
  ```swift
  case .nonZeroExit(_, let tail):
      return tail.isEmpty ? "The agent exited with an error." : tail
  ```
  `tail` is empty → the generic string. **That's the bug.**

So the detailed reason is already streaming past us — we just don't keep it on
failure.

## The change (runner: capture the result-event error, thread it through)

### 1. Capture the result event's error text — `DevAgentRunner.swift`
Today only the **success** text is parsed (`parseResultSummary`, ~742), and it
returns nil for an error result (the Claude Code error subtype omits the top-level
`result` string). Add a parser that pulls the **error** text from a terminal
`result` event, defensively, across agents:

- Add a sibling to `parseResultSummary`, e.g.
  `static func parseResultError(_ line: String) -> String?`, that:
  - parses the line, requires `type == "result"`;
  - treats it as an error when `is_error == true` **or** `subtype` is anything other
    than `"success"` (Claude Code uses `success` / `error_max_turns` /
    `error_during_execution`; cursor-agent/Codex vary — don't hard-code one);
  - returns the **first non-empty string** it finds among the likely fields, in
    order: `result`, `error`, `message`, `subtype`. (Belt-and-suspenders: agents
    differ on which field carries the human text. `subtype` is the last resort so we
    at least surface `error_max_turns` rather than nothing.)
  - trims, returns nil if empty. Reuse the existing trimming helpers; **do not** run
    `summaryDroppingQuestions` here — that's a success-summary nicety, errors should
    be shown verbatim.

- Add a field next to `resultSummary` (~385):
  ```swift
  /// The agent's error text, captured from a terminal stream-json `result` event
  /// whose subtype/`is_error` marks a failure. Rides out on `.nonZeroExit` so the
  /// pill shows the real reason instead of the generic fallback. nil until/unless
  /// such an event is seen.
  nonisolated(unsafe) private var resultError: String?
  ```

- In `processStreamLine` (~549, the `case .streamJSON` branch), alongside the
  existing `if case .done = event.kind … resultSummary = …`, also capture the error:
  ```swift
  if case .done = event.kind {
      if let summary = DevAgentProcessExecution.parseResultSummary(line) {
          resultSummary = summary
      }
      if let errText = DevAgentProcessExecution.parseResultError(line) {
          resultError = errText
      }
  }
  ```
  (Keep it tolerant — a `result` event can legitimately yield neither.)

### 2. Prefer the captured error in the failure — `DevAgentRunner.swift`
In `handleTermination` (~588), the non-zero branch currently passes `stderrTail`
only. Prefer the richer text, fall back to stderr:
```swift
} else {
    let detail = resultError
        ?? { let t = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
             return t.isEmpty ? nil : t }()
    finish(.failed(.nonZeroExit(code: status, stderrTail: detail ?? "")))
}
```
Keep the associated value named `stderrTail` (it's now "best available detail";
renaming it ripples through `DevDispatchFailure` + tests — out of scope). The
`userMessage` switch already does the right thing with whatever non-empty string it
gets, so **no change needed in `DevDispatchCoordinator.swift`** — its
`tail.isEmpty ? generic : tail` now lands on the real reason.

### 3. (Optional, same PR) text-format agents — Codex
For `outputFormat == .text` (Codex, ~561) there's no `result` event; the error, if
any, is in stderr, which `stderrTail` already carries — so those keep working via
the fallback. No change required, but note it in the report so the reviewer knows
it's intentional.

## Out of scope but adjacent (flag to product owner)
This surfaces the **raw** agent error. The specific
`ActionRequiredError: Named models unavailable. Free plans can only use Auto.` is
cursor-agent's raw text on a Free plan; turning it into a friendly line
("This model needs a paid Cursor plan — switch to Auto, or pick a different agent.")
is the **Cursor Free-plan backstop** (a separate error-string remap layer that sits
on top of this capture). Do the capture first so users see *something true*; remap
the common ones after. Don't block this PR on it.

## Privacy / telemetry
- `userMessage` is already logged `.private` in device logs — fine, leave it.
- **Do not** forward the captured `resultError` string to analytics. The M8
  `files_changed`/failure-code analytics stay **coarse** (the failure *category*,
  not the message) — an agent error string can echo file contents / repo paths. Only
  the in-app pill shows the full text.

## Tests
- `parseResultError` returns the error text for a Claude Code error result
  (`{"type":"result","subtype":"error_during_execution","is_error":true,"result":"…"}`
  and the variant where the text is under `error`/`message`); returns nil for a
  `subtype:"success"` result and for non-result lines.
- A run that exits non-zero **after** emitting an error `result` event resolves to
  `.nonZeroExit` whose detail is the **result-event text**, not empty — assert the
  generic "The agent exited with an error." is NOT what `userMessage` returns.
- stderr-only failure (no result event) still surfaces `stderrTail` (fallback path
  intact).
- A non-zero exit with neither result-event error nor stderr still yields the
  generic message (graceful floor).

## Acceptance criteria
- A failed dev run shows the agent's **actual** error in the pill (verified with the
  `Named models unavailable` case end-to-end), falling back to stderr, then to the
  generic line only when nothing else exists.
- No analytics payload carries the raw error string.
- Build + tests green; success path + result-card summary unchanged.
