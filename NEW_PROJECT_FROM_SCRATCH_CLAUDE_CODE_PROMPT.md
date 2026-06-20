# Claude Code handoff prompt — "Create a project from scratch" in Dev Mode

Copy everything below the line into Claude Code, running from the repo root.

---

You are implementing a new Dev Mode feature in the Zerro macOS app
(`apps/desktop`, Swift/SwiftUI, menu-bar app). Read this entire brief, then
explore the referenced files before writing code. There is a companion design
doc at `NEW_PROJECT_FROM_SCRATCH_HANDOFF.md` — read it first.

## Goal

Today Dev Mode requires the user to select a folder that is **already a git
repo**. I want users to be able to **start a brand-new project from scratch**:
they pick a location (e.g. their Desktop), give the project a name, and Zerro
creates a new subfolder, runs `git init` in it, and then the existing Dev Mode
pipeline (checkpoint → coding agent → one-click revert) takes over so the whole
project creation is fully revertible.

## Critical context — most of the safety work already exists

Do **not** rewrite the checkpoint/revert system. Read
`apps/desktop/Zerro/Services/Dev/GitCheckpoint.swift` carefully: it **already
handles a repo with no commits yet** (fresh `git init`). Specifically:

- `GitCheckpoint.baseSha` is the empty string for a no-commit repo;
  `hasBaseCommit` is false.
