# Claude Code handoff — descriptive, dynamic agent status (Codex + Cursor)

## Goal
In Dev Mode the running pill should show **specific, changing** status for ALL
three agents — like Claude Code already does ("Editing Button.tsx…", "Running
npm test…") — instead of Codex/Cursor sitting on one generic line the whole run.

## TL;DR of the problem (verified in source)
The runner **already parses rich per-event detail** into `DevAgentEvent`
(`kind` + `detail` = filename / command / pattern). The detail is then **thrown
away** at one choke point before it reaches the pill, and Codex never produces it
at all:

- **Cursor** — NOT data-starved. `parseStreamJSONLine` + `cursorToolCallEvent`
  already map its `tool_call` events to `.reading/.searching/.listing/.editing/
  .running` *with* detail. But `DevAgentEvent.substatus` collapses
  `.reading + .searching + .listing` → `.readingFiles` → the single string
  **"Exploring your codebase…"**, and drops the `detail` for everything except
  `.editing`. Reading/grepping/listing is most of a task → it looks frozen on
  "Exploring…". **This is a presentation bug, not a parsing bug.**
- **Codex** — data-starved by design. It runs `outputFormat: .text`, so every
  stdout line becomes a generic `.message` → `.working` → **"Working on your
  changes…"** forever. The old reason ("Codex `--json` differs from Claude's
  schema") is now stale: `codex exec --json` is promoted out of experimental and
  emits structured `item.*` events we can map to the same `DevAgentEvent` kinds.

## The choke point (the one thing to internalize)
`apps/desktop/Zerro/Services/Dev/DevAgentRunner.swift`

- `DevRunSubstatus` (lines 50–67): the 5-case enum + its `label` strings. Only
  `.editing` keeps detail; `.reading/.searching/.listing` all render
  "Exploring your codebase…".
- `DevAgentEvent` (lines 78–115): the RICH model — `kind` ∈ `.thinking/.reading/
  .searching/.listing/.editing/.running/.message/.toolResult/.working/.done`,
  plus `detail`. **The data we want is already here.**
- `DevAgentEvent.substatus` (lines 106–114): the lossy collapse. Note line 109
  folds reading+searching+listing into `.readingFiles`.

Render chain (where the label actually surfaces):
`emit(DevAgentEvent)` → `AppState.swift:3196–3198` (`case .running(let substatus)`
sets `devRunSubstatus`) → `PillStateBridge.swift:126`
(`devRunSubstatus?.label` → `.devProgress(label:)`) → `PillView.swift:475–476`
(`ProcessingPillContent(stepLabel: label …)`).

## Invariants — do NOT violate
1. **Privacy:** `detail` (file names, commands, patterns) is ON-SCREEN ONLY. It
   must NEVER reach analytics/telemetry. The existing "metadata only — no
   paths/content" discipline stays intact (see the comments at lines 70–72 and
   1175). Do not add `detail` to any event/log payload.
2. **Defensive parsing:** unknown shapes degrade to `.working`, never crash
   (matches the existing `cursorToolCallEvent`/`event(forTool:)` posture).
3. **Don't touch the stall/cancel machinery.** This change is status TEXT only.
   The process is still terminated only by explicit user action; the stall timer
   still resets on any output. No timer/deadline may call `cancel()`.

---

## Phase 1 — Cursor + shared UI (cheap, do first, biggest visible win)
App-only (Swift). No new parsing — just stop discarding detail.

**1a. Enrich the pill vocabulary.** In `DevAgentRunner.swift`, give the pill the
detail that's already captured. Two acceptable shapes — pick one:

- *Preferred (minimal):* expand `DevRunSubstatus` with detail-carrying cases and
  update `label`:
  - `.searching(pattern: String)` → `pattern.isEmpty ? "Searching your codebase…" : "Searching for \"\(pattern)\"…"`
  - `.listing(dir: String)` → `dir.isEmpty ? "Listing files…" : "Listing \(dir)…"`
  - `.reading(file: String)` → `file.isEmpty ? "Reading files…" : "Reading \(file)…"`
  - `.running(command: String)` → `command.isEmpty ? "Running commands…" : "Running \(command)…"`
  - keep `.editing(file:)` as-is; keep `.working`/`.done`.
  Then update `DevAgentEvent.substatus` (lines 106–114) to pass `detail` through
  for `.reading/.searching/.listing/.running` instead of collapsing to
  `.readingFiles`/`.running` (no-arg).
- *Alternative:* leave `DevRunSubstatus` coarse and have `PillStateBridge`
  build the label straight from the latest `DevAgentEvent` (kind + detail). Only
  do this if you'd rather not grow the enum.

