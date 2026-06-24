# Claude Code handoff prompt — Fix Dev Mode temp-snapshot leaks

Copy everything below the line into Claude Code, running from the repo root.

---

You are fixing two storage-leak bugs in the Zerro macOS app (`apps/desktop`,
Swift/SwiftUI, menu-bar app). Read this entire brief, then explore the referenced
files before writing any code. A companion audit with full reasoning lives at
`TEMP_STORAGE_CLEANUP_AUDIT.md` — read it first.

## Background (what already works — do NOT touch)

Normal recording artifacts (`zerro-*.mov`, `zerro-work-*/` holding frames, audio,
manifest) are reclaimed correctly by `WorkingDirectory.sweep()` at launch plus
per-session deletes. **Leave that pipeline alone.**

The bug is isolated to **Dev Mode's git-checkpoint snapshots.** Before an agent
edits a project, `GitCheckpointService` saves a copy of the project's untracked
files to `$TMPDIR/dev-checkpoint-<UUID>/` (see
`apps/desktop/Zerro/Services/Dev/GitCheckpoint.swift`, `snapshotUntracked()` ~line
454, dir created ~line 465). It also creates a throwaway git index at
`$TMPDIR/dev-ckpt-index-<UUID>`.

These are **deliberately NOT prefixed `zerro-`** (comment at `GitCheckpoint.swift`
~line 460), so `WorkingDirectory.sweep()` — which only deletes `zerro-*` entries —
never reclaims them. Their cleanup relies entirely on `discardSnapshot(_:)` being
called on every teardown, plus the durable recovery marker
(`Application Support/Zerro/dev-recovery.json`) driving
`recoverInterruptedDevCheckpointIfAny()` at next launch. Two paths break that
contract.

## Bug 1 — recovery-validation early-returns leak the snapshot dir

In `apps/desktop/Zerro/AppState.swift`, `recoverInterruptedDevCheckpointIfAny()`
(~lines 1814–1872) clears the recovery marker on several validation failures but
does **not** discard the `dev-checkpoint-*` directory the marker points at:

- **~line 1824** (project no longer exists / not a git repo): `devRecoveryStore.clear()`
  with no snapshot removal. Here the `GitCheckpointService` could not be built, so
  remove the dir directly from `marker.untrackedSnapshotPath`.
- **~line 1854** (restore ref unresolvable, OR empty diff): `devRecoveryStore.clear()`
  with no snapshot removal. Here both `service` and `checkpoint` ARE in scope, so
  call `service.discardSnapshot(checkpoint)` before clearing.

The empty-diff branch is genuinely reachable: the comment at `AppState.swift` ~line
3045 documents that a quit in the sliver after the marker is written but before the
agent edits produces a zero-diff checkpoint that lands exactly here.

Note: the **~line 1833** early-return (validate 3) only fires when the snapshot dir
is *already gone*, so it needs no change — but adding a defensive removal there is
harmless.

For reference, the correct pattern (always pair discard + clear) already exists in
`resolveDevRecovery(undo:)` at ~lines 1888 and 1906, and in `prepareForTermination`
at ~line 1520. Match that.

