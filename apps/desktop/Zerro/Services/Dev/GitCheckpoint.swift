//
//  GitCheckpoint.swift
//  Zerro
//
//  Dev Mode safety model (design §4): before the agent edits the working tree,
//  snapshot the EXACT pre-run state so a one-click Revert can restore it —
//  tracked, dirty (uncommitted), AND untracked work — without polluting branch
//  history.
//
//  Mechanics:
//    • checkpoint(): capture tracked + index state with `git stash create`
//      (returns a commit SHA WITHOUT touching the working tree or the stash
//      list; empty when the tree is clean → fall back to HEAD). Separately copy
//      untracked files aside, since stash-create omits them.
//    • The agent then edits the working tree directly.
//    • revert(): restore tracked files from the snapshot commit, remove the
//      files the AGENT created (a `git clean` scoped to agent-added untracked
//      paths only — never the user's pre-existing untracked work — which still
//      respects .gitignore so build dirs survive), then copy the saved untracked
//      files back. Net: the working tree returns to exactly the pre-run state;
//      the user's uncommitted work is intact; branch history is untouched.
//      CRASH-SAFE (G-01): the order + scope guarantee that a throw at ANY step
//      cannot leave the user's pre-existing untracked work deleted-and-
//      unrecoverable — a pre-flight check aborts before any destructive step if
//      the untracked snapshot is missing, and `clean` never targets the user's
//      pre-existing untracked set. Combined with the caller retaining the
//      checkpoint until a VERIFIED restore, a failed revert is always retryable.
//
//  All git invocations run with `cwd = projectURL`. Phase 1 REQUIRES a git repo
//  (design §4); a non-git project throws `.notAGitRepository`, surfaced to the
//  user as "Dev Mode needs a git repo".
//

import Foundation
import os

// MARK: - Errors

enum GitCheckpointError: Error, Equatable, Sendable {
    /// The project folder isn't inside a git work tree (Phase 1 requires one).
    case notAGitRepository
    /// `git` couldn't be located on disk.
    case gitUnavailable
    /// git couldn't write the index — almost always a stale `.git/index.lock`
    /// left by an interrupted git/agent process (the lock blocks every later
    /// index write until removed). Distinct from `commandFailed` so the UI can
    /// give the one-line fix (`rm -f .git/index.lock`) instead of a generic
    /// "couldn't snapshot" message.
    case indexLocked
    /// A git invocation exited non-zero. `stderr` is the trimmed tail.
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    /// A filesystem step (untracked snapshot copy/restore) failed.
    case fileOperationFailed(String)
}

// MARK: - Checkpoint value

/// The captured pre-run state. Plain data so it can be stored alongside the
/// recording and used later by Revert (Milestone 7).
struct GitCheckpoint: Equatable, Sendable {
    /// HEAD at checkpoint time — the restore base when the tree was clean
    /// (no stash commit was produced). EMPTY STRING for a repo with no commits
    /// yet (fresh `git init`): there is no HEAD to resolve, so the pre-run state
    /// is purely the untracked snapshot and the restore base is the empty tree.
    let baseSha: String
    /// The `git stash create` commit capturing tracked + dirty state, or nil
    /// when the working tree was clean OR the repo has no initial commit (stash
    /// create needs a HEAD, so it's skipped on an empty repo).
    let stashSha: String?
    /// A tree object capturing the ENTIRE pre-run working tree — tracked, dirty
    /// AND untracked (ignored files excluded) — written via a throwaway index at
    /// checkpoint time. This is the base the per-run DIFF is computed against.
    ///
    /// `stashSha` is unsuitable as the diff base because `git stash create` NEVER
    /// captures untracked files: a file an earlier accepted-but-uncommitted run
    /// left behind (or any of the user's own uncommitted work) would be diffed
    /// against a base that lacks it and re-counted as a brand-new addition on
    /// every subsequent run — the "+N −0" accumulation bug. Diffing against this
    /// full-tree snapshot makes all pre-existing work the base, so the pill shows
    /// ONLY the current run's edits.
    ///
    /// nil only when the snapshot couldn't be written (the diff then degrades to
    /// `restoreRef`, i.e. the old behavior). `stashSha` is still captured for
    /// REVERT (see `restoreRef`) — that path is unchanged.
    let diffBaseSha: String?
    /// Directory holding copies of the untracked files that existed at
    /// checkpoint time (stash-create omits untracked). nil when there were
    /// none.
    let untrackedSnapshotDir: URL?
    /// Relative paths (repo-root-relative) of the snapshotted untracked files.
    let untrackedRelativePaths: [String]

