//
//  GitCheckpointTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 3) — the git checkpoint/revert safety model
//  (design §4). These run real `git` against a throwaway repo in the temp dir
//  and assert the load-bearing guarantee: after checkpoint → arbitrary agent
//  mutations → revert, the working tree is byte-identical to the pre-run state,
//  covering tracked, DIRTY (uncommitted), and untracked files.
//

import XCTest
@testable import Zerro

final class GitCheckpointTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // NOT a `zerro-` prefix: a parallel test worker running
        // PendingPaidGenerationTests calls `WorkingDirectory.sweep()`, which
        // deletes every `zerro-*` dir in the shared temp dir — that would yank
        // this repo out from under the spawned git mid-test.
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-ckpt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try super.tearDownWithError()
    }

    // MARK: - Repo requirement

    func testCheckpointThrowsOnNonRepo() throws {
        // Fresh dir, never `git init`'d.
        let service = try GitCheckpointService(projectURL: repo)
        XCTAssertThrowsError(try service.checkpoint()) { error in
            XCTAssertEqual(error as? GitCheckpointError, .notAGitRepository)
        }
    }

    // MARK: - Round trip (tracked + dirty + untracked)

    func testRevertRestoresTrackedDirtyAndUntrackedByteIdentical() throws {
        try initRepo()

        // Committed baseline.
        write("tracked.txt", "v1\n")
        write("deleteme.txt", "d1\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        // Pre-run state the checkpoint must faithfully restore:
        //  • a DIRTY tracked file (uncommitted modification)
        write("tracked.txt", "v1-dirty\n")
        //  • untracked files, including one nested in a subdir
        write("untracked.txt", "u1\n")
        write("sub/nested.txt", "n1\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        // Dirty tree → a stash snapshot commit was produced.
        XCTAssertNotNil(checkpoint.stashSha)
        XCTAssertEqual(Set(checkpoint.untrackedRelativePaths), ["untracked.txt", "sub/nested.txt"])

        // Simulate the agent mutating the tree every which way:
        write("tracked.txt", "agent-edit\n")          // modify dirty tracked
        remove("deleteme.txt")                          // delete a tracked file
        write("agent-new.txt", "new\n")                 // create untracked
        write("untracked.txt", "u1-modified\n")         // modify pre-existing untracked
        remove("sub/nested.txt")                        // delete pre-existing untracked

        try service.revert(checkpoint)

        // Tracked dirty content restored (NOT the committed v1 — the exact
        // pre-run working-tree state).
        XCTAssertEqual(read("tracked.txt"), "v1-dirty\n")
        // Deleted tracked file recreated.
        XCTAssertEqual(read("deleteme.txt"), "d1\n")
        // Pre-existing untracked files restored to their original content.
        XCTAssertEqual(read("untracked.txt"), "u1\n")
        XCTAssertEqual(read("sub/nested.txt"), "n1\n")
        // Agent-created file removed.
        XCTAssertFalse(exists("agent-new.txt"))
    }

    func testCleanTreeCheckpointHasNoStashAndRevertsAgentEdits() throws {
        try initRepo()
        write("app.css", ".btn { color: blue; }\n")
        git("add", "-A")
        git("commit", "-m", "baseline")
        // Defeat git's "racy clean" heuristic: a file written in the same second
        // as the index can be flagged maybe-dirty, making `stash create`
        // non-deterministically emit a (content-identical, harmless) snapshot.
        // Back-date the file so its mtime is unambiguously older than the index.
        backdate("app.css")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        // Clean tree → no stash commit; HEAD is the restore base.
        XCTAssertNil(checkpoint.stashSha)
        XCTAssertEqual(checkpoint.untrackedRelativePaths, [])

        write("app.css", ".btn { color: teal; }\n")
        try service.revert(checkpoint)
        XCTAssertEqual(read("app.css"), ".btn { color: blue; }\n")
    }

    // MARK: - .gitignore'd files survive

    func testIgnoredFilesAreNotTouched() throws {
        try initRepo()
        write(".gitignore", "build/\n")
        write("src.txt", "s1\n")
        git("add", "-A")
        git("commit", "-m", "baseline")
        // An ignored build artifact present before the run.
        write("build/out.o", "binary\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        // Ignored files are neither snapshotted…
        XCTAssertFalse(checkpoint.untrackedRelativePaths.contains("build/out.o"))

        write("src.txt", "agent\n")
        try service.revert(checkpoint)
        // …nor removed by revert's clean (no -x).
        XCTAssertTrue(exists("build/out.o"))
        XCTAssertEqual(read("src.txt"), "s1\n")
    }

    // MARK: - Empty repo (no initial commit)

    /// A fresh `git init` with NO commits must checkpoint + revert cleanly: there
    /// is no HEAD (so `rev-parse HEAD` / `stash create` would error), and every
    /// file is untracked. Regression test for the "Couldn't snapshot the project"
    /// failure on a brand-new repo.
    func testCheckpointAndRevertOnRepoWithNoCommits() throws {
        git("init", "-q")
        // NOTE: deliberately NO commit — this is the empty-repo case.

        // Pre-run state: a couple of untracked files the user already had.
        write("index.html", "<h1>v1</h1>\n")
        write("src/app.ts", "export const v = 1\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        // No commit → empty base, no stash, restore base is the empty tree.
        XCTAssertEqual(checkpoint.baseSha, "")
        XCTAssertNil(checkpoint.stashSha)
        XCTAssertFalse(checkpoint.hasBaseCommit)
        XCTAssertEqual(checkpoint.restoreRef, GitCheckpoint.emptyTreeSha)
        XCTAssertEqual(Set(checkpoint.untrackedRelativePaths), ["index.html", "src/app.ts"])

        // Simulate the agent: modify an existing file, add a new one, delete one.
        write("index.html", "<h1>agent-edited</h1>\n")
        write("src/new.ts", "export const added = true\n")
        remove("src/app.ts")

        try service.revert(checkpoint)

        // The pre-run state is restored byte-identically.
        XCTAssertEqual(read("index.html"), "<h1>v1</h1>\n")
        XCTAssertEqual(read("src/app.ts"), "export const v = 1\n")
        // The agent-created file is gone.
        XCTAssertFalse(exists("src/new.ts"))
    }

    // MARK: - Revert verification (isRestored)

    /// The exact bug a user hit: run 1 was accepted but NOT committed (so its
    /// files sit untracked), run 2 edited them, and Undo reported "Couldn't
    /// restore your files" even though the tree WAS restored. `isRestored` checks
    /// tracked + untracked PARITY against the checkpoint directly — it must NOT be
    /// derived from `diffStat`, whose diff base is best-effort (`diffBaseSha` may
    /// be nil, e.g. on a recovery-reconstructed checkpoint, falling back to a base
    /// that omits untracked files). This independence is the invariant under test.
    func testIsRestoredTrueAfterRevertingUntrackedCheckpoint() throws {
        git("init", "-q") // no commit — run-1 files are untracked

        // Checkpoint state: untracked files from a prior accepted-but-uncommitted run.
        write("index.html", "<h1>v1</h1>\n")
        write("src/app.ts", "const v = 1\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        // Agent edits + adds, then we revert.
        write("index.html", "<h1>v2</h1>\n")
        write("src/extra.ts", "const x = 2\n")
        try service.revert(checkpoint)

        // The tree matches the checkpoint → revert succeeded.
        XCTAssertTrue(service.isRestored(to: checkpoint),
                      "a correctly-restored untracked checkpoint must verify as restored")
        // And the per-run diff is back to zero: with the full-tree diff base, the
        // restored pre-existing untracked files are the base, not a residual change
        // (the accumulation fix — previously this miscounted them as additions).
        XCTAssertEqual(try service.diffStat(since: checkpoint), .zero,
                       "a fully restored tree has no per-run changes")
    }

    /// `isRestored` must return FALSE when revert genuinely left the tree dirty —
    /// otherwise a real failure would be silently treated as success.
    func testIsRestoredFalseWhenTreeStillDiffers() throws {
        try initRepo()
        write("a.txt", "base\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        // A tracked edit that was NOT reverted.
        write("a.txt", "still-dirty\n")
        XCTAssertFalse(service.isRestored(to: checkpoint),
                       "an unreverted tracked edit must NOT verify as restored")

        // An extra agent-created untracked file left behind also fails parity.
        write("a.txt", "base\n")              // restore the tracked edit
        write("leftover.txt", "oops\n")       // but a stray untracked file remains
        XCTAssertFalse(service.isRestored(to: checkpoint),
                       "a leftover untracked file must NOT verify as restored")
    }

    // MARK: - diffStat

    func testDiffStatCountsTrackedChanges() throws {
        try initRepo()
        write("a.txt", "line1\nline2\n")
        write("b.txt", "keep\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        XCTAssertEqual(try service.diffStat(since: checkpoint), .zero)

        // Modify a.txt: line2 → CHANGED + add line3  ⇒  +2 / -1 across 1 file.
        write("a.txt", "line1\nCHANGED\nline3\n")
        let stat = try service.diffStat(since: checkpoint)
        XCTAssertEqual(stat.filesChanged, 1)
        XCTAssertEqual(stat.added, 2)
        XCTAssertEqual(stat.removed, 1)
    }

    // MARK: - Unified diff

    func testDiffReturnsReadableUnifiedDiff() throws {
        try initRepo()
        write("a.txt", "line1\nline2\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        // Nothing changed yet → empty diff.
        XCTAssertEqual(try service.diff(since: checkpoint), "")

        write("a.txt", "line1\nCHANGED\n")
        let diff = try service.diff(since: checkpoint)
        // The unified diff names the file and shows the +/- hunk lines.
        XCTAssertTrue(diff.contains("a.txt"), "diff should name the changed file:\n\(diff)")
        XCTAssertTrue(diff.contains("-line2"), "diff should show the removed line:\n\(diff)")
        XCTAssertTrue(diff.contains("+CHANGED"), "diff should show the added line:\n\(diff)")
        XCTAssertTrue(diff.contains("@@"), "diff should include a hunk header:\n\(diff)")
    }

    /// The result card must show agent-CREATED (untracked) files, not just edits
    /// to tracked ones — otherwise a no-commit repo (all untracked) reads as
    /// "No tracked-file changes." Regression test for the empty diff.
    func testDiffIncludesUntrackedAgentFiles() throws {
        try initRepo()
        write("a.txt", "line1\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        // Agent CREATES a new (untracked) file — no `git add`.
        write("new.ts", "export const added = true\n")

        let stat = try service.diffStat(since: checkpoint)
        XCTAssertEqual(stat.filesChanged, 1, "the created file must be counted")
        XCTAssertEqual(stat.added, 1)

        let diff = try service.diff(since: checkpoint)
        XCTAssertTrue(diff.contains("new.ts"), "diff should name the created file:\n\(diff)")
        XCTAssertTrue(diff.contains("+export const added"), "diff should show the new content:\n\(diff)")
    }

    /// Computing the diff must NOT disturb the index — work the user staged before
    /// the run has to survive (the intent-to-add is scoped + reset).
    func testDiffLeavesUserStagedChangesIntact() throws {
        try initRepo()
        write("a.txt", "base\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        // The user staged a file BEFORE the run; the agent then created an
        // untracked file (which the diff will intent-to-add + reset).
        write("staged.txt", "user\n")
        git("add", "staged.txt")
        write("agent.txt", "agent\n")

        _ = try service.diffStat(since: checkpoint)
        _ = try service.diff(since: checkpoint)

        // staged.txt is still STAGED; agent.txt is still untracked.
        let status = git("status", "--porcelain")
        XCTAssertTrue(status.contains("A  staged.txt"), "user-staged file must stay staged:\n\(status)")
        XCTAssertTrue(status.contains("?? agent.txt"), "agent file must remain untracked:\n\(status)")
    }

    func testCappedDiffTruncatesByLineCount() {
        // 50 lines, capped to 10 → 10 kept + 1 truncation note, naming the
        // remaining count.
        let raw = (1...50).map { "line\($0)" }.joined(separator: "\n")
        let capped = GitCheckpointService.cappedDiff(raw, maxLines: 10, maxBytes: 1_000_000)
        let lines = capped.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 11, "10 kept lines + 1 truncation note")
        XCTAssertEqual(String(lines[9]), "line10")
        // line11…line50 are dropped → 40 remaining.
        XCTAssertTrue(capped.contains("truncated, 40 more lines"), "note names the dropped count:\n\(capped)")
    }

    func testCappedDiffLeavesSmallDiffIntact() {
        let raw = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new"
        XCTAssertEqual(GitCheckpointService.cappedDiff(raw, maxLines: 400, maxBytes: 24_000), raw)
    }

    // MARK: - Per-run diff base: no accumulation across uncommitted runs

    /// THE CORE BUG. A prior run modified a TRACKED file and was accepted but NOT
    /// committed; the current run makes a further small edit. The pill must count
    /// ONLY the current run's lines — the pre-existing modification is the base.
    /// (Before the fix, a nil `stashSha` would diff against HEAD and recount the
    /// prior edit.)
    func testDiffStatExcludesPriorUncommittedTrackedEdit() throws {
        try initRepo()
        write("tracked.txt", "l1\nl2\nl3\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        // Prior accepted-but-uncommitted run: a tracked-file modification.
        write("tracked.txt", "l1\nPRIOR\nl3\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        // Current run: one further changed line.
        write("tracked.txt", "l1\nPRIOR\nl3-NOW\n")

        let stat = try service.diffStat(since: checkpoint)
        XCTAssertEqual(stat.filesChanged, 1)
        XCTAssertEqual(stat.added, 1, "only the current run's added line, not the prior edit")
        XCTAssertEqual(stat.removed, 1)
    }

    /// THE CORE BUG, untracked variant — the dominant real-world cause (an agent
    /// CREATING files across runs). A prior run left an untracked file; the
    /// current run edits it and creates one new file. `git stash create` NEVER
    /// captures untracked files, so before the fix the prior file's whole content
    /// was recounted as additions every run ("+N −0" accumulation). The full-tree
    /// `diffBaseSha` makes it the base instead.
    func testDiffStatExcludesPriorUncommittedUntrackedFiles() throws {
        try initRepo()
        write("committed.txt", "base\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        // Prior accepted-but-uncommitted run: an agent-created (untracked) file.
        write("prior_new.txt", "p1\np2\np3\np4\np5\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        // The pre-run untracked file is the base, captured in the diff snapshot.
        XCTAssertNotNil(checkpoint.diffBaseSha, "a dirty/untracked tree must snapshot a diff base")

        // Current run: append one line to the prior file + create a new file.
        write("prior_new.txt", "p1\np2\np3\np4\np5\np6\n")
        write("run_now.txt", "n1\nn2\n")

        let stat = try service.diffStat(since: checkpoint)
        // prior_new.txt: +1 (the appended line only), run_now.txt: +2 (new file).
        XCTAssertEqual(stat.filesChanged, 2)
        XCTAssertEqual(stat.added, 3, "only this run's lines (1 appended + 2 new), not the 5 pre-existing")
        XCTAssertEqual(stat.removed, 0)
    }

    /// The repeated-run accumulation the user reported: take a checkpoint, make an
    /// edit, take ANOTHER checkpoint (simulating a second uncommitted run), make a
    /// further edit. The second run's diff must reflect only the second edit — the
    /// count must NOT grow with the uncommitted backlog.
    func testDiffStatDoesNotAccumulateAcrossSuccessiveCheckpoints() throws {
        try initRepo()
        write("file.txt", "0\n")
        git("add", "-A")
        git("commit", "-m", "baseline")

        let service = try GitCheckpointService(projectURL: repo)

        // Run 1: add 3 lines, accept (NO commit).
        _ = try service.checkpoint()
        write("file.txt", "0\n1\n2\n3\n")

        // Run 2: checkpoint over the uncommitted run-1 state, add 1 more line.
        let checkpoint2 = try service.checkpoint()
        write("file.txt", "0\n1\n2\n3\n4\n")

        let stat = try service.diffStat(since: checkpoint2)
        XCTAssertEqual(stat.added, 1, "run 2 counts only its own line, not run 1's three")
        XCTAssertEqual(stat.removed, 0)
    }

    /// On a dirty tree the diff base must be the full-tree snapshot, and the
    /// REVERT base (`restoreRef`) must be the stash snapshot — never HEAD (the
    /// `−0` accumulation tell came from restoreRef collapsing to HEAD).
    func testDirtyTreeHasSnapshotBaseAndStashRestoreRef() throws {
        try initRepo()
        write("a.txt", "l1\nl2\n")
        git("add", "-A")
        git("commit", "-m", "baseline")
        write("a.txt", "l1\nDIRTY\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        XCTAssertNotNil(checkpoint.stashSha, "a dirty tree produces a stash snapshot")
        XCTAssertNotNil(checkpoint.diffBaseSha, "a dirty tree produces a full-tree diff base")
        XCTAssertEqual(checkpoint.restoreRef, checkpoint.stashSha,
                       "revert base is the stash snapshot, not HEAD")
        XCTAssertEqual(checkpoint.diffBaseRef, checkpoint.diffBaseSha,
                       "diff base is the full-tree snapshot")
        let head = git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(checkpoint.restoreRef, head, "restore base must NOT be HEAD on a dirty tree")
    }

    // MARK: - Stale index lock

    /// A stale `.git/index.lock` (left by an interrupted git/agent run) must
    /// surface as `.indexLocked` — NOT silently degrade to a HEAD-based diff that
    /// would accumulate every uncommitted change. (`stash create` can't write its
    /// snapshot while the lock is held.)
    func testCheckpointThrowsIndexLockedOnStaleLock() throws {
        try initRepo()
        write("a.txt", "l1\n")
        git("add", "-A")
        git("commit", "-m", "baseline")
        write("a.txt", "l1\ndirty\n") // dirty so stash create must write the index

        // Simulate the interrupted-run leftover lock.
        let lock = repo.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())

        let service = try GitCheckpointService(projectURL: repo)
        XCTAssertThrowsError(try service.checkpoint()) { error in
            XCTAssertEqual(error as? GitCheckpointError, .indexLocked,
                           "a stale index lock must surface as .indexLocked")
        }
        try? FileManager.default.removeItem(at: lock)
    }

    // MARK: - Clean tree (no regression)

    /// A genuinely clean tree must still resolve the restore base to HEAD with no
    /// stash, and report a zero diff — the fix must not perturb the clean path.
    func testCleanTreeHasNoStashRestoresToHeadAndZeroDiff() throws {
        try initRepo()
        write("a.txt", "x\n")
        git("add", "-A")
        git("commit", "-m", "baseline")
        backdate("a.txt") // defeat racy-clean so stash create stays empty

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()

        XCTAssertNil(checkpoint.stashSha, "clean tree → no stash snapshot")
        let head = git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(checkpoint.restoreRef, head, "clean tree restores to HEAD")
        XCTAssertEqual(try service.diffStat(since: checkpoint), .zero)
    }

    /// The no-initial-commit (empty-tree) path: the diff must still count the
    /// CURRENT run's edits only, not the pre-existing untracked files (which on a
    /// fresh `git init` are the entire pre-run state).
    func testNoCommitRepoDiffExcludesPreExistingUntracked() throws {
        git("init", "-q") // no commit — everything is untracked

        // Pre-run untracked state (a prior accepted-but-uncommitted run).
        write("index.html", "<h1>v1</h1>\n")

        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        XCTAssertEqual(checkpoint.restoreRef, GitCheckpoint.emptyTreeSha)

        // Current run: one new file only.
        write("new.txt", "added\n")

        let stat = try service.diffStat(since: checkpoint)
        XCTAssertEqual(stat.filesChanged, 1, "only the new file, not the pre-existing index.html")
        XCTAssertEqual(stat.added, 1)
    }

    // MARK: - Git helpers

    private func initRepo() throws {
        git("init", "-q")
        // Local identity so commits don't depend on global config / a $HOME.
        git("config", "user.email", "test@zerro.local")
        git("config", "user.name", "Zerro Test")
        git("config", "commit.gpgsign", "false")
    }

    @discardableResult
    private func git(_ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { XCTFail("git \(args) spawn failed: \(error)"); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            XCTFail("git \(args.joined(separator: " ")) failed (\(process.terminationStatus)): \(out)")
        }
        return out
    }

    // MARK: - File helpers

    private func write(_ rel: String, _ contents: String) {
        let url = repo.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do { try contents.write(to: url, atomically: true, encoding: .utf8) }
        catch { XCTFail("write \(rel) failed: \(error)") }
    }

    private func read(_ rel: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
    }

    private func remove(_ rel: String) {
        try? FileManager.default.removeItem(at: repo.appendingPathComponent(rel))
    }

    private func exists(_ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(rel).path)
    }

    /// Push a file's modification date an hour into the past so git treats it
    /// as unambiguously clean (not "racily clean").
    private func backdate(_ rel: String) {
        let url = repo.appendingPathComponent(rel)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path
        )
    }
}