**Fix for Bug 1:** before each marker-clearing early-return in
`recoverInterruptedDevCheckpointIfAny()`, discard the referenced snapshot:
- where `service` + `checkpoint` exist → `service.discardSnapshot(checkpoint)`
- where they don't (project gone) → `marker.untrackedSnapshotPath.map { try?
  FileManager.default.removeItem(atPath: $0) }`

## Bug 2 — hard crash during the review gate leaks an unreferenced snapshot

The snapshot dir is created when the checkpoint is taken, but the recovery marker is
only persisted at the `.dispatching` phase, **after** the Ask-Permission review gate
(`AppState.swift` ~line 3049, `persistDevRecoveryMarker()`). A clean ⌘Q during review
is already handled (`prepareForTermination` `.reviewingPrompt` case discards it,
~line 1520). But a **SIGKILL / hard crash** while the user sits at the review gate
leaves a `dev-checkpoint-<UUID>/` dir with **no marker pointing at it** — unreferenced,
not `zerro-`-prefixed, so nothing ever reclaims it except the OS temp purge.

**Fix for Bug 2 (preferred — also backstops Bug 1 and the stray `dev-ckpt-index-*`):**
add a launch-time, **marker-aware** sweep of orphaned Dev Mode temp dirs.

Implementation guidance:
1. Add a function (suggest `GitCheckpointService.sweepOrphanedSnapshots(keeping:)`,
   or a small static helper near `WorkingDirectory`) that scans `$TMPDIR` and deletes
   every entry whose name starts with `dev-checkpoint-` or `dev-ckpt-index-`, EXCEPT
   a single path to keep. Best-effort, log + ignore failures (mirror
   `WorkingDirectory.sweep`'s error handling).
2. Derive the `keeping:` path from the persisted marker: `devRecoveryStore.load()?
   .untrackedSnapshotPath`. This is the only snapshot that may still be needed (the
   pending cross-launch recovery offer). `dev-ckpt-index-*` is never marker-referenced,
   so it's always safe to delete.
3. Call it **once at launch only**, and **after**
   `recoverInterruptedDevCheckpointIfAny()` has loaded the marker, so the sweep can't
   race the recovery offer. Wire it alongside the existing launch recovery in
   `ZerroApp.swift` (~lines 255–258) or just after the dev-recovery step in AppState.
   Do NOT run it on the wake path (the running app may hold a live snapshot) — gate it
   the same way `sweepIfLaunch` restricts to `.launch` (`AppState.swift` ~line 1754).

Do **not** simply rename the dirs to a `zerro-` prefix to let the existing sweep catch
them unless you first confirm `WorkingDirectory.sweep()` can never run while a live Dev
Mode checkpoint exists. The original code avoided the prefix for that reason; the
marker-aware sweep above sidesteps the concern.

## Constraints

- Keep all deletes best-effort and non-load-bearing (cleanup failures must never
  surface an error to the user or block launch), consistent with the existing
  `WorkingDirectory.remove` / `sweep` style.
- Don't change recording/frame/manifest cleanup, the `zerro-` sweep, or the
  recovery UX/offer logic — only close the leak.
- Preserve the existing behavior that a *valid* pending recovery marker's snapshot
  survives to be offered on next launch.

## Verification (required)

1. `xcodebuild` (or the project's build command) succeeds; no new warnings in the
   touched files.
2. Add/extend unit tests under `apps/desktop/ZerroTests` (there are existing Dev Mode
   / GitCheckpoint tests — follow their patterns and any temp-dir test helpers):
   - **Bug 1, empty-diff path:** a saved marker + an existing `dev-checkpoint-*` dir,
     recovery validation hits the empty-diff/unresolvable-ref early-return → assert the
     marker is cleared AND the snapshot dir no longer exists on disk.
   - **Bug 1, project-gone path:** marker points at a now-missing project →
     assert the snapshot dir referenced by `untrackedSnapshotPath` is removed.
   - **Bug 2, marker-aware sweep:** create two `dev-checkpoint-*` dirs and one
     `dev-ckpt-index-*` in a temp location; persist a marker pointing at ONE of the
     dirs; run the sweep → assert the marker's dir survives and the others are gone.
   - **Regression:** a valid pending marker is NOT swept (its snapshot survives launch).
3. Manual smoke (if feasible): start a Dev Mode run, force-kill at the review gate,
   relaunch → confirm no `dev-checkpoint-*` accumulates in `$TMPDIR`.

## Deliverable

Make the code changes, add the tests, run the build + tests, and summarize: which
files changed, the exact discard calls added in `recoverInterruptedDevCheckpointIfAny()`,
where the new sweep lives and where it's invoked, and the test results.