- `restoreRef` falls back to the empty-tree SHA
  (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`).
- `revert(_:)` has a dedicated `hasBaseCommit == false` branch that runs
  `git reset -q` + `git clean -fd` + restores the untracked snapshot, returning
  the working tree to empty.

So once a fresh `git init`'d subfolder is set as `projectURL`, the existing
`DevDispatchCoordinator` → `GitCheckpointService.checkpoint()` → agent →
`diffStat`/`revert` flow works **unchanged**. Your job is the front half: create
the subfolder, `git init` it, and wire the UI/state to drive that.

## Design decisions (already made — do not re-litigate)

1. **Always create a new named SUBFOLDER** inside the chosen location. Never
   `git init` the chosen location directly (revert's `git clean -fd` must never
   be able to touch unrelated files in e.g. the Desktop root). `projectURL`
   becomes `<location>/<sanitized-name>/`.
2. **Name comes from an inline text field** the user fills before dispatch.
3. **Permissions unchanged** — from-scratch runs use the existing
   `DevAgentPermission` / `confirmGate` path. No new autonomy.
4. **No initial commit** — leave the fresh repo with no `HEAD`. This is the
   already-tested `hasBaseCommit == false` path. Do not create an empty commit.
5. **Revert keeps the (now-empty) folder** — do not make Revert delete the
   project root. That's existing-behavior-preserving; deleting the root is out
   of scope.
6. **"Edit existing" and "New project" are SEPARATE, explicit gestures** — the
   choice is made by the user via distinct UI actions BEFORE recording, and is
   NEVER inferred from the spoken/typed request. The coding agent only ever
   receives `projectURL` + a prompt; it has no authority to decide to scaffold a
   new project. This is the core invariant that prevents "user picked their repo,
   asked for an edit, and Zerro made a new project inside it." See
   "Misunderstanding guards" below — implement those guards as specified.

## Files to read before coding

- `apps/desktop/Zerro/Services/Dev/GitCheckpoint.swift` — the no-commit path
  (confirm, don't change).
- `apps/desktop/Zerro/Services/Dev/DevDispatchCoordinator.swift` — confirm the
  dispatch needs no change; `.notAGitRepo` should simply never fire for a
  freshly-init'd folder.
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift`
  — `presentFolderPicker(window:state:)` (~line 1227) and
  `beginGitRepoCheck(for:state:)` (~line 1273). This is where folder selection
  and the async git-repo probe live. Add the new-project creation alongside.
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorState.swift` —
  `projectURL`, `setProjectURL`, `projectIsGitRepo`, `setProjectGitRepo`,
  `isProjectNotGitRepo`, `setCheckingGitRepo`, `devValidationMessage`,
  `setDevState`.
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift` —
  `devProjectRow` (~line 1465) and `devGitReassuranceRow` (~line 1504) for where
  the UI affordance and name field go.
- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` — `devProjectURL`
  (~line 164) persistence.
- Tests: `apps/desktop/ZerroTests/GitCheckpointTests.swift`,
  `DevModeTeardownSafetyTests.swift`, `DevRecoveryTests.swift` — match their
  style for new tests.

## Implementation tasks

### 1. Git repo creation helper

In `GitCheckpoint.swift` (or a small sibling), add a static/throwing helper to
create a fresh repo, reusing the existing `Process`/git-binary-resolution
plumbing style already in `GitCheckpointService` (respect `gitUnavailable`):

```swift
/// Create a new directory at `url` and `git init` it (NO initial commit).
/// Throws if the directory can't be created or git is unavailable/fails.
static func createNewProject(at url: URL) throws
```

- `FileManager.createDirectory(at:withIntermediateDirectories:true)`.
- Run `git init` with `currentDirectoryURL = url`, same env hardening as the
  existing `run(...)` (`GIT_TERMINAL_PROMPT=0`, etc.).
- Surface `gitUnavailable` consistently with the existing error enum.

### 2. Name sanitization + collision handling

Add a pure, unit-testable function that turns a user string into a
filesystem-safe folder name and resolves collisions against the parent:

- Trim; collapse internal whitespace to `-`; strip `/`, `\`, leading dots, and
  control chars; cap length (e.g. 64).
- Empty/all-invalid → return nil (caller shows an inline hint, keeps record
  disabled).
- If the NEW PROJECT folder `<location>/<slug>` already exists, append `-2`,
  `-3`, … until free.

**Important — collision is about the new project folder ONLY, never the
location.** The location (e.g. `~/Documents`) is expected to be a busy folder
full of unrelated files and other projects — that is the normal, fully-supported
case, and Zerro creates the new project as a sibling subfolder inside it
(`~/Documents/<slug>/`) without touching anything else. The ONLY thing the
collision check prevents is creating a fresh project directly on top of an
already-existing `<location>/<slug>/` (which would clobber a prior project of
the same name). Do NOT block or warn merely because the chosen location is
non-empty.

Keep this pure (takes the parent URL + raw name, returns the final URL) so it's
testable without touching disk beyond an existence check.

### 3. State (`AreaSelectorState.swift`)

- Add an inline-name field value (e.g. `var newProjectName: String`) and any
  hover/validation flags you need, following the existing patterns.
- Add `private(set) var projectIsNewlyCreated: Bool` set true when a folder was
  created via this flow (so future UI can distinguish; not load-bearing for v1).
- Reuse `setProjectURL`, `devValidationMessage`. When a project is created
  successfully, call `setProjectURL(subfolder)` then `setProjectGitRepo(true)`
  directly (we just created the repo — no need to re-probe).

### 4. Controller (`AreaSelectorWindowController.swift`)

- Reuse `presentFolderPicker` to choose the **location** (it already opens a
  directories-only `NSOpenPanel` and handles the overlay-level dance — keep that
  exactly).
- Add `createNewProject(in location: URL, name: String, state:)`:
  1. Compute the final subfolder URL via the sanitizer (task 2).
  2. `Task.detached(priority: .utility)` → `GitCheckpoint.createNewProject(at:)`
     (mirror `beginGitRepoCheck`'s off-main pattern).
  3. On success, back on `MainActor`: `state.setProjectURL(subfolder)`,
     `state.setProjectGitRepo(true)`, `preferences?.devProjectURL = subfolder`,
     set `projectIsNewlyCreated = true`.
  4. On failure: set an inline `devValidationMessage` and do **not** set a
     `projectURL`.
- Guard against stale results the same way `beginGitRepoCheck` does (re-check the
  live state on apply).

### 5. UI (`AreaSelectorView.swift`)

- In the dev panel, add a **"New project…"** affordance next to the existing
  "Change…" action in `devProjectRow`, plus an inline text field for the name.
  Match the existing styling (fonts, `Color.vf*`, row heights). Keep
  `devGitReassuranceRow` as-is — the "snapshots with git before each change —
  undo anything" copy still applies and is reassuring here.
- While a name is empty/invalid, keep the record action disabled with an inline
  hint (reuse the `devValidationMessage` mechanism). Mirror how the existing
  not-a-git-repo amber attention state is rendered.

### 6. Confirm no downstream changes

- `DevDispatchCoordinator.dispatch` and `GitCheckpointService.checkpoint()`
  should need **no** changes. Verify `.notAGitRepo` cannot fire for a
  freshly-init'd folder.
- `DevRecovery.swift` stores a `projectPath`; a created subfolder path works the
  same. Confirm recovery treats a no-commit repo the same as a pre-existing
  no-commit repo (it should — same code path).

## Misunderstanding guards (REQUIRED — prevent "new project inside an existing repo")

The risk being designed out: a user selects their existing repo, asks for an
edit, and Zerro instead creates a brand-new project nested inside it. The
structural defense is decision #6 (separate explicit gestures; intent is never
inferred from the request). Implement these concrete guards on top of it. The
detection primitive already exists — `git rev-parse --is-inside-work-tree` is run
today via `beginGitRepoCheck`, and `GitCheckpointService.isRepository()` wraps
it. Reuse it; do not invent new detection.

### Guard 1 — HARD BLOCK: refuse to create a new project inside an existing repo (REQUIRED)

In the "New project…" flow, AFTER the user picks the parent **location** and
BEFORE creating the subfolder, run an off-main repo check on that location:

- If `git rev-parse --is-inside-work-tree` is true for the chosen location, the
  location is already inside a git work tree. **Do NOT create the subfolder.**
  Set an inline `devValidationMessage` like: "This location is already inside a
  git repo. To make changes there, use 'Change folder' instead." Keep the
  record action disabled until the user picks a different location.
- Use `git rev-parse --show-toplevel` to name the offending repo root in the
  message when available (e.g. "…already inside the repo at `~/code/app`").
- Add a small reusable helper on `GitCheckpointService` for this, mirroring the
  existing `isRepository()` style, e.g.:

  ```swift
  /// The enclosing git work-tree root for `url`, or nil if `url` is not inside
  /// any git repo. Used to BLOCK creating a new project inside an existing repo.
  nonisolated func enclosingRepoRoot() -> URL?   // git rev-parse --show-toplevel
  ```

  Run it off-main (`Task.detached`), same pattern as `beginGitRepoCheck`, and
  guard against stale results by re-checking live state on apply.

**Decision to honor — nested repos:** treat Guard 1 as a **hard block** for v1
(simplest, and nested git repos are confusing/error-prone). Do NOT add an
"create nested project anyway?" override in v1. Leave a single-line `// TODO`
noting a future soft-confirm override could relax this if a real use case
appears.

### Guard 2 — Surface the parent-repo case on the NORMAL folder picker (nice-to-have, implement if low-cost)

In the existing `presentFolderPicker` / `beginGitRepoCheck` path (edit-existing),
when the picked folder IS inside a repo but is NOT the repo root
(`show-toplevel` ≠ picked path), show a non-blocking informational note on the
chip: "Part of the repo at `<root>` — changes and revert apply across that
repo." This is transparency only; it does not block. Skip if it materially
complicates the chip layout — it's the only non-required guard here.

### Guard 3 — Make the two gestures visually + verbally distinct (REQUIRED)

- The edit-existing action stays "Change folder…". The new action is a clearly
  separate **"New project…"** affordance — not a mode toggle on the same control.
  Different label, visually distinguishable.
- The new-project flow MUST show a live **path preview** of exactly what will be
  created before anything is written, e.g. `Will create: ~/Desktop/my-app/`
  (use `abbreviatingWithTildeInPath`, matching the existing chip's path styling).
  Update it as the name field changes and as collision-disambiguation applies
  (so if it resolves to `my-app-2`, the preview shows `my-app-2`). The user
  confirms a concrete path, never an inferred outcome.

### Guard 4 — Reuse the existing confirm gate as the final backstop (REQUIRED)

The dispatch already runs `confirmGate` AFTER the checkpoint and BEFORE the agent
edits anything. For a from-scratch run (when `projectIsNewlyCreated` is true),
the review surfaced through that gate must make the action explicit, e.g.
"Creating new project in `~/Desktop/my-app`". Wire the new-project context
through to whatever copy the confirm gate renders so a mistaken gesture can still
be cancelled with nothing written. Do not add a second/parallel gate — reuse the
existing one.

> Note on blast radius: even if a mistaken gesture slipped past all guards, the
> existing checkpoint + `git clean -fd` + untracked-snapshot revert restores the
> pre-run state in both directions, so committed history is never harmed. These
> guards exist to prevent confusion and wasted runs, not to prevent data loss
> (which is already handled) — but Guard 1 makes the specific "new project inside
> an existing repo" outcome impossible in the first place.

## Tests to add

Follow the existing XCTest style in `ZerroTests/`:

1. `GitCheckpoint.createNewProject(at:)` creates a valid **no-commit** repo:
   `checkpoint()` returns `baseSha == ""` and `stashSha == nil`;
   `isRepository()` is true.
2. End-to-end on a temp dir: create repo → write some files (simulate the agent)
   → `diffStat(since:)` counts them as additions → `revert(_:)` →
   directory is empty → `isRestored(to:)` is true.
3. Name sanitization: spaces→`-`, strips separators/leading dots, length cap,
   empty→nil.
4. Collision: existing `<loc>/name` yields `name-2`, then `name-3`.
5. **Guard 1:** `enclosingRepoRoot()` returns the toplevel for a path inside a
   repo and nil for a path outside any repo. Creating a new project into a
   location inside an existing repo is blocked (no subfolder created, inline
   message set, `projectURL` unchanged).
6. **Guard 3:** the path preview reflects the sanitized + collision-resolved
   final name (e.g. shows `my-app-2` when `my-app` exists).

## Acceptance criteria

- User can toggle Dev Mode, choose "New project…", pick a location, name the
  project, and Zerro creates `<location>/<name>/` with `git init`, no initial
  commit, and the folder chip shows a valid (non-amber) repo.
- Recording a request dispatches the agent into the new folder via the **existing
  unchanged** pipeline; the result card shows the scaffolded files as additions.
- One-click Revert empties the folder back to its just-created state.
- No regressions: existing "pick an already-git folder" flow is byte-for-byte
  unchanged; all existing Dev Mode tests still pass.
- `git init`/mkdir failures (permissions, missing git) surface as a clean inline
  message and never leave Dev Mode pointing at an invalid `projectURL`.
- **Choosing a location that's already inside a git repo for "New project…" is
  blocked** with a clear inline message pointing the user to "Change folder"
  instead — it is impossible to create a new project nested inside an existing
  repo (Guard 1). Whether a run edits an existing repo or creates a new project
  is determined solely by which explicit action the user took, never by the
  request text (decision #6).

## Constraints

- Don't modify the checkpoint/revert algorithms — only confirm and reuse them.
- Keep all git work off the main thread (`Task.detached`), matching existing
  patterns.
- Match existing code style, logging (`Log.dev`), analytics, and error-enum
  conventions. Add an analytics event for "dev project created from scratch" if
  there's an existing `Analytics.capture` pattern nearby.
- Build and run the test suite before declaring done.
