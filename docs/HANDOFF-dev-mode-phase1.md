# Claude Code handoff — Dev Mode, Phase 1 (the end-to-end loop)

Implement **Phase 1** of Dev Mode in the Zerro macOS app: a working
record → prompt → dispatch-to-Claude-Code → files-edited → hot-reload → revert
loop, using **click-only** anchoring and **Claude Code only**. This is the
foundation the later phases (hover-track deixis, more agents, port magic) build on.

## Read first
- `docs/DEV-MODE-DESIGN.md` — the full design. **Binding.** Especially §1
  (toolbar), §2 (agent model), §4 (git checkpoint), §6 (dev prompt), §8 (pill
  states), §9 (runner), §10 (analytics), §11 (research-driven corrections — read
  the CLI-spawn plumbing and prompt-quality parts carefully).
- The existing recording → generation flow you'll branch off:
  `AppState.swift` (`runPromptGeneration`, `acceptGenerationResult`),
  `Surfaces/AreaSelector/*`, `Services/ModelRegistry.swift`,
  `Services/PromptGenerationSystemPrompt.swift`,
  `supabase/functions/generate/prompt.ts`, `Surfaces/Pill/PillView.swift`,
  `Observability/Analytics.swift`, `Preferences/PreferencesStore.swift`.

## Ground rules
- **Do not change normal-mode behavior.** Everything new is gated behind a
  recording's `isDevMode` flag. A non-Dev recording must behave exactly as today
  (clipboard, etc.).
- Match surrounding code + comment style. Keep diffs focused and reviewable.
- Zerro is **non-sandboxed Developer-ID** (`ENABLE_APP_SANDBOX = NO`) — spawning
  external binaries is allowed. Don't add an App Sandbox entitlement.
- Analytics: metadata only, behind the existing opt-out gate. Never content, paths,
  or email (§14.5). Enums/counts/durations/booleans only.
- **Work milestone by milestone. Build + test after each. STOP for review at
  Milestone 6 (the AppState wiring) before going live** — that's the first point
  the agent actually edits real files.

## Scope — Phase 1 ONLY
In: the toggle + inline toolbar + record-time validation; explicit folder picker
(remembered); Claude Code adapter; `mode:"dev"` dev prompt; click-only anchoring
(reuse existing click data — **no** cursor/hover track yet); git checkpoint +
revert; pill states through done/failed; Phase-1 analytics.

Out (do NOT build now): the ~30Hz cursor/hover track, dwell detection, marker
compositing, OCR, the confidence/`confirmAnchors` flow, Codex/Cursor adapters,
auto-detect dropdown, port→folder detection, review-before-apply, the
self-correction loop, non-git fallback.

---

## Milestone 1 — Toolbar: toggle + inline chips + validation (UI/state only)
Files: `Surfaces/AreaSelector/AreaSelectorState.swift`, `AreaSelectorView.swift`,
`AreaSelectorWindowController.swift`, `Preferences/PreferencesStore.swift`.

- Add to `AreaSelectorState`: `isDevMode: Bool`, `selectedAgentID: String?`,
  `projectURL: URL?` (+ display name), and a transient `devValidationMessage: String?`.
- Render a standalone **Dev Mode toggle pill on the left**, separate from the
  settings cluster (see §1 + the agreed mock). When `isDevMode` is on, render two
  extra chips in the cluster: an **agent chip** (Milestone 2 fills it; for now show
  "Claude Code") and a **folder chip** that shows the project name or, when unset,
  an amber/dashed "Select folder" attention state.
- Add the geometry helpers (`devToggleFrame`, `agentChipFrame`, `folderChipFrame`)
  and hit-test them in `AreaSelectorWindowController`'s existing mouse monitor, the
  same way the model/mic dropdowns are handled.
- Folder chip click → `NSOpenPanel` (directories only) → store `projectURL`.
  Persist last-used `projectURL` + `selectedAgentID` in `PreferencesStore`; seed
  them back on next open.
- **Validation on Record**: if `isDevMode` and (`selectedAgentID == nil` ||
  `projectURL == nil`), block the record action and set `devValidationMessage`
  ("Pick a folder to work in before recording."). Show it inline near the toolbar.
