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
