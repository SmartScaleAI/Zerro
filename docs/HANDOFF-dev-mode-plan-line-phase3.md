# Claude Code handoff — Phase 3: the "Step N of M" plan line (all 3 agents)

## Goal
Surface the agent's own to-do/plan as a live pill line — e.g. **"[2/5] Adding auth
middleware…"** — so the user sees the roadmap advancing, not just tool-by-tool
churn. All three agents emit a plan list; map each to one shared model and render
it through the existing substatus path. This is the "best UX" item from the
original research.

## Base
Branch from `claude/codex-json-status` (tip `2d58b22` — Phases 1 + 2) in a NEW
worktree. Phase 3 builds on the enriched `DevRunSubstatus` and the three parsers
(`event(forTool:)`, `cursorToolCallEvent`, `codexItemEvent`).

## Design — keep it on the existing last-event-wins path (low risk)
Phases 1–2 emit one `DevAgentEvent` per agent message → `DevRunSubstatus` → pill
(latest wins). Do the SAME for the plan: when a to-do update arrives, emit a
`.plan` event. It shows "[2/5] …" right then; the next tool event shows
"Editing Foo.swift…". The plan checkpoints and the live tool actions **interleave
naturally** — the user gets both the roadmap and the live motion, with no new
precedence logic, no persistent state, no pill-layout change.

(Optional future enhancement — NOT this phase: pin the step persistently by
storing it in `AppState` and composing "Step 2/5" as a stable prefix. If you ever
do that, see the **timeSeparator caveat** below — the composed label must not use
`" · "`.)

