# Claude Code handoff — Cursor as a full dispatchable agent (Phase 3)

Make **Cursor** (`cursor-agent`) a fully dispatchable Dev Mode agent, alongside
Claude Code and Codex. Most of the plumbing already exists — this is mainly a
`DevAgentRegistry.makeCursor()` entry, **gated on verifying the live CLI contract
first** (the design doc's cursor flags may be stale, exactly like we pinned Codex
against `codex exec --help`).

App-only (Swift). **Part 1 is a verify-and-report STOP** before any wiring; then
build, then **STOP again for the live E2E** (Part 7).

## What already exists — do NOT rebuild
- **Detection:** `Services/Dev/DevAgentDetection.swift` already warms
  `which cursor-agent` (login-shell `DevAgentBinaryResolver`) and
  `probeCursorModels()` → publishes `cursorModels: [AgentModel]`.
- **Model sourcing:** `Services/Dev/AgentModelManifest.swift` already maps the
  agent id **`"cursor"`** → `.cursorCLI` (`AgentModelMapping.source(forAgent:)`
  ~line 57-61) and `models(forAgent:)` → `DevAgentDetection.shared.cursorModels`
  (~line 150). **The entry's `id` MUST be the literal `"cursor"`** so this
  mapping hits.
- **Runner:** `Services/Dev/DevAgentRunner.swift` spawns any agent from
  `DevAgentEntry` data, parses `.streamJSON` / `.text`, and already has the
  agent-agnostic wall-clock (300s) + inactivity (60s) timeouts + SIGTERM→SIGKILL
  cancel — **the known `cursor-agent -p` hang is already covered**, no
  Cursor-specific timeout work.
- **Checkpoint/dispatch/recovery/billing:** all agent-agnostic — untouched.

So the gap is: the **registry entry** + the **verified contract** it encodes.

## Read first
- `Services/DevAgentRegistry.swift` — `DevAgentEntry` (the declarative contract:
  `promptDelivery`, `outputFormat`, `baseArgs`/`editsOnlyArgs`/`allowCommandsArgs`,
  `modelFlagName`) and `makeClaudeCode()` / `makeCodex()` as the two patterns to
  mirror. Note `all()` (~154) lists the agents; `claudeCodeID`/`codexID` constants.