**1b. Truncate for the pill.** Commands/patterns can be long. Cap the rendered
detail (~40 chars, ellipsis) in the `label` getter so the capsule doesn't blow
out. (The pill already truncates, but keep labels short.)

**1c. No registry/CLI change needed for Cursor** — it's already
`outputFormat: .streamJSON` (`DevAgentRegistry.swift:482`) and the tool kinds are
already mapped (`cursorToolCallEvent`, lines 942–967). Verify these Cursor kinds
all route (they do today): `editToolCall/writeToolCall/createToolCall` → editing;
`grepToolCall/globToolCall/searchToolCall` → searching; `lsToolCall` → listing;
`readToolCall` → reading; `shellToolCall` → running.

**Phase 1 result:** Cursor shows "Searching for "useAuth"…", "Reading
authMiddleware.ts…", "Running npm test…", "Editing Button.tsx…" — live and
changing. Claude Code also benefits (its reading/searching/listing detail, which
exists via `event(forTool:)` lines 1149–1173, stops collapsing too).

**→ STOP for review after Phase 1.**

---

## Phase 2 — Codex via `--json` (more work; the only way to unstick Codex)
Codex must move from `.text` to a parsed event stream.

**2a. Registry** — `DevAgentRegistry.swift` `makeCodex()` (lines 390–429):
- `outputFormat: .text` → `.streamJSON` (line 397).
- `baseArgs`: add `--json` →
  `["exec", "--json", "--skip-git-repo-check", "--color", "never"]` (line 398).
  (On older Codex builds the flag is `--experimental-json`; gate on the detected
  Codex version if you support old CLIs — check `DevAgentDetection`.)
- Update the stale comment at lines 384–386 (it claims we intentionally parse
  Codex as `.text`).
- Leave auth/sandbox/MCP-fence args untouched — `--json` is orthogonal.

**2b. Parser** — `DevAgentRunner.swift`. Codex's JSON is a DIFFERENT schema from
Claude/Cursor, so branch on it. Codex emits JSONL with a top-level `type`
(`thread.started`, `turn.started`, `item.started`/`item.completed`/`item.updated`,
`turn.completed`, `error`) and an `item` object whose `item_type` (or `type`)
names the activity. Add Codex handling so it produces the SAME `DevAgentEvent`
kinds. Options:
- Add a `case .codexJSON` to `DevAgentOutputFormat` and a matching branch in
  `processStreamLine` (lines 739–769), OR
- Reuse `.streamJSON` and detect Codex frames inside `parseStreamJSONLine`
  (lines 883–926) by their distinct `type`/`item_type` keys.

Map Codex item types → `DevAgentEvent` (degrade unknown → `.working`):
- file change / patch apply → `.editing(detail: <filename>)`
- command execution → `.running(detail: <command first line>)`
- file read → `.reading(detail: <filename>)`
- search / grep / web search → `.searching(detail: <query/pattern>)`
- reasoning / agent message → `.thinking` / `.message(detail: text)`
- plan update → see Phase 3
- `turn.completed` (final) → `.done`, and pull the final assistant text for the
  result-card summary (the analog of `parseResultSummary`).

**2c. Re-verify the error-capture path.** Today Codex failures surface via
`lastTextLine` (the `.text` tail — `DevAgentRunner.swift:767`, `817–825`). With
`--json` there is no plain-text tail, so wire Codex's `error` event / failed
`turn.completed` into `resultError` the way the stream-json agents already do
(lines 747–761). Don't regress error messages. (See
`HANDOFF-dev-mode-capture-agent-error-v2.md` for the current behavior.)

**2d. Confirm the live `--json` schema before coding.** Run once in a throwaway
repo and capture real frames (the registry comments show this is the team norm
for Codex/Cursor):
`codex exec --json --skip-git-repo-check "list files then read README" | tee /tmp/codex.jsonl`
Map against ACTUAL keys, not this doc's guess.

**→ STOP for review after Phase 2.**

---

## Phase 3 — surface the plan/to-do stream (best UX; touches all three)
A single live line that says "Step 2 of 5: Add auth middleware" is more
descriptive and more reassuring than tool-by-tool flicker, and it changes
meaningfully over a long run. All three agents expose a task list:
- **Claude Code:** the `TodoWrite` tool — add a case in `event(forTool:)`
  (lines 1149–1173) reading `input["todos"]` (each has `content` + `status`).
- **Cursor:** `todoToolCall` / `updateTodosToolCall` — `args.todos[]` with
  `status` ∈ `TODO_STATUS_PENDING/IN_PROGRESS/COMPLETED/CANCELLED`. Handle in
  `cursorToolCallEvent`.
