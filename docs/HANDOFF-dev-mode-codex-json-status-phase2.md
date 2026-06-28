# Claude Code handoff — Phase 2: Codex `--json` descriptive status

## Goal
Make the Dev Mode pill show specific, changing status for **Codex** like it now
does for Cursor/Claude (Phase 1). Today Codex runs `outputFormat: .text`, so every
stdout line becomes a generic `.message` → `.working` → "Working on your changes…"
for the whole run. Switch Codex to its structured `--json` event stream and map
those events to the SAME `DevAgentEvent` kinds Phase 1 already renders.

This is bigger than Phase 1 (new CLI flag + a new parser + the error/summary path
moves off the text tail). Build it in a worktree, STOP after the parser for
review, then wire the registry + error path.

## Prerequisite — Phase 1 must be in
This builds on Phase 1's enriched `DevRunSubstatus` (`.reading/.searching/
.listing/.running(detail:)` etc.) and `DevAgentEvent.substatus` passthrough. If
Phase 1 isn't merged into your base branch yet, branch from it, not bare staging.

## STEP 0 — capture a REAL Codex `--json` run first (do not skip)
The schema below is from current docs, but pin it to THIS machine's Codex build
before coding. In the worktree, against a throwaway repo:

```
codex exec --help | grep -i json        # confirm the flag is --json (older builds: --experimental-json)
cd /tmp && rm -rf codexjson && mkdir codexjson && cd codexjson && git init -q && echo hi > README.md && git add -A && git commit -qm init
codex exec --json --skip-git-repo-check "list the files, read README.md, then create NOTES.md with one line" | tee /tmp/codex.jsonl
```

Then map the parser to the ACTUAL keys in `/tmp/codex.jsonl`. If any field name
differs from this doc, the live capture wins — note the diff in the PR.

## Verified schema (current `codex exec --json`, JSONL — one object per line)
Top-level events (a `type` field on every line):
- `thread.started` `{thread_id}` — ignore (no render)
- `turn.started` `{}` — ignore
- `turn.completed` `{usage:{…}}` — **terminal success**
- `turn.failed` `{error:{message}}` — **terminal failure** → capture `error.message`
- `error` `{message}` — fatal stream error → capture `message`. EXCEPTION: a
  message starting with `"Reconnecting…"` is a transient non-fatal retry — ignore it.

Item events — envelope `{type:"item.started"|"item.updated"|"item.completed",
item:{id, type, …}}`. The `item.type` discriminator + the fields we use:
- `agent_message` (completed only) — `item.text` → final/narration text
- `reasoning` (completed only, if enabled) — `item.text` → thinking
- `command_execution` (started **and** completed) — `item.command`
  (e.g. `"bash -lc ls"`), `item.aggregated_output`, `item.exit_code`,
  `item.status` (`in_progress`/`completed`/`failed`)
- `file_change` (**completed only**) — `item.changes[]` of `{path, kind}` where
  `kind` ∈ `add`/`update`/`delete`; `item.status`
- `mcp_tool_call` (started and completed) — `item.server`, `item.tool`,
  `item.arguments`, `item.result`, `item.error`, `item.status`
- `web_search` (**completed only**) — `item.query`
- `todo_list` (started/updated/completed) — `item.items[]` of `{text, completed}`
- `error` item (completed only) — `item.message` → non-fatal warning

Real example lines (from the schema reference; confirm against /tmp/codex.jsonl):
```
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[{"path":"docs/x.md","kind":"add"},{"path":"docs/y.md","kind":"update"}],"status":"completed"}}
{"type":"item.completed","item":{"id":"item_7","type":"web_search","query":"codex exec --json schema"}}
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Done. I updated the docs."}}
{"type":"turn.completed","usage":{"input_tokens":24763,"output_tokens":122}}
{"type":"turn.failed","error":{"message":"model response stream ended unexpectedly"}}
```

## Mapping → `DevAgentEvent` (emit ONE event per meaningful line; unknown → nil)
Mirror Phase 1's "emit on start, don't re-emit on completion" rule, EXCEPT for the
completed-only item types (file_change, web_search), which must emit on completion
because that's their only line.

| Codex line | DevAgentEvent | detail |
|---|---|---|
| `item.started` `command_execution` | `.running` | cleaned `command` (strip leading `bash -lc `/`bash -c `) |
| `item.completed` `command_execution` | nil (already shown on start) | — |
| `item.completed` `file_change` | `.editing` | `lastComponent(changes[0].path)` (append `" +N"` if `changes.count > 1`) |
| `item.completed` `web_search` | `.searching` | `query` |
| `item.started` `mcp_tool_call` | `.running` | `tool` (or `server/tool`) |
| `item.completed` `mcp_tool_call` | nil | — |
| `item.completed` `reasoning` | `.thinking` | nil |
| `item.completed` `agent_message` | `.message` | `text` (also capture as summary — below) |
| `item.*` `todo_list` | nil for now (Phase 3 surfaces the plan line) | — |
| `thread.started`/`turn.started`/`turn.completed`/`turn.failed`/top-level `error` | nil (handled as lifecycle/summary/error, not feed events) | — |
| `turn.completed` | `.done` | — |

Reuse the existing detail helpers: `lastComponent(_:)`, `commandLine(_:)`,
`nonEmpty(_:)`. Add one small `strippedShell(_:)` to drop the `bash -lc `/`bash -c `
wrapper from `command` so the label reads `Running ls…` not `Running bash -lc ls…`.

## Summary + error capture (this is what moves off the text tail)
Today (`.text`) Codex's failure detail rides on `lastTextLine`
(`DevAgentRunner.swift:563`, set at `:767`, used in the exit handler at
`:823–826`), and there is no real summary. With `--json`:
- **Summary (success):** on each `item.completed` `agent_message`, set
  `resultSummary = summaryDroppingQuestions(item.text)` (last one wins) — same
  treatment Claude/Cursor get via `parseResultSummary` (`:974`, `summaryDropping
  Questions` `:1087`). The exit handler already rides `resultSummary` out on
  `.succeeded(summary:)` (`:811`).
- **Error (failure):** set `resultError` (`:558`) from `turn.failed.error.message`,
  the top-level fatal `error.message`, or a `command_execution`/`file_change`
  item whose `status == "failed"`. The exit handler already prefers
  `resultError` for the `.nonZeroExit` detail (`:823–826`), so the pill shows the
  real reason. `lastTextLine` becomes a dead fallback for Codex — fine to leave.

## Implementation (App-only, Swift)

### Part A — registry (`DevAgentRegistry.swift`, `makeCodex()` 390–429)
- `outputFormat: .text` → `.codexJSON` (new case, Part B). Line 397.
- `baseArgs`: add `--json` right after `exec` →
  `["exec", "--json", "--skip-git-repo-check", "--color", "never"]`. Line 398.
  (`--color` is a no-op for JSON; leave it or drop it. If STEP 0 shows the flag is
  `--experimental-json` on the installed build, use that — ideally gate on the
  detected version in `DevAgentDetection`.)
- Rewrite the now-stale comment at lines **384–386** (it claims we intentionally
  parse Codex as `.text` because its JSON differs from Claude's — that's exactly
  what we're changing; point it at the new `parseCodexJSONLine`).
- Leave auth / sandbox / `--ignore-user-config` / Seatbelt args untouched —
  `--json` is orthogonal to all of them. (Re-run one fenced dispatch to confirm
  auth still works under the wrapper, per the registry's existing discipline.)

### Part B — output format + parser (`DevAgentRunner.swift`)
- Add `case codexJSON` to `DevAgentOutputFormat` (`DevAgentRegistry.swift:41–46`).
- Add `case .codexJSON` to `processStreamLine` (`:739–769`), structured like the
  `.streamJSON` branch (`:741–763`): capture error → capture summary → emit event.
  Keep it defensive (unknown shapes → return, never crash):
  ```
  case .codexJSON:
      if let errText = DevAgentProcessExecution.parseCodexErrorEvent(line) { resultError = errText }
      if let summary = DevAgentProcessExecution.parseCodexSummary(line) { resultSummary = summary }
      guard let event = DevAgentProcessExecution.parseCodexJSONLine(line) else { return }
      emit(event)
  ```
- Add `parseCodexJSONLine(_:)` (the table above), `parseCodexSummary(_:)` (last
  `agent_message.text` → `summaryDroppingQuestions`), and `parseCodexErrorEvent(_:)`
  (`turn.failed.error.message` / fatal top-level `error.message` excluding
  `"Reconnecting…"` / failed item) next to the existing Cursor/Claude parsers
  (`parseStreamJSONLine` `:883`, `parseResultSummary` `:974`,
  `parseStreamErrorEvent` `:1063`). Add `…ForTesting` shims beside `:472–487`.
- Do NOT touch `parseStreamJSONLine` — Codex gets its own parser so the
  Claude/Cursor path stays untouched.

**→ STOP for review after Part B (parser + tests), before shipping the registry flip.**

## Tests (`apps/desktop/ZerroTests/DevAgentRunnerTests.swift`)
Add table-driven tests using literal JSONL lines from the schema (and from your
STEP 0 capture):
- `command_execution` `item.started` → `.running` with the shell-stripped command;
  `item.completed` → nil.
- `file_change` `item.completed` → `.editing` with the basename (and `+N` when
  multiple changes).
- `web_search` `item.completed` → `.searching("…query…")`.
- `reasoning` → `.thinking`; `agent_message` → `.message` AND `parseCodexSummary`
  returns the question-stripped text.
- `turn.completed` → `.done`; `turn.failed` → `parseCodexErrorEvent` returns the
  message; top-level `"Reconnecting… 1/5"` error → nil (non-fatal).
- Unknown/garbage line → nil (no crash).
Keep `-parallel-testing-enabled NO` (the suite is serial — see prior handoffs).

## Acceptance
- `xcodebuild build-for-testing` succeeds; new + existing `DevAgentRunnerTests`
  pass serially.
- Live: a Codex dev dispatch moves through `Running …` → `Editing NOTES.md…` →
  finishes on a result card with the agent's final message — no longer stuck on
  "Working on your changes…". A failing Codex run shows the real error in the
  result card (not the generic fallback).
- Privacy invariant intact: `command`/`path`/`query` ride only event → substatus
  → pill label; nothing new reaches analytics (same rule Phase 1 held).
- Stall/cancel machinery untouched; the only process terminator is still an
  explicit user action.

## Out of scope (Phase 3)
`todo_list` is parsed to nil here. Phase 3 surfaces a "Step N of M: …" line across
all three agents (Codex `todo_list`, Cursor `todoToolCall`, Claude `TodoWrite`).

## Anchor cheatsheet
- `DevAgentRegistry.swift`: `DevAgentOutputFormat` 41–46; `makeCodex` 390–429
  (stale comment 384–386, `outputFormat` 397, `baseArgs` 398).
- `DevAgentRunner.swift`: `processStreamLine` 739–769 (`.text` branch 764–768);
  state `resultSummary` 551 / `resultError` 558 / `lastTextLine` 563; exit handler
  811 (success) + 823–826 (failure detail chain); parsers `parseStreamJSONLine`
  883, `parseResultSummary` 974, `parseResultError` 1006, `parseStreamErrorEvent`
  1063, `summaryDroppingQuestions` 1087; testing shims 472–487; detail helpers
  `lastComponent`/`commandLine`/`nonEmpty` ~1178+.

## Sources (schema)
- Codex non-interactive `--json` (OpenAI): https://developers.openai.com/codex/noninteractive
- Codex `exec --json` event cheatsheet (field-level, with example lines): https://takopi.dev/reference/runners/codex/exec-json-cheatsheet/