    /// Git's well-known EMPTY TREE object — every repo has it without any
    /// commit. Used as the restore/diff base on a repo with no initial commit,
    /// so `git diff <ref>` shows the agent's additions and tracked-file restore
    /// has a valid (empty) base.
    static let emptyTreeSha = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// True when the repo had at least one commit at checkpoint time. False for a
    /// fresh `git init` (no HEAD) — revert then only removes agent-created files
    /// and restores the untracked snapshot (no `checkout`, which can't run
    /// against a path-less empty base).
    var hasBaseCommit: Bool { !baseSha.isEmpty }

    /// The ref REVERT restores tracked files from: the stash snapshot if one
    /// was taken, else HEAD — or the empty tree when the repo has no commits yet.
    /// (Untracked files are restored separately from the on-disk snapshot.)
    var restoreRef: String { stashSha ?? (hasBaseCommit ? baseSha : Self.emptyTreeSha) }

    /// The base the per-run DIFF is computed against: the full-tree snapshot when
    /// it was written, else `restoreRef`. Distinct from `restoreRef` because the
    /// diff base must include pre-existing UNTRACKED work (which `stashSha`/HEAD
    /// omit) so it isn't recounted as this run's edits — see `diffBaseSha`.
    var diffBaseRef: String { diffBaseSha ?? restoreRef }
}

// MARK: - Diff stat

struct GitDiffStat: Equatable, Sendable {
    let filesChanged: Int
    let added: Int
    let removed: Int

    static let zero = GitDiffStat(filesChanged: 0, added: 0, removed: 0)
}

// MARK: - Service

struct GitCheckpointService: Sendable {

    let projectURL: URL
    private let gitURL: URL

    /// Filename prefix for the on-disk untracked-file snapshot dirs in `$TMPDIR`
    /// (`dev-checkpoint-<UUID>/`). Deliberately NOT under `WorkingDirectory.prefix`
    /// (`zerro-`) so the launch sweep can't delete a LIVE checkpoint's snapshot —
    /// see `snapshotUntracked`. The launch-only `sweepOrphanedSnapshots` reclaims
    /// these instead.
    nonisolated static let snapshotPrefix = "dev-checkpoint-"

    /// Filename prefix for the throwaway git index files (`dev-ckpt-index-<UUID>`,
    /// plus their `.lock` siblings) used by `writeWorkingTreeSnapshot`. Normally
    /// removed in a `defer`, but a hard crash mid-snapshot can leak one — never
    /// marker-referenced, so always safe for `sweepOrphanedSnapshots` to delete.
    nonisolated static let indexPrefix = "dev-ckpt-index-"

    /// - Parameters:
    ///   - projectURL: the project folder (must be inside a git work tree).
    ///   - gitURL: the `git` binary. Defaults to `/usr/bin/git` (always present
    ///     on macOS via the Command Line Tools shim and on the GUI-stripped
    ///     PATH), falling back to a PATH probe. Injectable for tests.
    nonisolated init(projectURL: URL, gitURL: URL? = nil) throws {
        self.projectURL = projectURL
        if let gitURL {
            self.gitURL = gitURL
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            self.gitURL = URL(fileURLWithPath: "/usr/bin/git")
        } else if let resolved = DevAgentBinaryResolver.resolve("git") {
            self.gitURL = resolved
        } else {
            throw GitCheckpointError.gitUnavailable
        }
    }

    // MARK: Checkpoint

