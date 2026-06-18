# Claude Code handoff — Dev Mode quit-mid-dispatch recovery

Close the last "could lose work" path. Today, if the user **quits while a Dev
Mode dispatch is in flight** (the agent is mid-edit), `prepareForTermination`
already kills the agent and **deliberately keeps the git checkpoint snapshot on
disk** (`AppState.swift` ~1349, the `.devCheckpointing/.devAgentDispatching/
.devAgentRunning` branch — the comment says "KEEP the snapshot on disk for a
future quit-recovery (tracked follow-up)"). But nothing on the **next launch**
knows that snapshot exists, so the user is left with half-applied edits and no
one-click undo. The data is recoverable; the *affordance* isn't.

Wire that affordance: **persist a recovery marker when a dispatch starts**,
**detect + validate it at next launch**, and **offer an Undo/Keep pill** that
reuses the already-verified `GitCheckpointService.revert`.

App-only (Swift). No backend, no billing. Build + test, then **STOP for review +
the manual kill test** (Part 6).

## Read first
- `AppState.swift`:
  - `prepareForTermination()` (~1336) — the quit router. The in-flight-dispatch
    branch (~1349) already keeps the snapshot; the `.confirmAnchors` branch
    (~1358) discards it (agent never ran). **Don't change the keep/discard
    decisions** — just add marker writes/clears around them.
  - the session teardown/reset (the method ~1175–1232 that nils
    `devCheckpoint`/`devCheckpointService`, calls `discardSnapshot` ~1211, and
    `pendingPaidStore.clear()` ~1231) — the **single point** where a live
    checkpoint is torn down on every non-quit path (cancel, dismiss, reset,
    revocation). Clear the marker here too.
  - `beginDevDispatch` / the transition **past the `confirmAnchors` gate into the
    agent launch** — where you WRITE the marker (see Part 2).
  - the Undo/revert success path (~3057–3072, `service.discardSnapshot(checkpoint)`)
    — clear the marker here too.
  - `recoverOrphanedRecordingIfAny(trigger:)` (~1551) + `resolveRecovery(generate:)`
    (~1607) — the **recording-recovery pattern to mirror** (launch scan → gate on
    `state == .idle` → set a `pending…` + enter a `.confirming…` state → resolve).
  - `pendingPaidStore` — the existing tiny persisted-pointer store to model
    `DevRecoveryStore` on.
- `Services/Dev/GitCheckpoint.swift` — `GitCheckpoint` is plain `Sendable` data
  (`baseSha`, `stashSha?`, `untrackedSnapshotDir: URL?`, `untrackedRelativePaths`,
  `restoreRef`); `GitCheckpointService(projectURL:)` re-resolves git from the
  folder alone; `revert`, `diffStat(since:)`, `discardSnapshot`, `isRepository()`
  are all there. **Nothing new needed here** — the checkpoint is fully
  reconstructable from persisted fields + `projectURL`.
- `Surfaces/Pill/PillView.swift` — `ConfirmRecoveryPillContent` (the recording
  recovery pill) is the chrome to clone for the dev-recovery pill.

## Ground rules
- **Non-destructive by default.** Only ever offer recovery when a revert is
  provably safe (Part 3 validation). If anything is stale/missing, **clear the
  marker and don't offer** — never do a partial revert that could delete
  un-restorable untracked files. Keeping the user's edits is the safe failure.
- Reuse `GitCheckpointService.revert` verbatim — do **not** write a second revert.
- BYOK and managed are identical here (the checkpoint/dispatch tail is shared), so
  this covers both paths with one implementation.
- Normal-mode + the existing recording-recovery flow stay byte-identical.

## Part 1 — the marker + a durable store
Add a `Codable` marker capturing exactly what reconstructs the checkpoint:
```swift
struct DevRecoveryMarker: Codable, Equatable {
    var projectPath: String           // GitCheckpointService(projectURL:)
    var baseSha: String
    var stashSha: String?
    var untrackedSnapshotPath: String? // the dev-checkpoint-* dir
    var untrackedRelativePaths: [String]
    var createdAt: Date
    var agentName: String?            // optional, for the pill copy
}
```
Reconstruct via `GitCheckpoint(baseSha:stashSha:untrackedSnapshotDir:
untrackedRelativePaths:)` (URLs from the path strings) + `GitCheckpointService(
projectURL: URL(fileURLWithPath: projectPath))`.

`DevRecoveryStore` (mirror `pendingPaidStore`): `save(_:)`, `load() -> DevRecoveryMarker?`,
`clear()`. **Durability matters** — the marker must survive an *abrupt* kill, not
just ⌘Q. Either write an **atomic JSON file** under Application Support
(`…/Zerro/dev-recovery.json`, `Data.write(options: .atomic)`) — preferred for
`kill -9` durability — or UserDefaults **with an explicit `synchronize()`** right
after save. (⌘Q runs `prepareForTermination` and exits cleanly, so UserDefaults
would flush anyway; the file is only stricter for the hard-kill case in the
manual test.)

## Part 2 — write the marker at dispatch start; clear it at every teardown
- **Write:** the instant the agent is first allowed to edit — i.e. **after the
  `confirmAnchors` gate resolves to proceed and before the coordinator launches
  the agent** (in `beginDevDispatch`/the dispatch entry), once `devCheckpoint` +
  `devCheckpointService` are set. Persist `DevRecoveryStore.save(marker)` there.
  Writing it a hair before the first edit is harmless (a quit in that sliver →
  recovery reverts a zero-diff checkpoint → no-op).
  - **Critically, write it AFTER the gate**, so the `.confirmAnchors` state never
    has a marker — its quit branch (~1358) discards the snapshot, and we must not
    leave a marker pointing at a discarded snapshot.
- **Clear:** wherever a live checkpoint is torn down —
  - the session teardown/reset (~1211/1224): add `DevRecoveryStore.clear()` next
    to the existing `discardSnapshot` / `pendingPaidStore.clear()`;
  - the Undo/revert success (~3072): clear after `discardSnapshot`.
  Net rule: **the marker's lifetime mirrors `devCheckpoint`'s, but survives
  process death.** It persists through `.devDone`/`.devFailed` (checkpoint still
  alive → a quit there is still recoverable) and is gone the moment the user
  accepts/dismisses/cancels/reverts.
- Defensive: in `prepareForTermination`'s `.confirmAnchors` branch, you may also
  call `DevRecoveryStore.clear()` (belt-and-suspenders; there shouldn't be one).

## Part 3 — detect + VALIDATE at launch
Add `recoverInterruptedDevCheckpointIfAny()`, called on the **launch** path
(alongside `recoverOrphanedRecordingIfAny`), gated on `state == .idle`. The
launch `WorkingDirectory.sweep()` won't touch the snapshot (it's `dev-checkpoint-*`,
not `zerro-*`). Order: **dev-recovery first** — it restores real source files
(higher stakes); if it makes an offer, skip the recording scan this launch (the
recording orphan re-offers next launch). If no dev marker, fall through to the
existing recording recovery unchanged.

Load the marker, reconstruct checkpoint+service, then **validate — offer only if
ALL hold**, else `DevRecoveryStore.clear()` and return (no offer):
1. `projectPath` exists on disk and `service.isRepository()` is true.
2. `restoreRef` still resolves — `git rev-parse --verify "<restoreRef>^{commit}"`
   succeeds (the dangling `stash create` commit wasn't GC'd). Computing
   `diffStat(since:)` doubles as this check — run it off-main.
3. If `untrackedSnapshotPath` is non-nil, the directory still exists. If it's gone
   (e.g. a reboot cleared `$TMPDIR`), **do not offer** — a revert would
   `clean -fd` pre-existing untracked files it can't restore. Clearing + keeping
   the edits is the safe outcome.
4. The diffStat is non-empty (the agent actually changed tracked files before the
   quit). Zero diff → nothing to undo → clear, no offer.

On success: stash the reconstructed `(checkpoint, service, diffStat, agentName)`
in a `pendingDevRecovery`, set `state = .confirmingDevRecovery`, and
`Analytics.capture("dev_recovery_offered", [...])` (mirror `recovery_offered`).

## Part 4 — the recovery state + pill
- Add `case confirmingDevRecovery` to the state enum. Audit the `switch`es that
  must stay exhaustive — at minimum give `prepareForTermination` an arm for it
  (terminal/idle-like: the agent already exited; nothing to tear down — leave the
  marker so it re-offers next launch) and any sweep/idle guards (it is NOT idle —
  recovery/recording scans must no-op while it's showing, exactly like
  `.confirmingRecovery`).
- Clone `ConfirmRecoveryPillContent` → a dev variant: title "Dev Mode change
  interrupted", a one-line body using the diffStat ("Undo the unfinished change?
  +x −y in N files") and `agentName` if present, with **two buttons: Undo**
  (destructive/red — reuses the result-card Undo treatment) and **Keep** (neutral).
  Route `.confirmingDevRecovery` in `PillView` to it.

## Part 5 — resolve
`resolveDevRecovery(undo: Bool)` (mirror `resolveRecovery`), no-op outside
`.confirmingDevRecovery`:
- **Undo:** run `try service.revert(checkpoint)` **off-main** (it shells out to
  git); on success → `discardSnapshot` + `DevRecoveryStore.clear()` +
  `state = .idle` + `Analytics.capture("dev_recovery_undone")`. On revert failure:
  surface a brief non-blocking error (reuse the dev failure copy), still clear the
  marker (a stale checkpoint won't get healthier on retry) → `.idle`.
- **Keep / dismiss:** `discardSnapshot` + `DevRecoveryStore.clear()` +
  `state = .idle` + `Analytics.capture("dev_recovery_kept")`. (Dismissing the pill
  routes here as Keep — never leave the marker on disk once the user has engaged.)

## Tests
- `DevRecoveryMarker` Codable round-trip; `DevRecoveryStore` save/load/clear
  (isolated suite / temp file — no global UserDefaults bleed).
- Validation matrix → offered vs cleared: missing project, non-repo,
  unresolvable `restoreRef`, missing untracked snapshot dir, zero diff. Each
  non-happy case must **clear and not offer**.
- State machine: a seeded valid marker at launch → `.confirmingDevRecovery`;
  `resolveDevRecovery(undo:true)` calls `revert` + clears + `.idle`;
  `undo:false` keeps (no revert) + clears + `.idle`.
- Guard: marker is written only after the confirm gate (a `.confirmAnchors` quit
  leaves NO marker); the teardown/reset clears it.

## Part 6 — manual verification (STOP for review)
1. Start a Dev Mode dispatch on a localhost git project; while the agent is
   editing, **hard-quit** (`kill -9` the app, or ⌘Q mid-run).
2. Relaunch → the **Dev Mode change interrupted** pill appears with the right
   diff stat. **Undo** → working tree returns to exactly the pre-run state
   (`git status` clean of the agent's edits; pre-existing uncommitted + untracked
   work intact). Relaunch again → no pill (marker cleared).
3. Repeat → **Keep** → edits remain; no pill on the next launch.
4. Negative: quit at the `confirmAnchors` gate (agent never ran) → next launch
   shows **no** pill (no marker; snapshot was discarded).

## Acceptance criteria
- Quitting mid-dispatch (clean ⌘Q **and** `kill -9`) leaves a durable marker;
  next launch offers an Undo/Keep pill; **Undo** restores the tree via the
  existing `revert`; **Keep** retains edits. Marker cleared after either.
- Recovery is offered **only** when the revert is provably safe; every stale/
  missing case clears the marker and keeps the user's edits (never a partial
  revert).
- No marker is ever left pointing at a discarded snapshot (`.confirmAnchors`
  quit, and every normal teardown, clear it).
- Recording recovery, normal mode, and all existing teardown paths unchanged;
  build + tests green.

## Notes
- This finishes the Dev Mode safety model: cancel (live), dismiss/accept,
  in-session Undo, and now **cross-launch** Undo all reuse the one verified
  `GitCheckpointService.revert`.
- The stash commit is a dangling object — fine for a next-launch offer (git's
  default ~2-week unreachable grace), and Part 3 step 2 guards the GC'd case.
- Out of scope (Phase 3+): non-git temp-dir fallback, review-before-apply. Quit
  recovery only needs to handle the git-checkpoint path that exists today.