- Capture `dev_mode_toggled` analytics on toggle.

*Test:* toggle on → chips appear; record with no folder → blocked + message; pick a
folder → record proceeds (into the normal flow for now). Normal mode unaffected.

## Milestone 2 — `DevAgentRegistry` + Claude Code detection
Files: new `Services/DevAgentRegistry.swift` (model on `ModelRegistry.swift`); a
small helper for binary resolution.

- `DevAgentEntry`: `id`, `displayName`, `executableName` ("claude"),
  `promptDelivery` (.stdin), `extraArgs` (`["-p","--permission-mode","acceptEdits",
  "--output-format","stream-json","--verbose"]`), `outputFormat` (.streamJSON),
  `installed: Bool`, `absolutePath: URL?`. Phase 1 ships **one** entry: Claude Code.
- Detect install + resolve absolute path by running `/bin/zsh -lc 'command -v claude'`
  once (login shell → real PATH; §11). Cache the result. The agent chip reflects
  installed/not-installed; if not installed, show an install hint and keep the
  agent unset (so validation blocks).
- **Verify the exact flags against the installed CLI** (`claude --help`) before
  committing — versions drift; adjust `extraArgs` to match.

*Test:* on a machine with Claude Code, the chip shows it installed with a resolved
absolute path.

## Milestone 3 — `GitCheckpoint` service (+ unit tests)
Files: new `Services/Dev/GitCheckpoint.swift` + tests.

