# Dev Mode — Create a Project From Scratch

> Status: design / planning. Lets a user start a brand-new project in Dev Mode
> from an empty location (e.g. "make me this website" while pointing at their
> Desktop), instead of requiring a folder that's already a git repo.

## 1. Why this is feasible (and mostly already built)

The Dev Mode safety model is checkpoint → agent edits → one-click revert
(`GitCheckpoint.swift`, design §4). The important finding: **the checkpoint /
revert machinery already supports a repo with no commits yet.**

In `GitCheckpoint.swift`:

- `baseSha` is documented as the empty string "for a repo with no commits yet
  (fresh `git init`)".
- `restoreRef` falls back to git's well-known **empty tree**
  (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`) when there's no base commit.
- `revert()` has an explicit `hasBaseCommit == false` branch: it skips
  `git checkout` (the empty tree has no paths), runs `git reset -q`,
  `git clean -fd`, and restores the untracked snapshot — netting the working
  tree back to **empty**.

So if the agent scaffolds a fresh project into an empty `git init`'d folder, the
existing Revert wipes it back to nothing. The hard engineering is done.

What blocks the from-scratch gesture today is **two product gates, not a safety
gap**:

1. `AreaSelectorWindowController.presentFolderPicker` → `beginGitRepoCheck`
   flags any non-git folder with an amber "not a git repo" attention chip.
2. `DevDispatchCoordinator.dispatch` → `GitCheckpointService.checkpoint()` →
   `verifyRepository()` throws `.notAGitRepository` for a non-repo folder,
   surfaced as `DevDispatchFailure.notAGitRepo`
   ("Dev Mode needs a git repo — pick a folder that's inside one.").

The feature is: **let the user create a new named subfolder in a chosen
location, `git init` it for them, and let the existing pipeline take over.**

## 2. Key safety decision — new project = new SUBFOLDER

The user gesture is "pick a location (Desktop) and make me a project." We must
**not** `git init` the chosen location directly and let the agent scaffold into
it, because:

- Revert's `git clean -fd` would then operate on the chosen location's root. If
  that's the Desktop, an over-eager clean (or a bug) could touch unrelated user
  files sitting on the Desktop.
- A `.git` appearing at `~/Desktop/.git` is a surprising, hard-to-find artifact.

**Decision (chosen): always create a new named subfolder.** Zerro creates
`<chosen-location>/<project-name>/`, runs `git init` inside *that* subfolder,
and sets `projectURL` to the subfolder. Every downstream operation — checkpoint,
agent cwd, diff, revert, `git clean -fd` — is already scoped to `projectURL`, so
the blast radius is strictly the new subfolder. The parent location is never
touched.

## 3. Naming — ask the user inline (chosen)

A small text field in the dev panel lets the user name the project before
dispatch. Predictable, user-controlled names; no awkward inference from a spoken
request. Rules:

- Sanitize to a filesystem-safe slug (trim, collapse whitespace → `-`, strip
  path separators and leading dots).
- If `<location>/<name>` already exists, either disambiguate
  (`name-2`, `name-3`, …) or surface an inline "folder already exists" note and
  block dispatch until resolved. (Disambiguate is the smoother default.)
- Empty / all-invalid name → keep the record button disabled with an inline hint
  (mirror the existing `devValidationMessage` pattern).

## 4. Permissions — unchanged (chosen)

From-scratch runs flow through the **existing** `DevAgentPermission` /
`confirmGate` path with no new autonomy. The agent may need to run several shell
commands to scaffold (e.g. a framework's create command, dependency install).
That's the same approval surface as today — consistent and safe. If first-run
friction proves high later, a "looser inside the fresh folder" mode can be a
follow-up (the folder is fully revertible, so it's a reasonable future lever),
but it is **out of scope for v1**.

## 5. Flow

```
User toggles Dev Mode
  └─ chooses "New project…" (new affordance on the folder row)
        ├─ picks a parent LOCATION (NSOpenPanel, directories only)   ← reuse presentFolderPicker
        └─ types a project NAME (inline field)                       ← new
  └─ Zerro:
        1. mkdir <location>/<slug>            (disambiguate on collision)
        2. git init <location>/<slug>
        3. setProjectURL(subfolder)          → chip shows valid repo, NO amber
  └─ User records the request as normal ("build me a landing page that …")
  └─ Existing pipeline runs UNCHANGED:
        checkpoint() (no-commit branch) → agent scaffolds into the empty repo
        → diffStat (all untracked, already handled) → result card
  └─ Revert: existing no-base-commit branch → git clean -fd + untracked restore
        → folder is empty again. (Optionally also rmdir the created folder —
          see edge cases.)
```

The only genuinely new code is steps 1–3 plus the UI to drive them. Everything
after `setProjectURL` is the existing path.

## 6. Where the code lands

- **`AreaSelectorWindowController.swift`**
  - `presentFolderPicker(...)` — reuse for picking the *location*. Add a sibling
    `createNewProject(in:name:)` that does mkdir + `git init` + `setProjectURL`.
    The git-init runs off-main (mirror `beginGitRepoCheck`'s `Task.detached`).
  - After `git init` succeeds, the existing `beginGitRepoCheck` will correctly
    report `isRepo == true`, so the chip clears its amber state with no special
    casing — but we can skip the probe and call `setProjectGitRepo(true)`
    directly since we just created the repo.
- **`AreaSelectorState.swift`**
  - Add state for the inline name field + a `projectIsNewlyCreated` flag (lets
    the result/revert UI optionally offer "delete the folder too").
  - Reuse `setProjectURL`, `setProjectGitRepo`, `devValidationMessage`.
- **`AreaSelectorView.swift`**
  - In `devProjectRow` (and/or an expanded dev panel), add a "New project…"
    action and the name text field. Keep the existing `devGitReassuranceRow`
    copy — it still applies.
- **`GitCheckpoint.swift` / `DevDispatchCoordinator.swift`** — **no changes
  required.** The no-commit path already exists. (Verify with the existing
  `DevModeTeardownSafetyTests` / `GitCheckpointTests` / `DevRecoveryTests`.)
- **`PreferencesStore.swift`** — `devProjectURL` already persists last-used; the
  new subfolder writes through the same setter.

## 7. `git init` mechanics

Run via the same `Process` plumbing style as `GitCheckpointService.run` (or add
a tiny `GitCheckpointService.initRepository(at:)` static):

```
git init                         # in the new subfolder
# optionally: git commit --allow-empty -m "init"   ← see decision below
```

**Empty initial commit — decide explicitly.** Two viable bases:

- **No initial commit (recommended for v1):** matches the already-tested
  `hasBaseCommit == false` path exactly. `baseSha == ""`, revert uses
  empty-tree + clean. Zero new behavior to validate.
- **One empty initial commit:** gives a real `HEAD`, so the *general* checkpoint
  path runs instead of the special-case branch. Slightly "cleaner" git history,
  but exercises a different code path and adds a commit the user didn't ask for.

Recommend **no initial commit** for v1 — it's the path your tests already cover.

## 8. Edge cases & guards

- **Two distinct folders — don't conflate them.** The **location** is the parent
  the user picks (Documents, Desktop, …). It is EXPECTED to be full of unrelated
  files and projects; Zerro never writes into it directly or touches anything
  already in it. The **project folder** is the NEW subfolder Zerro creates inside
  it (`<location>/<name>/`) — that's the only thing `git init`'d and scoped for
  revert.
- **Picking a busy location (e.g. Documents) is fully supported.** A user
  choosing `~/Documents` (which already holds many files/projects) is the normal
  case: Zerro just creates `~/Documents/<name>/` alongside everything else. The
  parent's existing contents are irrelevant and untouched.
- **Collision** is ONLY about the new project folder's PATH, not the location:
  if `<location>/<name>/` already exists, don't create a fresh project on top of
  it — disambiguate the name to `name-2`, `name-3`, … (or, alternatively, show
  an inline "that name's taken here" note and let the user rename). The path
  preview (Guard 3) reflects the resolved name.
- **Permission denied at location:** mkdir/`git init` can fail (sandbox,
  read-only volume). Surface an inline failure on the chip; do not enter Dev
  Mode with an invalid `projectURL`.
- **`git` unavailable:** reuse the existing `.gitUnavailable` handling —
  `GitCheckpointService` init already throws it; surface before recording.
- **Revert of a from-scratch run:** existing no-base-commit revert empties the
  folder. **Decision:** should Revert also remove the now-empty created folder?
  - *Keep folder:* simplest, matches "revert = restore working tree" semantics.
    The empty folder + `.git` remain. (Recommended for v1.)
  - *Remove folder:* nicer "undo the whole project creation" feel, but Revert
    today never deletes the project root — making it do so for this one case is
    a new, riskier behavior. Defer.
- **Abandoned empty folders:** if the user creates a project but never records /
  cancels, an empty `<name>/.git` is left behind. Acceptable for v1; a future
  sweep could clean unused freshly-created empties.
- **Recovery (`DevRecovery.swift`):** the recovery marker stores `projectPath`;
  a freshly-created subfolder path works the same as any other. Confirm the
  recovery flow treats a no-commit repo correctly (it should — same path as a
  pre-existing no-commit repo).

## 9. Test additions

- `GitCheckpointService.initRepository(at:)` creates a valid no-commit repo;
  `checkpoint()` on it returns `baseSha == ""`, `stashSha == nil`.
- End-to-end: init empty repo → write files (simulate agent) → `diffStat` counts
  them as additions → `revert` → folder is empty → `isRestored` true.
- Name sanitization + collision disambiguation unit tests.
- Picking a location and creating a subfolder sets `projectURL` to the subfolder
  and clears the amber not-a-repo state.

## 10. Out of scope for v1

- Looser/auto-approve scaffold permissions.
- Inferring the project name from the spoken request.
- Deleting the project folder on Revert.
- Templates / framework presets for the new project.
