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
