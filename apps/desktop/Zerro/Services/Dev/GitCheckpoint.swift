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
//    • revert(): restore tracked files from the snapshot commit, remove
//      agent-created untracked files (git clean, which respects .gitignore so
//      build dirs survive), then copy the saved untracked files back. Net: the
//      working tree returns to exactly the pre-run state; the user's
//      uncommitted work is intact; branch history is untouched.
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

    /// The ref Revert/diff restore tracked files from: the stash snapshot if one
    /// was taken, else HEAD — or the empty tree when the repo has no commits yet.
    var restoreRef: String { stashSha ?? (hasBaseCommit ? baseSha : Self.emptyTreeSha) }
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
        // WITHOUT mutating the work tree or stash list. Empty output ⇒ the tree
        // was clean, so the restore base is HEAD. SKIPPED on a repo with no
        // initial commit: stash-create requires a HEAD ("you do not have the
        // initial commit yet") — there, every file is untracked and captured by
        // the snapshot below instead.
        let stashSha: String?
        if hasHead {
            let stashOut = try run(["stash", "create"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stashSha = stashOut.isEmpty ? nil : stashOut
        } else {
            stashSha = nil
        }

        let (snapshotDir, relPaths) = try snapshotUntracked()

        Log.dev.notice("Dev checkpoint taken — stash: \(stashSha != nil, privacy: .public), untracked: \(relPaths.count, privacy: .public)")
        return GitCheckpoint(
            baseSha: baseSha,
            stashSha: stashSha,
            untrackedSnapshotDir: snapshotDir,
            untrackedRelativePaths: relPaths
        )
    }

    // MARK: Revert

    nonisolated func revert(_ checkpoint: GitCheckpoint) throws {
        try verifyRepository()

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

        // 2. Remove untracked files the agent created. `-fd` covers files +
        //    directories; no `-x`, so .gitignore'd build output is preserved.
        try run(["clean", "-fd"])

        // 3. Copy the saved untracked files back into place.
        try restoreUntracked(checkpoint)

        Log.dev.notice("Dev checkpoint reverted to \(checkpoint.restoreRef, privacy: .public)")
    }

    // MARK: Diff stat

    /// Tracked-file changes between the checkpoint and the current working tree
    /// (design §4: `N files changed (+x −y)`). `git diff <ref>` compares the
    /// snapshot commit to the work tree, so it reflects all of the agent's edits
    /// to tracked files. (Agent-created untracked files aren't counted — Phase 1
    /// matches the design's stated `git diff --stat` surface.)
    nonisolated func diffStat(since checkpoint: GitCheckpoint) throws -> GitDiffStat {
        let out = try run(["diff", "--numstat", checkpoint.restoreRef]).stdout
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
    /// wanted). Like `diffStat`, this covers tracked-file edits — agent-created
    /// untracked files aren't part of `git diff` (Phase 1 scope).
    nonisolated func diff(since checkpoint: GitCheckpoint, maxLines: Int = 400, maxBytes: Int = 24_000) throws -> String {
        let raw = try run(["diff", "--no-color", checkpoint.restoreRef]).stdout
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
            .appendingPathComponent("dev-checkpoint-\(UUID().uuidString)", isDirectory: true)
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
        do {
            for rel in checkpoint.untrackedRelativePaths {
                let src = dir.appendingPathComponent(rel)
                let dst = projectURL.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                // `git clean` already removed it; copy the saved original back.
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
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
    nonisolated private func run(_ arguments: [String], allowFailure: Bool = false) throws -> (status: Int32, stdout: String, stderr: String) {
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