## All three plan schemas (each emits the FULL list every update — no deltas)
- **Claude Code** — `TodoWrite` tool. `input.todos[]` of
  `{content, status, activeForm}`; `status` ∈ `pending`/`in_progress`/`completed`.
  Current step = the `in_progress` item; its `activeForm` ("Adding auth
  middleware") is the ideal title (fall back to `content`).
  ```
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[
    {"content":"Add auth middleware","status":"in_progress","activeForm":"Adding auth middleware"},
    {"content":"Wire routes","status":"pending","activeForm":"Wiring routes"}]}}]}}
  ```
- **Cursor** — `todoToolCall` / `updateTodosToolCall`. `args.todos[]` of
  `{content, status}`; `status` ∈ `TODO_STATUS_PENDING`/`_IN_PROGRESS`/
  `_COMPLETED`/`_CANCELLED`. Current = the `_IN_PROGRESS` item; title = `content`.
  Emitted on the `started` twin (we already emit Cursor tools on `started`).
- **Codex** — `todo_list` item (currently parsed to nil). `item.items[]` of
  `{text, completed}` (a bool — NO explicit in_progress). Current = the FIRST item
  with `completed == false`; title = `text`. Emitted on `item.started`/
  `item.updated`/`item.completed`; `item.updated` is the primary signal.
  ```
  {"type":"item.updated","item":{"id":"item_8","type":"todo_list","items":[
    {"text":"Scan docs","completed":true},{"text":"Write code","completed":false}]}}
  ```

## Unified model + step/total derivation
Add `struct DevRunPlan: Equatable, Sendable { let step: Int; let total: Int; let title: String }`.

Normalize each agent's list to `[(title: String, done: Bool, current: Bool)]`,
then a shared helper computes the plan:
- `total` = number of steps (for Cursor, exclude `_CANCELLED`).
- current index = the explicitly-current item (Claude/Cursor `in_progress`) ELSE
  the first not-done item (Codex always; Claude/Cursor before anything starts).
- `step` = current index + 1 (1-based), clamped so `step ≤ total`.
- `title` = current item's title.
- **All items done, or list empty → return nil** (the plan is finished/absent;
  let `.done` / tool events take the line). Never emit "[6/5]".

## Pill rendering — mind the timeSeparator
The dev pill label is `"<phrase> · <elapsed>"` and `ProcessingPillContent` splits
on `" \u{00B7} "` (space-middot-space) to pin the timer (`PillView.swift` ~959).
**The plan label must NOT contain `" · "`** or the timer split breaks. Use bracket
+ colon form:
- `DevRunSubstatus.planStep(step:total:title:)` → label:
  `title.isEmpty ? "Step \(step) of \(total)…" : "[\(step)/\(total)] \(capped(title))…"`
  (reuse the existing `capped(_:max:40)` helper; the trailing `…` is the truncation
  marker, same as Phase 1).

## Implementation (App-only, Swift) — `DevAgentRunner.swift` unless noted
1. **Model + substatus + Kind**
   - Add `DevRunPlan` (above).
   - `DevRunSubstatus` (53–60): add `case planStep(step: Int, total: Int, title: String)`
     + its `label` (above).
   - `DevAgentEvent.Kind` (97–108): add `case plan(DevRunPlan)` (associated value;
     `Kind` stays `Equatable`/`Sendable` since `DevRunPlan` is both).
   - `DevAgentEvent.substatus` (127–141): `case .plan(let p): return .planStep(step: p.step, total: p.total, title: p.title)`.
   - Add a shared `planFrom(_ items: [(title: String, done: Bool, current: Bool)]) -> DevRunPlan?`.
2. **Claude** — `event(forTool:)` (1366–1389): add
   `case "TodoWrite":` → read `input["todos"]`, map each to
   `(activeForm ?? content, status=="completed", status=="in_progress")`, then
   `planFrom(...)` → `.plan` (or nil → `.working`/skip).
3. **Cursor** — `cursorToolCallEvent` (996–1030): before the generic `default`,
   add `if lower.contains("todo")` → read `args["todos"]`, map each to
   `(content, status=="TODO_STATUS_COMPLETED", status=="TODO_STATUS_IN_PROGRESS")`,
   dropping `_CANCELLED`, then `planFrom(...)`.
4. **Codex** — `codexItemEvent` (1174–1205): change the `todo_list` case from nil
   to: read `item["items"]`, map each to `(text, completed==true, false)` (no
   in_progress flag — `planFrom` falls back to first-not-done), then `planFrom(...)`.
   Emit on `item.started`/`item.updated`/`item.completed` (idempotent; last wins).
5. **Privacy:** to-do text is ON-SCREEN ONLY — never analytics (same invariant as
   Phases 1–2). Do not add it to any event/log payload.

## Tests (`DevAgentRunnerTests.swift`)
- Claude `TodoWrite` (in_progress item) → `.plan(step:2,total:5,title:"Adding auth middleware")` (uses `activeForm`).
- Cursor `todoToolCall` with an `_IN_PROGRESS` item → correct step/total; a
  `_CANCELLED` item is excluded from `total`.
- Codex `todo_list` (first incomplete) → step = completed+1, title = its `text`;
  `item.updated` and `item.completed` both parse.
- All-complete list → nil; empty list → nil; `step` never exceeds `total`.
- Label: `planStep(2,5,"Adding auth middleware")` → `"[2/5] Adding auth middleware…"`;
  empty title → `"Step 2 of 5…"`; long title capped; **label contains no `" · "`**.
- Keep `-parallel-testing-enabled NO`.

## Acceptance
- `xcodebuild build-for-testing` succeeds; new + existing tests pass serially.
- Live: a task that uses a plan (e.g. "make a multi-step change") shows
  "[1/4] …" → "[2/4] …" advancing, interleaved with the Phase 1/2 tool lines —
  no longer a single static phrase. (Codex live needs the Jul 17 quota reset or a
  non-capped account, same as Phase 2.)
- Invariants intact: to-do text never reaches analytics; stall/cancel machinery
  untouched (only an explicit user action terminates the process).

## Anchor cheatsheet (lines from the codex-json-phase2 worktree; will shift a bit
off a fresh branch — match by content)
- `DevAgentRunner.swift`: `DevRunSubstatus` 53–84 (`capped` 82); `DevAgentEvent.Kind`
  97–108; `substatus` 127–141; `cursorToolCallEvent` 996–1030; `codexItemEvent`
  1174–1205 (`todo_list` ~1199); `event(forTool:)` 1366–1389.
- (Enhancement-B only) `AppState.swift` `devRunSubstatus` 591 + handler 3196–3198;
  `PillStateBridge.swift` `devProgressLabel` 162; `PillView.swift`
  `ProcessingPillContent` timeSeparator `" · "` ~959.

## Sources (schemas)
- Claude Code TodoWrite (todos[] content/status/activeForm): https://docs.claude.com/en/docs/agent-sdk/todo-tracking
- Cursor stream-json todo tool calls (TODO_STATUS_*): https://tarq.net/posts/cursor-agent-stream-format/
- Codex `todo_list` item (items[] text/completed): https://takopi.dev/reference/runners/codex/exec-json-cheatsheet/