- **Codex `--json`:** plan-update item type — `args`/payload carries the plan
  steps + current step.

Add a `.planStep(current: Int, total: Int, title: String)` `DevAgentEvent.Kind`
(or a dedicated substatus) and prefer it in the pill when present, falling back
to the per-tool line between plan updates. Same privacy rule: on-screen only.

---

## Appendix A — Cursor `stream-json` event shapes (verified)
Top-level `type`: `system` / `user` / `assistant` / `thinking` / `tool_call` /
`result`. Tool activity rides in its own event:
```
{ "type":"tool_call", "subtype":"started"|"completed",
  "tool_call": { "<kind>ToolCall": { "args": { … }, "result": { … } } } }
```
We emit on `subtype:"started"` (the `completed` twin would re-emit). `<kind>`
examples and their detail args:
- `shellToolCall` → `args.command`            (→ `.running`)
- `readToolCall`  → `args.path`               (→ `.reading`)
- `editToolCall` / `writeToolCall` → `args.path` (→ `.editing`)
- `grepToolCall`  → `args.pattern` (+ `args.path`) (→ `.searching`)
- `globToolCall`  → `args.globPattern`        (→ `.searching`)
- `lsToolCall`    → `args.path`               (→ `.listing`)
- `todoToolCall` / `updateTodosToolCall` → `args.todos[] {content,status}` (Phase 3)
The standalone `thinking` event is a per-token delta — skip it (noise); the stall
clock still resets on the raw bytes.

## Appendix B — Codex `--json` event shapes (confirm live, see 2d)
JSONL stream. Top-level `type`: `thread.started`, `turn.started`,
`item.started` / `item.updated` / `item.completed`, `turn.completed`, `error`.
The `item` carries an item-type discriminator; documented item categories include
**agent messages, reasoning, command executions, file changes, MCP tool calls,
web searches, and plan updates**. Map those to the `DevAgentEvent` kinds in 2b.
Sources: OpenAI Codex non-interactive docs + CLI reference (`--json`, formerly
`--experimental-json`).

## Testing / acceptance
- **Unit:** extend the existing parser tests (`parseStreamJSONLineForTesting`,
  `DevAgentRunner.swift:467`; see `ZerroTests/DevAgentRunnerTests.swift`,
  `CursorTrackerTests.swift`) with: a Cursor `grepToolCall`/`lsToolCall`/
  `readToolCall` started frame → asserts `.searching/.listing/.reading` WITH
  detail; Codex `item.*` frames → asserts the mapped kind+detail; a Codex `error`
  frame → populates `resultError`.
- **Manual:** dispatch a multi-step task to each agent; confirm the pill text
  CHANGES through reading → searching → editing → running, shows real
  filenames/commands, and ends on the result card. Confirm Codex no longer sits
  on "Working on your changes…".
- **Privacy check:** grep the analytics/telemetry call sites — no `detail`,
  path, command, or pattern is ever included.
- **Regression:** Codex failure still shows a real error message (2c); the stall
  prompt + Cancel/Kill paths are unchanged.

## Build order
Phase 1 (Cursor + shared UI) → review → Phase 2 (Codex `--json` + error
re-wire) → review → Phase 3 (plan/to-do). Each phase ships independently; Phase 1
delivers most of the visible win on its own.

## Key anchors (for quick navigation)
- `apps/desktop/Zerro/Services/Dev/DevAgentRunner.swift`
  - `DevRunSubstatus` + labels: 50–67
  - `DevAgentEvent` model: 78–115; lossy `substatus` collapse: 106–114
  - `processStreamLine` (.streamJSON vs .text): 739–769
  - `parseStreamJSONLine` (Claude `assistant` + Cursor `tool_call`): 883–926
  - `cursorToolCallEvent`: 942–967
  - `event(forTool:input:)` (Claude tool map): 1149–1173
- `apps/desktop/Zerro/Services/DevAgentRegistry.swift`
  - `makeClaudeCode`: 306+ (`.streamJSON`, 313)
  - `makeCodex`: 390–429 (`.text` → change, 397; baseArgs, 398; stale comment, 384–386)
  - `makeCursor`: 475–526 (`.streamJSON`, 482)
- `apps/desktop/Zerro/AppState.swift`: `.running(substatus)` → `devRunSubstatus`: 3196–3198
- `apps/desktop/Zerro/PillStateBridge.swift`: `devRunSubstatus?.label` → `.devProgress`: 126
- `apps/desktop/Zerro/Surfaces/Pill/PillView.swift`: `.devProgress` render: 475–476
