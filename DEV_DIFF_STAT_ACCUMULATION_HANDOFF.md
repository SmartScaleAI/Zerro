# Handoff: Dev Mode pill diff stat accumulates uncommitted changes across runs

## Symptom

The "Changes applied (+N −0)" pill (Dev Mode result card) shows the diff for **all
uncommitted changes in the working tree since the last commit**, not just the edits
the agent made during the single prompt that was just dispatched.

User-reported behavior, verbatim: *"It just keeps accumulating all the git changes
that you do if you didn't commit the previous changes."*

So: run prompt A → Accept (but don't `git commit`) → run prompt B. Prompt B's pill
shows A's lines **plus** B's lines, instead of only B's. Each subsequent
uncommitted run keeps adding to the count. A real screenshot showed `+4828 −0`.

**Intended behavior:** the pill must show **only the current run's edits.** All
pre-existing uncommitted work (from earlier accepted-but-uncommitted runs, or the
user's own manual edits) is the *base* and must NOT be counted.

## Root cause (diagnosis to confirm first)

The diff base for a run is `GitCheckpoint.restoreRef`:

```
var restoreRef: String { stashSha ?? (hasBaseCommit ? baseSha : Self.emptyTreeSha) }
```

`stashSha` comes from `git stash create` in `GitCheckpointService.checkpoint()`
(`apps/desktop/Zerro/Services/Dev/GitCheckpoint.swift`). `stash create` snapshots
the **current tracked + dirty tree** into a dangling commit — that snapshot is the
correct per-run base, because it already includes all prior uncommitted work.

When `stashSha` is captured correctly, the diff is right. Verified empirically on a
clean clone of this repo:

- Dirty tracked file present → `git stash create` returns a SHA → `git diff --numstat <sha>`
  reports **0 added / 0 removed** (the pre-existing edit is the base, not counted). ✅
- Same tree, but diffing against `HEAD` → reports the pre-existing edit as **+1 −0**. ❌

So the bug is: **`stashSha` is ending up `nil`, so `restoreRef` falls back to `HEAD`,
and every uncommitted change since the last commit gets counted as part of "this run."**
The all-additions / zero-removals shape (`−0`) is the tell — diffing a dirty tree
against HEAD reads pre-existing modifications largely as additions.

`stashSha` becomes nil on two paths in `checkpoint()`:

1. **`stash create` returns empty output** → treated as "clean tree" → fall back to
   HEAD. This is correct ONLY when the tree truly is clean. Confirm whether it is
   returning empty on a dirty tree (it should not).

2. **The repo has a stale `.git/index.lock`.** Reproduced live in this repo during
   investigation: `git stash create` failed with
   `fatal: Unable to create '.../.git/index.lock': File exists`. With
   `GIT_OPTIONAL_LOCKS=0` set (line ~434) and the empty-output fallback, a failed/empty
   `stash create` can collapse the base to HEAD instead of surfacing as
   `.checkpointFailed`. A leftover lock (from an interrupted agent/git run) then makes
   EVERY subsequent run silently diff against HEAD → continuous accumulation that
   matches the user's description exactly.

**Confirm the exact path before fixing:** add temporary `Log.dev` lines in
`checkpoint()` recording (a) whether `rev-parse HEAD` succeeded, (b) the raw
`stash create` stdout/stderr/exit status, (c) the resolved `stashSha`, and
(d) the final `restoreRef`. Reproduce by: making an edit, accepting without
committing, then running a second prompt — and separately by leaving a
`.git/index.lock` in place. Capture which branch produces the inflated count.

## Fix

Goal: `restoreRef` must reflect the **actual pre-run working-tree state** on every
run, so the per-run diff excludes all pre-existing uncommitted work. Specifically:

1. **Do not silently fall back to HEAD when `stash create` fails.** In
   `checkpoint()` (around lines 151–158), `git stash create` currently runs WITHOUT
   `allowFailure`, so a hard failure throws → `.checkpointFailed`. But verify the
   empty-output case: empty stdout is only legitimately "clean tree" when the exit
   status is 0. If `stash create` exits non-zero (e.g. index lock) it must NOT be
   read as "clean" → it should surface a real error, not degrade to HEAD.

2. **Detect and recover from a stale `.git/index.lock`.** There is already an
   `indexLocked` error + a user-facing one-line fix message
   (`DevDispatchFailure.indexLocked`, `GitCheckpointError.indexLocked`,
   `isIndexLockFailure`). Make sure `stash create`'s failure routes through
   `isIndexLockFailure` so the user gets the actionable "run `rm -f .git/index.lock`"
   message rather than silently producing a wrong (HEAD-based) diff. Consider
   detecting a stale lock proactively at checkpoint time and surfacing `.indexLocked`
   before attempting the snapshot. (Do NOT auto-delete the lock — a live git process
   could legitimately hold it; surface the fix to the user.)

3. **Harden the "clean tree" decision.** Only treat `stash create` empty output as
   "clean" when the command exited 0 AND there are no staged/unstaged tracked changes
   (cross-check with `git diff --quiet` / `git diff --cached --quiet`). If there ARE
   tracked changes but `stash create` produced no SHA, that's an anomaly — error out
   rather than diff against HEAD.

4. **Verify the untracked intent-to-add path is symmetric.** In
   `diffIncludingUntracked` (lines ~277–295), the `add --intent-to-add` /
   `reset` dance must not leak into the count or the index. Confirm the scoped
   `reset` runs even when the diff throws (the `defer` already does this) and that a
   stale lock can't leave intent-to-add entries staged across runs (which would
   inflate the NEXT run's base/diff).

## Acceptance criteria / tests

Add to `apps/desktop/ZerroTests/GitCheckpointTests.swift` (this suite already exists
and exercises `GitCheckpointService` against temp repos):

1. **Accumulation regression (the core bug):** init a temp repo with a commit →
   modify a tracked file (simulating an accepted-but-uncommitted prior run) → take a
   checkpoint → make a *further* small edit (the "current run") → assert `diffStat`
   counts **only the current run's lines**, not the pre-existing modification.
   (Today this would over-count.)

2. **Dirty-tree base is the stash snapshot, not HEAD:** assert that on a dirty tree,
   `checkpoint().stashSha != nil` and `restoreRef` resolves to the stash SHA, never
   HEAD.

3. **Stale index lock:** create `.git/index.lock` in the temp repo → assert
   `checkpoint()` throws `.indexLocked` (or surfaces it) rather than returning a
   checkpoint whose `restoreRef` is HEAD. Assert the dispatch maps it to
   `DevDispatchFailure.indexLocked` with the existing fix-it message.

4. **Genuinely clean tree still works:** clean tree → `stashSha == nil`,
   `restoreRef == HEAD`, `diffStat == .zero`. (No regression to the clean path.)

5. **Untracked-only / no-commit repo unchanged:** the existing fresh-`git init`
   (empty-tree base) behavior must still pass.

Also run the full `ZerroTests` suite (esp. `DevRecoveryTests`,
`DevResultChargeLineTests`) — the checkpoint/diff is load-bearing for quit-recovery
and the result card.

## Key files

- `apps/desktop/Zerro/Services/Dev/GitCheckpoint.swift` — `checkpoint()`,
  `restoreRef`, `diffStat(since:)`, `diffIncludingUntracked`, `isIndexLockFailure`.
  Primary fix site.
- `apps/desktop/Zerro/Services/Dev/DevDispatchCoordinator.swift` — calls
  `diffStat(since: checkpoint)` (lines ~271–284); maps errors to
  `DevDispatchFailure`.
- `apps/desktop/Zerro/AppState.swift` — consumes `success.diff`, persists the
  checkpoint, recovery path (lines ~3203–3235, ~1784–1814).
- `apps/desktop/ZerroTests/GitCheckpointTests.swift` — add the tests above.

## Out of scope / guardrails

- Do NOT change the Revert/`isRestored` semantics — they intentionally do NOT use
  `diffStat == 0` (a valid checkpoint can have untracked files). The fix is about the
  diff **base**, not the restore logic.
- Do NOT auto-delete `.git/index.lock`.
- Keep the no-initial-commit (empty-tree) path intact.
- Remove the temporary diagnostic logging before finalizing (or gate it behind an
  existing debug flag).