- `Services/Dev/AgentModelManifest.swift` ~57-61, ~146-150 (the `"cursor"`
  mapping that's already there).
- `Services/Dev/DevAgentRunner.swift` — how `outputFormat` drives parsing, so you
  can choose Cursor's format in Part 3.

## Part 1 — VERIFY the live cursor-agent contract (STOP, report back)
Do **not** assume the design doc's `cursor-agent -p --force --output-format json`
is current. In a throwaway git repo, run against the installed CLI and report the
real answers before wiring:
- `cursor-agent --help` and the non-interactive/print subcommand's help
  (`cursor-agent -p --help` or whatever it is). Pin:
  1. **Invocation** — the headless/print form (subcommand? `-p`/`--print`?).
  2. **Prompt delivery** — stdin, a trailing positional arg, or a `--message`-style
     flag? (Maps to `DevAgentPromptDelivery.stdin` / `.argument` / `.messageFlag`.)
  3. **Output format** — is there a line-delimited `stream-json` (like Claude, →
     `.streamJSON` with a parseable event schema) or only a single final `json`
     blob / plain text? (Drives Part 3.)
  4. **Permission posture** — what does `--force` actually do, and is there an
     edits-only vs full-access distinction (a sandbox / "don't run shell" flag) or
     only one auto-accept mode? (Drives Part 4.)
  5. **Model flag** — confirm `--model <id>` exists AND accepts the ids
     `cursor-agent models` prints (the ones `probeCursorModels()` already lists).
  6. **A 1-line smoke dispatch** — point it at a tiny repo with a trivial prompt
     ("add a comment to README"), confirm it edits the file headlessly and exits
     (and roughly how it streams/terminates — feeds the timeout sanity check).
- Report the findings + the exact argv you intend to bake in. **Pause for review
  here.**

## Part 2 — `makeCursor()` in the registry
Per the verified contract, add a `makeCursor()` mirroring `makeCodex()`:
- `cursorID = "cursor"` constant (and switch `AgentModelManifest`'s line-61
  literal to use `DevAgentRegistry.cursorID` for consistency).
- `id: cursorID`, `displayName: "Cursor"`, `executableName: "cursor-agent"`,
  the verified `promptDelivery` / `outputFormat` / args, `modelFlagName: "--model"`
  (if Part 1 confirms it), `absolutePath: DevAgentBinaryResolver.resolve("cursor-agent")`.
- Add `makeCursor()` to `all()` → `[makeClaudeCode(), makeCodex(), makeCursor()]`.
- Update the stale top-of-file comment (it still says "Phase 1 ships exactly ONE
  agent" — Codex already shipped; now Cursor too).
- Document the verified contract in a doc-comment block exactly like `makeCodex()`
  did (the help version + date + each flag's rationale), so the next reader knows
  it was pinned, not guessed.

## Part 3 — output format
- If Part 1 found a **clean line-delimited stream-json** with a mappable event
  schema → use `.streamJSON` and extend the runner's parser to Cursor's event
  shape for live substatus (and the `result`-equivalent summary for the result
  card, like Claude Code's).
- If it's a **single final JSON blob or messy** → use `.text` (like Codex) and do
  NOT pass a `--output-format json` flag (it would dump JSON into the pill tail);
  prefer plain text output. The result card falls back to the diff-generated
  change line, which is already the Codex behavior. **Prefer `.text` unless
  stream-json is clearly clean** — don't half-parse a schema.

## Part 4 — permission posture (edits-only vs allow-commands)
Map Cursor to the existing two-posture model:
- If `cursor-agent` has a shell-restricted / sandbox mode → use it for
  `editsOnlyArgs` (the default safe posture) and the full-auto form for
  `allowCommandsArgs`, mirroring Claude/Codex.
- If Cursor has **no** edits-only mode (only one auto-accept form, e.g. `--force`)
  → set `editsOnlyArgs == allowCommandsArgs` to that form and **call this out in
  the report + the doc-comment**: Cursor can't be restricted to file-edits-only,
  so the **git checkpoint + revert remains the containment** (which it always is).
  This is a user-facing safety nuance worth surfacing, not a blocker.

## Part 5 — surface it in the UI (mostly already wired)
- Detection already probes Cursor, so the dev-settings **Agent** section should now
  list it (installed → selectable; not-installed → the existing "install" hint).
  Confirm selecting it persists `selectedAgentID = "cursor"`.
- The **Model** section should populate from `cursorModels` via the existing
  `models(forAgent:)` path — confirm it shows Cursor's models with the checkmark,
  and `--model` is appended on dispatch. (No new UI code expected; verify the
  existing compact-toolbar dev-settings menu renders Cursor correctly.)

## Part 6 — tests
- `DevAgentEntry` for Cursor: `arguments(permission:.editsOnly/.allowCommands,
  model:)` produces the verified argv, and appends `--model <id>` only when a model
  is set.
- `AgentModelMapping.source(forAgent: "cursor") == .cursorCLI` and
  `models(forAgent:"cursor")` returns the probed `cursorModels` (stub
  `DevAgentDetection`).
- A dispatch test with a stubbed runner: Cursor entry → correct executable +
  argv + prompt delivery; cancel still SIGTERM→SIGKILLs (reuse the existing runner
  test harness).
- Registry: `all()` includes Cursor; `entry(id:"cursor")` resolves.

## Part 7 — live E2E (STOP for review)
With `cursor-agent` installed, in a localhost git project:
1. Select **Cursor** + a model in the dev-settings menu; record a Dev Mode change
   ("make this button bigger" while hovering) → confirm it dispatches to Cursor,
   edits the right file, the pill runs and the result card shows the diff.
2. **Cancel** mid-run → agent terminates, tree reverts (the shared safe-cancel).
3. **Undo** from the result card → restores. (Same shared revert — should just
   work, but confirm with a third agent in the mix.)
4. Confirm the selected `--model` actually took (Cursor used it, not its default).

## Acceptance criteria
- Cursor is a selectable agent; a Dev Mode recording dispatches to `cursor-agent`
  with the **verified** argv, edits files, and drives the pill/result card.
- The CLI contract is pinned against the live `--help` (version + date in the
  doc-comment), not copied from the design doc.
- Model list comes from `cursor-agent models` (existing path); `--model` is passed;
  the pick is remembered per agent.
- `.text` (or a clean `.streamJSON`) output renders sanely — no raw JSON in the pill.
- Cancel/Undo/timeout all work for Cursor via the shared agent-agnostic paths.
- Claude Code + Codex + normal mode unchanged; build + tests green.

## Notes
- This completes the three-CLI promise (design §2). The custom-command escape
  hatch + port→folder zero-setup are the remaining Phase 3 items (separate handoffs).
- If Part 1 reveals `cursor-agent` has materially changed (e.g. no headless mode,
  or auth that can't run unattended), STOP and report — that's a product decision,
  not something to force.
