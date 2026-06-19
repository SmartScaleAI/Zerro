# Claude Code handoff — agent transparency + stall prompt (Phase 4)

Two coupled changes to the Dev Mode dispatch:
1. **Show every event the agent emits** — replace the single-line running status
   with a **live, scrolling activity feed** (each tool call / read / run / search /
   thought / result as its own line, with its specifics).
2. **Replace the hard timeouts with a non-destructive stall check-in** — drop the
   5-min wall-clock and 60s inactivity kills; instead, if **3 minutes pass with no
   new event**, show a pill asking whether to keep waiting — **without ever killing
   the process**. Any new event auto-dismisses it.

This is a big, staged change. Build **Parts 1–2 (runner/parser)** → STOP for review
→ **Parts 3–5 (state/UI)**. App-only (Swift).

## THE critical invariant (do not violate)
**The agent process is terminated ONLY by an explicit user action — the "Kill the
process" button, the existing Cancel, or app quit. NOTHING else kills it.** The new
stall timer only *notifies*; the process keeps running underneath the prompt. If
you find any path where a timer/deadline calls `cancel()`, it's wrong.

## Behavior spec (the source of truth)
- The pill, while the agent runs, shows a **live feed of every event** (newest at
  the bottom, auto-scrolling).
- A **3-minute stall timer** resets on *any* output from the agent. If it elapses
  with no new event → show a **stall prompt** (process still running):
  professional copy, e.g. **"No activity from the agent for 3 minutes — it may be
  hung. Last step: `Running npm install`. Keep waiting?"** with two buttons:
  **Continue** and **Kill the process**.
- **Continue** → dismiss the prompt, re-arm the 3-min timer, back to the feed. (The
  process was never touched.)
- **Kill the process** → terminate the agent (SIGTERM→SIGKILL), then **show the
  result card** with the diff of whatever it changed so far + **Undo / Accept** (NO
  auto-revert — the user decides). Reuses the normal `.devDone` card.
- **A new event arrives while the prompt is up** → **immediately dismiss the
  prompt**, append the event, resume the feed, reset the timer. (If that event is
  the terminal `result`, it naturally transitions to the result card.)

## Read first
- `Services/Dev/DevAgentRunner.swift`: `DevRunTimeouts` (~90, `wallClock:300,
  inactivity:60`) + `TimeoutKind` (~64) + `startTimeoutTimer()` (~380, the 0.5s
  `DispatchSourceTimer` that checks the caps and fires `cancel()`) + `lastActivity`
  (~290) + `cancel()` (~240, the ONLY terminator) + `onSubstatus` (the emit path) +
  `parseStreamJSONLine`/`substatus(forTool:input:)`/`cursorToolCallSubstatus` (the
  event→substatus mappers that currently *discard* read/run detail) +
  `DevRunSubstatus` (~44).
- `AppState.swift`: `applyDevPhase` (the `.running(substatus)` handler →
  `devRunSubstatus`), `applyDevOutcome`/the `.devDone` result-card path,
  `cancelDevDispatchSafely` (terminate + revert — reuse its terminate, NOT its
  revert, for Kill), the dispatch `Task` in `beginDevDispatch` (~2851).
- `Surfaces/Pill/PillView.swift` + `PillStateBridge.swift` +
  `PillWindowController.swift`: the `.devAgentRunning` pill (today one substatus
  line) and the `confirmAnchors`/review pills (the two-button prompt pattern to
  clone for the stall prompt).

## Part 1 — runner: timer becomes a stall NOTIFIER, never a killer
- **Delete the wall-clock cap entirely.** Remove `wallClock` from `DevRunTimeouts`
  and its check.
- **Repurpose the inactivity check:** the 0.5s timer still tracks `lastActivity`
  (reset on *any* process output — see Part 2), but on exceeding the threshold it
  **emits a stall signal instead of calling `cancel()`**. Add a dedicated callback
  `onStall: @Sendable (Bool) -> Void` (true = stalled, false = resumed): fire
  `true` once when the threshold is crossed; fire `false` on the next output after
  a stall. **The timer must never terminate the process.**
- Threshold = a named constant, default **180s** (injectable for tests).
- `cancel()` stays exactly as-is — the sole SIGTERM→SIGKILL path, called only by
  the user (Kill/Cancel) or quit. Remove the `.timeout` failure reason (or keep the
  enum case unused) — a stall no longer fails the run.
- Update the file header comment (it documents the two old caps).

## Part 2 — emit EVERY meaningful event (with its specifics)
- Expand the emitted type from the 4 coarse `DevRunSubstatus` cases to a
  per-event **`DevAgentEvent`** (or enrich `DevRunSubstatus`) carrying `{ kind,
  detail, timestamp }` — e.g. `editing("Button.tsx")`, `reading("package.json")`,
  `searching("useState")`, `listing("src/")`, `running("npm install")`,
  `thinking`, `message(text)`, `toolResult(...)`, `done`.
- The detail is ALREADY in the event payloads — `substatus(forTool:input:)` and
  `cursorToolCallSubstatus` read `input["file_path"]` / `args["path"]` etc. and
  currently throw away everything but the edit path. Capture the path/command/
  pattern for **all** tool kinds (`Read`/`Glob`/`Grep`/`LS`/`Bash` for Claude;
  `read`/`shell`/etc. for Cursor). Emit one event per agent message.