Implement against a project directory (all `git` calls run with `cwd = projectURL`):
- `checkpoint() -> Checkpoint`:
  - Verify repo: `git rev-parse --is-inside-work-tree`; if not a repo → throw a
    typed error (Phase 1 requires git; surfaced to the user as "Dev Mode needs a git
    repo").
  - `git stash create` → capture the snapshot commit SHA (may be empty if the tree
    is clean — then record `HEAD` SHA as the base).
  - Snapshot untracked files: `git ls-files --others --exclude-standard -z` → copy
    each into a Zerro temp dir (stash-create omits untracked).
  - Return `{ baseSha, stashSha?, untrackedSnapshotDir }`.
- `revert(_ checkpoint:)`:
  1. `git checkout <stashSha ?? baseSha> -- .` (restore tracked to checkpoint).
  2. `git clean -fd` (remove untracked the agent created; respects `.gitignore`,
     so build dirs are safe).
  3. Copy the saved untracked snapshot back into place.
  Net: working tree == exact pre-run state; user's uncommitted work intact; branch
  history untouched.
- `diffStat(since checkpoint:) -> (files:Int, added:Int, removed:Int)` via
  `git diff --stat`/`--numstat` against the checkpoint.

*Test (unit):* a temp git repo with tracked + dirty + untracked files; checkpoint,
mutate/add/delete files, revert → assert the tree is byte-identical to pre-run;
assert `diffStat` counts are correct.

## Milestone 4 — `DevAgentRunner` (spawn + stream + timeout/kill)
Files: new `Services/Dev/DevAgentRunner.swift` (protocol + Claude Code impl).

- Spawn with `Process`: `executableURL` = the resolved absolute `claude` path (or
  `/bin/zsh -lc 'exec claude …'` if env/PATH is needed), `currentDirectoryURL` =
  `projectURL`, the registry `extraArgs`, and the **prompt written to stdin**
  (avoids shell-quoting a long prompt). Pipe stdout/stderr, line-buffered.
- Parse the `stream-json` events → emit a `substatus` stream the pill consumes
  ("reading files", "editing <file>", "running", "done"). Map unknown/other events
  to a generic "working…".
- **Timeouts (§9):** overall wall-clock cap (default 5 min) **and** inactivity
  timeout (no output 60s). On either → SIGTERM, then SIGKILL after a short grace →
  finish as `.failed(reason: .timeout)`. Always close stdin after writing the prompt
  (the Cursor-style hang guard; applies defensively here too).
- Non-zero exit → `.failed(reason: .exit(code, stderrTail))`. Clean exit →
  `.succeeded`.
- **Concurrency:** at most one run at a time; reject/queue a second dispatch.

*Test:* a fake/echo binary to exercise success, non-zero exit, inactivity timeout,
and the kill path without needing the real CLI.

## Milestone 5 — `mode:"dev"` prompt variant
Files: `Services/PromptGenerationSystemPrompt.swift` **and**
`supabase/functions/generate/prompt.ts` (keep both in sync — local BYOK + managed
proxy paths). Thread a `mode` parameter from the Dev recording through to both.

The dev system prompt must (per §6 + §11):
- Output the `agent_prompt` shape: `Goal:` / enumerated `Changes:` (one per
  instruction, ordered as spoken) / `Scope:`.
- Anchor each change to **visible on-screen text** (the agent greps it). Phase 1:
  use the recording's **click positions + frames** to identify which element was
  acted on; no hover track yet.
- Include **route context** (the visible `localhost/...` path if present in frames).
- Add a **runtime note**: editing a live dev server with hot reload → make minimal,
  targeted edits; don't scaffold/restart.
- **CSS/quality constraints (the #1 failure mode, §11):** use the project's existing
  tokens/utilities/components; prefer relative/flex over hardcoded px; respect dark
  mode + responsiveness; smallest change that satisfies the intent.
- Preserve the user's **original phrasing verbatim** in a "user said:" line as a
  tiebreaker; resolve vague asks conservatively (smallest reversible change).

*Test:* the existing prompt test suites (`prompt_test.ts`, the Swift prompt evals)
gain a dev-mode case asserting the structure + that constraints are present.

## Milestone 6 — AppState wiring (THE INTEGRATION — stop for review here)
Files: `AppState.swift`, a new `Services/Dev/DevDispatchCoordinator.swift`.

- Carry `isDevMode` + `projectURL` + `selectedAgentID` from the recording into
  generation (alongside the existing `recordingModelID`).
- After generation produces the `agent_prompt` artifact: if the recording was Dev
  Mode, **branch before the clipboard step** — do NOT copy to clipboard. Instead the
  coordinator runs: `checkpoint()` (M3) → `DevAgentRunner.run(prompt, projectURL)`
  (M4) streaming substatus into the pill → on success compute `diffStat` → `.done`;
  on failure → `.failed`. Store the checkpoint so Revert (M7) can use it.
- Normal mode path is untouched.
- **Pause here and request review** before enabling the live edit path.

## Milestone 7 — Pill states + Revert
Files: `Surfaces/Pill/PillView.swift` (+ the pill state enum in `AppState`).

- Add the Dev tail (§8): `checkpointing → dispatching → agentRunning (substatus +
  elapsed) → done | failed`.
- `done`: "N files changed (+x −y)" + **[Revert]** + **[Done]**. Revert →
  `GitCheckpoint.revert` → confirm restored.
- `failed`: short stderr tail + **[Revert]** + **[Retry]**. No auto-revert.

## Milestone 8 — Analytics
File: `Observability/Analytics.swift`.
Add (metadata only): `dev_dispatch_started` (agent_id), `dev_run_succeeded` /
`dev_run_failed` (reason, duration_ms, files_changed), `dev_revert_used`.
(`dev_mode_toggled` already added in M1.)

## Milestone 9 — End-to-end manual test
Against a local sample (e.g., a Vite/Next app on `localhost:3000` in a git repo):
record the page, say "make the 'Get started' button teal," stop. Expect: checkpoint
taken → Claude Code edits the file → the dev server hot-reloads → the button turns
teal → **Revert** restores the file exactly.

---

## Acceptance criteria (Phase 1 done)
- Dev Mode toggle + inline agent/folder chips + record-time validation work; normal
  mode unchanged.
- Claude Code is detected and dispatched with the correct non-interactive flags,
  editing files in the chosen project.
- A click-anchored change ("make the 'Get started' button teal") lands on disk and
  hot-reloads in the browser.
- Git checkpoint + one-click Revert restore the working tree to its exact pre-run
  state (tracked, dirty, and untracked), verified by the M3 unit tests.
- Runner handles success, non-zero exit, and the hang/timeout path gracefully.
- Phase-1 analytics fire (metadata only).

## Suggested commit boundaries
One commit per milestone (M3 and M4 are independently testable services and good
standalone commits). Keep M6's live-edit enablement in its own commit after review.