    nonisolated func checkpoint() throws -> GitCheckpoint {
        try verifyRepository()

        // Resolve HEAD, but tolerate a repo with NO initial commit (fresh
        // `git init`): `rev-parse HEAD` exits non-zero there. An empty baseSha
        // marks that state — everything is untracked, so the snapshot below is
        // the whole pre-run state and the restore base is the empty tree.
        let headResult = try run(["rev-parse", "HEAD"], allowFailure: true)
        let hasHead = headResult.status == 0
        let baseSha = hasHead
            ? headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // Settle "racy-clean" stat info: a file written within the same second
        // as the index timestamp is flagged maybe-dirty until git re-checksums
        // it. Refreshing first means `stash create` reflects only REAL changes —
        // otherwise a just-touched-but-identical file spawns a pointless
        // snapshot commit. `--refresh` exits non-zero when there ARE genuine
        // modifications, which is expected here, so failure is allowed.
        try run(["update-index", "-q", "--refresh"], allowFailure: true)

        // `git stash create` snapshots tracked + index state into a commit
        // WITHOUT mutating the work tree or stash list — the REVERT base for
        // tracked files. Empty output ⇒ the tree was clean, so the restore base
        // is HEAD. SKIPPED on a repo with no initial commit: stash-create
        // requires a HEAD ("you do not have the initial commit yet") — there,
        // every file is untracked and captured by the snapshot below instead.
        //
        // A hard `stash create` failure (e.g. a stale `.git/index.lock`) throws —
        // `run` maps the lock signature to `.indexLocked`, so the user gets the
        // actionable fix rather than a silently-wrong base. The empty-output case
        // is hardened below: empty is only "clean" when the tree REALLY has no
        // tracked changes; otherwise it's an anomaly and we must NOT degrade to
        // HEAD (which would recount the pre-existing tracked work on revert).
        let stashSha: String?
        if hasHead {
            let stashOut = try run(["stash", "create"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stashOut.isEmpty, hasTrackedChanges() {
                // stash create produced no snapshot yet the tree has tracked
                // changes — the snapshot we'd revert to would be wrong. The
                // realistic cause is a lock that slipped past the hard-failure
                // path, so surface the actionable lock error rather than a base
                // that silently collapses to HEAD.
                Log.dev.error("Dev checkpoint anomaly: stash create empty on a dirty tree")
                throw GitCheckpointError.indexLocked
            }
            stashSha = stashOut.isEmpty ? nil : stashOut
        } else {
            stashSha = nil
        }

        // The per-run DIFF base: a tree of the ENTIRE pre-run working tree
        // (tracked + dirty + untracked, ignored excluded). Unlike `stashSha` this
        // includes untracked files, so prior accepted-but-uncommitted work forms
        // the base instead of being recounted every run (the "+N −0" bug). Written
        // via a throwaway index so the real `.git/index` (and its lock) is never
        // touched — best-effort: nil falls the diff back to `restoreRef`.
        let diffBaseSha = writeWorkingTreeSnapshot()

        let (snapshotDir, relPaths) = try snapshotUntracked()

        Log.dev.notice("Dev checkpoint taken — stash: \(stashSha != nil, privacy: .public), diffBase: \(diffBaseSha != nil, privacy: .public), untracked: \(relPaths.count, privacy: .public)")
        return GitCheckpoint(
            baseSha: baseSha,
            stashSha: stashSha,
            diffBaseSha: diffBaseSha,
            untrackedSnapshotDir: snapshotDir,
            untrackedRelativePaths: relPaths
        )
    }

    /// Whether the tree has any tracked changes (unstaged OR staged) right now —
    /// the cross-check that a stash-create empty output is genuinely "clean".
    /// `diff --quiet` exits 1 when there ARE differences (allowed; we read the
    /// status), 0 when none. Any other failure is treated as "no changes" so a
    /// transient git error can't spuriously block a checkpoint.
    nonisolated private func hasTrackedChanges() -> Bool {
        let unstaged = (try? run(["diff", "--quiet"], allowFailure: true).status) ?? 0
        let staged = (try? run(["diff", "--cached", "--quiet"], allowFailure: true).status) ?? 0
        return unstaged != 0 || staged != 0
    }

    /// Snapshot the ENTIRE current working tree (tracked + dirty + untracked,
    /// `.gitignore`'d files excluded) into a tree object and return its SHA. Uses
    /// a throwaway `GIT_INDEX_FILE` so neither the real index nor `.git/index.lock`
    /// is involved — which also makes the diff robust to a stale lock. `git add
    /// --all` from a fresh (empty) temp index stages every present, non-ignored
    /// file; `write-tree` then records them. Returns nil on any failure (caller
    /// falls back to `restoreRef`).
    nonisolated private func writeWorkingTreeSnapshot() -> String? {
        let indexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.indexPrefix)\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: indexFile)
            try? FileManager.default.removeItem(
                at: indexFile.appendingPathExtension("lock")
            )
        }
        do {
            try run(["add", "--all"], indexFile: indexFile)
            let tree = try run(["write-tree"], indexFile: indexFile).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tree.isEmpty ? nil : tree
        } catch {
            Log.dev.error("Dev checkpoint working-tree snapshot failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    // MARK: Revert

    nonisolated func revert(_ checkpoint: GitCheckpoint) throws {
        try verifyRepository()

        // 0. CRASH-SAFETY PRE-FLIGHT (G-01): the untracked snapshot is the ONLY
        //    copy of the user's pre-existing untracked work. If it's gone (e.g. a
        //    reboot cleared $TMPDIR), a destructive step below could delete
        //    untracked files we can no longer restore — so abort HERE, with the
        //    working tree untouched, and let the caller keep the checkpoint and
        //    surface a retryable .revertFailed rather than tear down to idle.
        try verifyUntrackedSnapshotIntact(checkpoint)

        // 1. Restore tracked files to the checkpoint (recreates files the agent
        //    deleted, reverts modifications). `checkout <ref> -- .` doesn't
        //    remove files absent from the ref — those are handled by clean.
        //    SKIPPED on a no-initial-commit repo: there are no tracked files to
        //    restore, and `checkout <empty-tree> -- .` errors ("pathspec '.' did
        //    not match") because the empty tree has no paths. The agent's work is
        //    entirely untracked there, so clean + untracked-restore fully reverts.
        if checkpoint.hasBaseCommit {
            try run(["checkout", checkpoint.restoreRef, "--", "."])
        } else {
            // Drop any index entries the agent staged so the tree is truly back
            // to the no-commit state (best-effort: a fresh repo may have none).
            try run(["reset", "-q"], allowFailure: true)
        }

        // 2. Remove ONLY the untracked files the AGENT created — never the user's
        //    pre-existing untracked work (those are restored in place by step 3).
        //    The old blanket `git clean -fd` deleted the pre-existing untracked
        //    set too and relied on step 3 to copy it back; a throw in between left
        //    those files deleted (G-01). Scoping the clean to agent-added paths
        //    makes a mid-revert throw non-destructive to the user's work.
        try cleanAgentAddedUntracked(checkpoint)

        // 3. Copy the saved untracked files back into place — reverts an agent
        //    edit to a pre-existing untracked file, recreates one it deleted.
        try restoreUntracked(checkpoint)

        Log.dev.notice("Dev checkpoint reverted to \(checkpoint.restoreRef, privacy: .public)")
    }

    /// Throw BEFORE any destructive revert step if the untracked snapshot — the
    /// sole copy of the user's pre-existing untracked work — is missing. Guards the
    /// "$TMPDIR cleared after checkpoint" case: without it, the `clean` step would
    /// delete untracked files the restore can no longer recover. A checkpoint with
    /// no pre-existing untracked files needs no snapshot, so this is a no-op there.
    nonisolated private func verifyUntrackedSnapshotIntact(_ checkpoint: GitCheckpoint) throws {
        guard !checkpoint.untrackedRelativePaths.isEmpty else { return }
        guard let dir = checkpoint.untrackedSnapshotDir,
              FileManager.default.fileExists(atPath: dir.path) else {
            throw GitCheckpointError.fileOperationFailed(
                "untracked snapshot missing — refusing to revert (would delete unrecoverable untracked files)"
            )
        }
    }

    /// Remove the untracked files the AGENT created during the run, scoped so the
    /// user's PRE-EXISTING untracked work is never deleted (it's restored in place
    /// by `restoreUntracked`). The candidate set is the current untracked set MINUS
    /// the checkpoint's pre-existing untracked set; `.gitignore`'d files are excluded
    /// from both (`--exclude-standard`), so build output survives exactly as the old
    /// blanket `clean -fd` (no `-x`) preserved it. Empty agent-created directories
    /// left behind are then pruned to match the old clean's directory removal.
    nonisolated private func cleanAgentAddedUntracked(_ checkpoint: GitCheckpoint) throws {
        let raw = try run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
        let current = raw.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        let preExisting = Set(checkpoint.untrackedRelativePaths)
        let agentAdded = current.filter { !preExisting.contains($0) }
        guard !agentAdded.isEmpty else { return }
        // `-fd` descends into any directory the agent created; the explicit
        // pathspec keeps the removal off the pre-existing untracked set.
        try run(["clean", "-fd", "--"] + agentAdded)
        pruneEmptyAgentDirectories(agentAdded)
    }

    /// After removing agent-added files, drop any now-EMPTY directories the agent
    /// created so a reverted tree carries no stray empty dirs (parity with the old
    /// blanket `clean -fd`). Walks each agent-added path's ancestors bottom-up,
    /// removing a directory ONLY while it is genuinely empty — so a dir still holding
    /// the user's pre-existing untracked work is never touched, and `restoreUntracked`
    /// recreates any dir it needs afterward. Best-effort: an empty dir is cosmetic,
    /// never data loss, so failures are ignored.
    nonisolated private func pruneEmptyAgentDirectories(_ agentAdded: [String]) {
        let fm = FileManager.default
        for rel in agentAdded {
            var dir = (rel as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                let abs = projectURL.appendingPathComponent(dir)
                guard let contents = try? fm.contentsOfDirectory(atPath: abs.path),
                      contents.isEmpty else { break }
                try? fm.removeItem(at: abs)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
    }

    // MARK: Revert verification

    /// Whether the working tree now matches the checkpoint's CAPTURED state —
    /// the success check after a revert. This is deliberately NOT `diffStat == 0`:
    /// `diffStat` counts untracked files (so the result card can show
    /// agent-created files), but a checkpoint legitimately HAS untracked files
    /// (e.g. a prior accepted-but-uncommitted run), and restoring them must NOT
    /// read as a residual change. So we check the two halves the checkpoint
    /// actually captured, separately:
    ///   1. TRACKED files match `restoreRef` — a plain `git diff <ref>` (untracked
    ///      NOT included) with no output.
    ///   2. The current untracked set equals the snapshotted untracked set, both
    ///      in PATHS and in CONTENT (the agent may have left an extra untracked
    ///      file, or edited a restored one).
    /// Returns true only when both hold.
    nonisolated func isRestored(to checkpoint: GitCheckpoint) -> Bool {
        // 1. Tracked-file parity: `diff --quiet` exits 0 when identical, 1 when
        //    there are differences — so allowFailure (1 is not an error here) and
        //    read the status. Any other failure (no such ref, git error) → not
        //    restored.
        guard let trackedResult = try? run(["diff", "--quiet", checkpoint.restoreRef], allowFailure: true),
              trackedResult.status == 0 else {
            return false
        }

        // 2. Untracked parity: same paths AND same bytes as the snapshot.
        let raw = (try? run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout) ?? ""
        let nowUntracked = Set(raw.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
        guard nowUntracked == Set(checkpoint.untrackedRelativePaths) else { return false }

        guard let snapshotDir = checkpoint.untrackedSnapshotDir else {
            // No snapshot dir ⇒ the checkpoint had no untracked files; parity above
            // already proved the current set is also empty.
            return nowUntracked.isEmpty
        }
        for rel in checkpoint.untrackedRelativePaths {
            let live = projectURL.appendingPathComponent(rel)
            let saved = snapshotDir.appendingPathComponent(rel)
            guard let a = try? Data(contentsOf: live),
                  let b = try? Data(contentsOf: saved), a == b else {
                return false
            }
        }
        return true
    }

    // MARK: Diff stat

    /// File changes between the checkpoint and the current working tree
    /// (design §4: `N files changed (+x −y)`) — ONLY the edits THIS run made.
    /// Counts the agent's edits to tracked files AND files it CREATED (untracked).
    /// Pre-existing uncommitted work (a prior accepted-but-uncommitted run, or the
    /// user's own edits) is the base and is NOT counted: the diff is computed
    /// against `diffBaseSha`, a full-tree snapshot that already includes it (see
    /// `runDiff`). Critical for a no-commit repo, where the agent's entire output
    /// is untracked and would otherwise read as "0 files changed".
    nonisolated func diffStat(since checkpoint: GitCheckpoint) throws -> GitDiffStat {
        let out = try runDiff(["--numstat"], since: checkpoint)
        var files = 0, added = 0, removed = 0
        for line in out.split(whereSeparator: \.isNewline) {
            // numstat: "<added>\t<removed>\t<path>"; binary files show "-\t-".
            let cols = line.split(separator: "\t", maxSplits: 2)
            guard cols.count >= 3 else { continue }
            files += 1
            added += Int(cols[0]) ?? 0
            removed += Int(cols[1]) ?? 0
        }
        return GitDiffStat(filesChanged: files, added: added, removed: removed)
    }

    /// The per-run diff output for the given `git diff` flags — base → current
    /// working tree — counting ONLY the edits this run made.
    ///
    /// Preferred path: a TREE-vs-TREE diff. The base is the checkpoint's full
    /// pre-run snapshot (`diffBaseSha`, which includes untracked work); the
    /// "current" side is a fresh snapshot of the working tree taken the same way.
    /// Both sides include untracked files and neither touches the real index — so
    /// pre-existing untracked work cancels out (it's in both trees) and a stale
    /// `.git/index.lock` can't corrupt the result.
    ///
    /// Fallback (only when no snapshot could be written at checkpoint OR now):
    /// the legacy `git diff <restoreRef>` with a scoped intent-to-add for
    /// untracked files. This preserves prior behavior when the tree snapshot is
    /// unavailable.
    nonisolated private func runDiff(_ flags: [String], since checkpoint: GitCheckpoint) throws -> String {
        if let baseTree = checkpoint.diffBaseSha, let currentTree = writeWorkingTreeSnapshot() {
            return try run(["diff"] + flags + [baseTree, currentTree]).stdout
        }
        return try diffIncludingUntracked(["diff"] + flags + [checkpoint.restoreRef])
    }

    /// FALLBACK diff path (used by `runDiff` only when no full-tree snapshot is
    /// available). Runs a `git diff <ref>` so that agent-CREATED untracked files
    /// are included as new-file additions. `git diff` ignores untracked files, so
    /// we briefly `git add --intent-to-add` (`-N`) ONLY the currently-untracked
    /// paths (content is NOT staged — `-N` records just their existence), run the
    /// diff, then `git reset` exactly those paths back to untracked. Scoping the
    /// reset to the `-N`'d paths leaves any work the USER had staged before the
    /// run untouched. The reset runs even if the diff throws.
    ///
    /// NOTE: against a `restoreRef` base (stash/HEAD) this CANNOT distinguish a
    /// pre-existing untracked file from one the agent just made — both read as
    /// additions. That accumulation is exactly why the preferred `runDiff` path
    /// diffs against the untracked-inclusive `diffBaseSha` instead; this remains
    /// only as a graceful degradation when that snapshot couldn't be written.
    nonisolated private func diffIncludingUntracked(_ diffArgs: [String]) throws -> String {
        // The untracked, non-ignored paths at diff time (NUL-separated for paths
        // with spaces/newlines). Empty ⇒ nothing to mark; just run the diff.
        let raw = try run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
        let untracked = raw.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        guard !untracked.isEmpty else {
            return try run(diffArgs).stdout
        }

        // Mark them intent-to-add so the diff sees them. Best-effort: a path that
        // vanished between ls-files and here just won't be marked.
        try run(["add", "--intent-to-add", "--"] + untracked, allowFailure: true)
        defer {
            // Always undo the intent-to-add, scoped to exactly these paths, so the
            // index is left as we found it (user-staged changes preserved).
            try? run(["reset", "-q", "--"] + untracked, allowFailure: true)
        }
        return try run(diffArgs).stdout
    }

    // MARK: Unified diff

    /// The readable unified diff between the checkpoint and the current working
    /// tree (`git diff <restoreRef>`) — the per-file hunks shown in the Dev Mode
    /// result card's body well. CAPPED at `maxLines` / `maxBytes` with a trailing
    /// truncation note so a huge change can't bloat the pill. Run off-main (like
    /// `diffStat`): a big diff can be slow to compute and read.
    ///
    /// `--no-color` is explicit (a user's `color.diff = always` would otherwise
    /// leak ANSI escapes into the text); context defaults to git's standard 3
    /// lines (no `-U` flag is passed — add one here if non-default context is ever
    /// wanted). Agent-CREATED untracked files are included as new-file hunks via
    /// the scoped intent-to-add in `diffIncludingUntracked` — so a no-commit
    /// repo's all-untracked output still renders in the result card.
    nonisolated func diff(since checkpoint: GitCheckpoint, maxLines: Int = 400, maxBytes: Int = 24_000) throws -> String {
        let raw = try runDiff(["--no-color"], since: checkpoint)
        return Self.cappedDiff(raw, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// Trim a unified diff to at most `maxLines` lines and `maxBytes` bytes,
    /// appending a "… (truncated, N more lines)" note when anything was dropped.
    /// Pure + internal so the truncation contract is unit-testable.
    nonisolated static func cappedDiff(_ diff: String, maxLines: Int = 400, maxBytes: Int = 24_000) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var bytes = 0
        for (index, line) in lines.enumerated() {
            let lineBytes = line.utf8.count + 1 // + newline
            if kept.count >= maxLines || bytes + lineBytes > maxBytes {
                let remaining = lines.count - index
                let noun = remaining == 1 ? "line" : "lines"
                kept.append(Substring("\u{2026} (truncated, \(remaining) more \(noun))"))
                break
            }
            kept.append(line)
            bytes += lineBytes
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Untracked snapshot helpers

    nonisolated private func snapshotUntracked() throws -> (dir: URL?, relPaths: [String]) {
        // -z → NUL-separated, so paths with spaces/newlines are unambiguous.
        let raw = try run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
        let relPaths = raw.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        guard !relPaths.isEmpty else { return (nil, []) }

        // Deliberately NOT under the `zerro-` prefix: `WorkingDirectory.sweep()`
        // reclaims every `zerro-*` temp dir at launch/recovery, which would
        // delete a LIVE checkpoint's untracked snapshot out from under a run.
        // The agent edit is bounded by one dispatch, so the coordinator removes
        // this via `discardSnapshot` on completion/revert.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.snapshotPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for rel in relPaths {
                let src = projectURL.appendingPathComponent(rel)
                let dst = dir.appendingPathComponent(rel)
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                // Skip a path that vanished between ls-files and the copy.
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                try FileManager.default.copyItem(at: src, to: dst)
            }
        } catch {
            throw GitCheckpointError.fileOperationFailed("snapshot untracked: \(error.localizedDescription)")
        }
        return (dir, relPaths)
    }

    nonisolated private func restoreUntracked(_ checkpoint: GitCheckpoint) throws {
        guard let dir = checkpoint.untrackedSnapshotDir else { return }
        let fm = FileManager.default
        do {
            for rel in checkpoint.untrackedRelativePaths {
                let src = dir.appendingPathComponent(rel)
                let dst = projectURL.appendingPathComponent(rel)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                // ATOMIC per-file restore: copy the saved original to a temp sibling,
                // then swap it into place. A plain remove-then-copy had a gap — if
                // the copy threw, the destination was already deleted, briefly losing
                // a pre-existing untracked file (recoverable only because the snapshot
                // is retained). Copying first, then atomically replacing, means a
                // mid-restore failure leaves the destination exactly as it was.
                let tmp = dst.deletingLastPathComponent()
                    .appendingPathComponent(".zerro-restore-\(UUID().uuidString)-\(dst.lastPathComponent)")
                do {
                    try fm.copyItem(at: src, to: tmp)
                } catch {
                    try? fm.removeItem(at: tmp)
                    throw error
                }
                if fm.fileExists(atPath: dst.path) {
                    _ = try fm.replaceItemAt(dst, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dst)
                }
            }
        } catch {
            throw GitCheckpointError.fileOperationFailed("restore untracked: \(error.localizedDescription)")
        }
    }

    /// Best-effort removal of the on-disk untracked snapshot once a checkpoint
    /// is no longer needed (the coordinator calls this after a successful run is
    /// finalized, or after a revert). Never load-bearing for correctness.
    nonisolated func discardSnapshot(_ checkpoint: GitCheckpoint) {
        guard let dir = checkpoint.untrackedSnapshotDir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Launch-only, marker-aware reclaim of orphaned Dev Mode temp dirs in
    /// `$TMPDIR`: every `dev-checkpoint-*` snapshot dir and `dev-ckpt-index-*`
    /// throwaway index, EXCEPT the single `keeping` path (the snapshot a still-
    /// pending cross-launch recovery marker points at — the only one that may
    /// still be needed). Closes the two leaks `discardSnapshot` can't reach: a
    /// hard crash during the review gate (snapshot created, but no marker yet),
    /// and a leaked index file from a crash mid-`writeWorkingTreeSnapshot`.
    ///
    /// MUST run only at launch and only AFTER `recoverInterruptedDevCheckpointIfAny`
    /// has loaded the marker — otherwise it could race the recovery offer or delete
    /// a live checkpoint a running app still holds. Best-effort: failures are
    /// logged and ignored (mirrors `WorkingDirectory.sweep`).
    nonisolated static func sweepOrphanedSnapshots(keeping keep: String? = nil) {
        sweepOrphanedSnapshots(in: FileManager.default.temporaryDirectory, keeping: keep)
    }

    /// Directory-injectable core of `sweepOrphanedSnapshots` — the production path
    /// passes `$TMPDIR`; tests pass a throwaway subdir so the sweep is hermetic and
    /// can never reach a concurrent test's live snapshot.
    nonisolated static func sweepOrphanedSnapshots(in directory: URL, keeping keep: String? = nil) {
        let fm = FileManager.default
        let keepPath = keep.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.dev.error("dev snapshot sweep: couldn't list tmp: \(error.localizedDescription, privacy: .private)")
            return
        }

        var removed = 0
        for entry in contents {
            let name = entry.lastPathComponent
            guard name.hasPrefix(snapshotPrefix) || name.hasPrefix(indexPrefix) else { continue }
            if let keepPath, entry.standardizedFileURL.path == keepPath { continue }
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                // The basename is .public — a `dev-checkpoint-*` / `dev-ckpt-index-*`
                // name we generated ourselves, no user content. The error
                // description is .private (it embeds paths).
                Log.dev.error(
                    "dev snapshot sweep: couldn't remove \(name, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        if removed > 0 {
            Log.dev.notice("dev snapshot sweep removed \(removed, privacy: .public) orphaned entries")
        }
    }

    // MARK: - Repository probe

    /// Whether `projectURL` is inside a git work tree. Non-throwing wrapper over
    /// `verifyRepository()` for the record-time folder check (Milestone 7) — a
    /// non-repo folder surfaces a non-blocking warning on the folder chip so the
    /// user learns BEFORE recording, rather than only at the checkpoint gate.
    nonisolated func isRepository() -> Bool {
        do { try verifyRepository(); return true } catch { return false }
    }

    // MARK: - Git plumbing

    nonisolated private func verifyRepository() throws {
        do {
            let result = try run(["rev-parse", "--is-inside-work-tree"], allowFailure: true)
            guard result.status == 0,
                  result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                throw GitCheckpointError.notAGitRepository
            }
        } catch let error as GitCheckpointError {
            throw error
        }
    }

    @discardableResult
    nonisolated private func run(_ arguments: [String], allowFailure: Bool = false, indexFile: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = projectURL
        // Deterministic, non-interactive: never open a pager or prompt for
        // credentials mid-run.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Point git at a THROWAWAY index (working-tree snapshot path) so the real
        // `.git/index` — and its lock — are never touched.
        if let indexFile { env["GIT_INDEX_FILE"] = indexFile.path }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw GitCheckpointError.commandFailed(arguments: arguments, status: -1, stderr: String(describing: error))
        }
        // Read BEFORE waitUntilExit so a large diff can't fill the pipe buffer
        // and deadlock the child.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 && !allowFailure {
            // A stale `.git/index.lock` (left by an interrupted git/agent run)
            // makes every index write fail — git reports "could not write index"
            // / "Unable to create '…/index.lock': File exists". Map it to a
            // dedicated error so the pill can give the exact fix instead of a
            // generic failure. Checked here so ANY index-writing git op surfaces
            // it, not just `stash create`.
            if Self.isIndexLockFailure(stderr) {
                throw GitCheckpointError.indexLocked
            }
            throw GitCheckpointError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                stderr: String(stderr.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (process.terminationStatus, stdout, stderr)
    }

    /// Recognize the stale-lock signature in git's stderr. Matches both the
    /// direct lock message and the "could not write index" that `stash create`
    /// reports when the lock blocks the write. Case-insensitive + substring so a
    /// localized or slightly reworded git build still matches.
    nonisolated private static func isIndexLockFailure(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("index.lock")
            || s.contains("could not write index")
            || s.contains("unable to write new index")
    }
}