- **Reset the stall timer on ANY process output** (any stdout/stderr line),
  including frames you don't render — they're signs of life. **Display** only events
  with renderable content; skip purely-empty/structural frames (noise, not
  transparency).
- **Codex** (`.text`): emit each output line as a `message`/raw event (no structured
  tool data — coarser, but still live and still resets the timer).
- **Privacy:** the detail (file names, commands) renders ON SCREEN only — it must
  NEVER go to analytics. Keep the existing "metadata only — no paths/content"
  telemetry discipline intact.

## Part 3 — AppState: activity log + the (non-terminating) stall state
- `devActivityLog: [DevAgentEvent]` — append per emitted event, **capped** to the
  last ~200 (bound memory; the feed shows a scrollable window).
- A `.agentStalled` `RecordingState` (or a flag layered on `.devAgentRunning`).
  **Entering it does NOT stop the agent.** Store the last action for the prompt copy.
- `onStall(true)` → enter `.agentStalled` (show prompt). `onStall(false)` OR any new
  event while stalled → leave `.agentStalled`, back to the running feed.
- `continueWaiting()` → leave `.agentStalled`, re-arm the runner's stall timer (or
  it just keeps running — the point is another 3-min window before re-prompting),
  process untouched.
- `killStalledAgent()` → Part 4.
- Auto-dismiss is the same code path as `onStall(false)`: any appended event clears
  the stalled state.

## Part 4 — Kill → terminate, keep edits, show the result card
`killStalledAgent()`:
- Terminate via the runner's `cancel()` (reuse `cancelDevDispatchSafely`'s
  terminate mechanism) **but do NOT revert.**
- Compute the checkpoint→current diff (the existing `GitCheckpointService.diff/
  diffStat` the result card already uses) and route to the **`.devDone` result
  card** — the diff body + **Undo** (reverts to checkpoint) + **Accept** (keeps).
  Optionally flavor the header "Stopped — N changes so far," but reuse the card.
- The checkpoint + quit-recovery marker behave as for a normal completion (the
  user can Undo; a quit while the card is up is recoverable).

## Part 5 — pill UI
- **Running feed:** replace the single substatus line with a scrolling feed —
  one styled line per `devActivityLog` entry (icon + text: "Editing Button.tsx",
  "Running `npm install`", "Read package.json", "Searching 'useState'",
  "Thinking…"), newest at the bottom, auto-scroll, fixed max height, `.clipped()`.
  Keep the existing Cancel affordance.
- **Stall prompt:** a pill state cloning the confirmAnchors/review two-button card —
  the message (naming the last action) + **Continue** (neutral) / **Kill the
  process** (red `vfDestructive` — this one *does* terminate). Write professional,
  calm copy (not alarmist). Bridge `.agentStalled` →
  `.agentStalled(lastAction:)`; wire `onContinueWaiting`/`onKillProcess`.
- **Auto-dismiss:** when an event lands while the prompt is shown, the state leaves
  `.agentStalled` (Part 3) and the pill returns to the feed with no user action.

## Part 6 — teardown / quit
- `.agentStalled` folds into the running-agent arms: Cancel → `cancelDevDispatchSafely`
  (terminate + revert); quit → terminate + recovery marker (same as
  `.devAgentRunning`); reset/supersede → terminate + clean up. The stall prompt must
  never block or hang teardown.
- Invalidate the stall timer on every terminate/teardown path.

## Part 7 — tests + manual
- Runner: stall timer resets on output; fires `onStall(true)` after the threshold of
  silence and **does NOT terminate** (assert the process is still alive / cancel was
  not called); a subsequent output fires `onStall(false)`; `cancel()` is the only
  terminator; wall-clock is gone.
- Parser: every tool kind yields an event with its captured detail; Codex lines
  become events; the stall timer resets on non-displayed frames.
- AppState: events append (capped); `onStall(true)`→`.agentStalled` without stopping
  the dispatch; a new event auto-clears the stall; `continueWaiting` re-arms; 
  `killStalledAgent` terminates + shows the result card (diff + Undo/Accept), NO
  auto-revert.
- Manual: run a long task → watch the live feed; induce a stall (a sleeping/looping
  command in allow-commands, or just wait) → the prompt appears, **the agent is
  still running**; let an event land → prompt auto-dismisses; Continue → re-arms;
  Kill → result card with the partial diff, Undo/Accept both work.

## Acceptance criteria
- The running pill shows a live, scrolling feed of every meaningful agent event with
  its specifics; telemetry stays metadata-only.
- No wall-clock or inactivity *kill* exists; the only termination is explicit user
  action / quit. A 3-min silence shows the stall prompt with the agent still running.
- Continue re-arms and keeps running; a new event auto-dismisses the prompt; Kill
  terminates and shows the diff with Undo/Accept (no auto-revert).
- Teardown/quit never hang on the stall state; build + tests green; normal/artifact
  mode unaffected.

## Notes
- Long *legitimate* silence (a big build, a long thinking pass) will trip the
  prompt — that's expected and harmless (process keeps running, user clicks
  Continue). It's the accepted cost of having no hard kill.
- Tradeoff being chosen deliberately: a truly-dead-but-alive process can linger
  until the user returns and Kills it (or quits). That's the product owner's call.
- Feed performance: events are message-level (not per-token, since we don't pass
  `--include-partial-messages`), so the rate is modest; the ~200 cap + clipped
  scroll view keeps it cheap.
