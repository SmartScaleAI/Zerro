//
//  DevModeTeardownSafetyTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 7) — regression coverage for the teardown-safety
//  invariant surfaced by the adversarial review: a teardown that runs while an
//  agent dispatch is in flight must NEVER abandon the running agent or destroy
//  its undo. Concretely, `resetToIdle()` (reachable via the record-hotkey path)
//  must route through the safe terminate→revert, not the plain reset that only
//  cancels the (inert) Swift Task and discards the snapshot.
//

import XCTest
@testable import Zerro

@MainActor
final class DevModeTeardownSafetyTests: XCTestCase {

    private var repos: [URL] = []
    private var tempFiles: [URL] = []
    private var snapshotDirs: [URL] = []

    override func tearDownWithError() throws {
        for url in repos + tempFiles + snapshotDirs { try? FileManager.default.removeItem(at: url) }
        repos = []; tempFiles = []; snapshotDirs = []
    }

    func testIsDevBusyCoversDispatchAndReverting() {
        let app = AppState()
        // The dispatch tail + revert are all "busy" — the hotkey flashes instead
        // of starting a new recording over a live agent.
        for s in [RecordingState.devCheckpointing, .devAgentDispatching, .devAgentRunning, .devReverting] {
            app.state = s
            XCTAssertTrue(app.isDevBusy, "\(s) must read as dev-busy")
        }
        // Terminal + idle states are NOT busy.
        for s in [RecordingState.idle, .done, .devDone, .devFailed] {
            app.state = s
            XCTAssertFalse(app.isDevBusy, "\(s) must NOT read as dev-busy")
        }
    }

    func testResetToIdleDuringActiveDispatchRoutesThroughSafeCancel() async {
        let app = AppState()
        app.recordingIsDevMode = true
        app.state = .devAgentRunning

        // The OLD bug: resetToIdle() synchronously set `.idle` (abandoning the
        // agent + discarding the undo). The fix routes through the safe cancel,
        // which first flips to `.devReverting` (terminate → await → revert) — so
        // the state is NOT `.idle` immediately after the call.
        app.resetToIdle()
        XCTAssertEqual(app.state, .devReverting,
                       "reset during an active dispatch must route through safe-cancel, not plain-reset to idle")

        // With no checkpoint/agent to wait on, the async teardown then settles to
        // idle on its own.
        await settle { app.state == .idle }
        XCTAssertEqual(app.state, .idle)
        XCTAssertFalse(app.recordingIsDevMode, "dev state cleared after the safe teardown")
    }

    // MARK: - G-01: a cancel whose auto-revert FAILS must not destroy the undo

    /// The launch-blocker. A safe-cancel auto-revert that does NOT verify-restore
    /// must KEEP the checkpoint, the untracked snapshot, AND the recovery marker,
    /// and surface a retryable `.revertFailed` card — never tear down to idle (which
    /// would discard the only copy of the user's pre-existing untracked work and
    /// strand the agent's partial edits with no undo).
    func testCancelWithFailingRevertKeepsSnapshotMarkerAndOffersRevert() async throws {
        let (repo, checkpoint) = try makeDirtyCheckpoint()
        let snapshot = try XCTUnwrap(checkpoint.untrackedSnapshotDir)

        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(repo: repo))
        app.recordingIsDevMode = true
        app.devAgentStarted = true
        app.devCheckpoint = checkpoint
        // A service whose `git` ALWAYS fails → the auto-revert can't restore.
        app.devCheckpointService = try GitCheckpointService(
            projectURL: repo, gitURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        app.state = .devAgentRunning

        app.cancelRecording() // routes to the safe cancel → auto-revert
        await settle({ app.state == .devFailed }, timeoutMs: 3000)

        XCTAssertEqual(app.state, .devFailed, "a failed auto-revert must NOT settle to idle")
        XCTAssertEqual(app.devFailure, .revertFailed)
        XCTAssertTrue(app.devCanRevert, "a working Revert must be offered so the user can retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path),
                      "the untracked snapshot must SURVIVE a failed revert")
        XCTAssertNotNil(app.devRecoveryStore.load(),
                        "the recovery marker must SURVIVE a failed revert")
        XCTAssertEqual(read(repo, "untracked.txt"), "u1\n",
                       "the user's pre-existing untracked file must not be lost")
    }

    /// Happy path unchanged: a cancel whose auto-revert verifies-restores discards
    /// the snapshot, clears the marker, and settles to idle.
    func testCancelWithSucceedingRevertDiscardsSnapshotAndClearsMarker() async throws {
        let (repo, checkpoint) = try makeDirtyCheckpoint()
        let snapshot = try XCTUnwrap(checkpoint.untrackedSnapshotDir)

        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(repo: repo))
        app.recordingIsDevMode = true
        app.devAgentStarted = true
        app.devCheckpoint = checkpoint
        app.devCheckpointService = try GitCheckpointService(projectURL: repo) // real git
        app.state = .devAgentRunning

        // The agent edited the tree; the auto-revert should fully restore it.
        write(repo, "tracked.txt", "agent-edit\n")
        write(repo, "agent-new.txt", "new\n")

        app.cancelRecording()
        await settle({ app.state == .idle }, timeoutMs: 3000)

        XCTAssertEqual(app.state, .idle, "a verified revert settles to idle (happy path unchanged)")
        XCTAssertEqual(read(repo, "tracked.txt"), "v1-dirty\n", "tree restored to the checkpoint")
        XCTAssertEqual(read(repo, "untracked.txt"), "u1\n")
        XCTAssertFalse(exists(repo, "agent-new.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path),
                       "a successful revert discards the snapshot")
        XCTAssertNil(app.devRecoveryStore.load(), "a successful revert clears the marker")
        XCTAssertFalse(app.recordingIsDevMode, "dev state cleared after a verified revert")
    }

    // MARK: - Helpers

    /// Spin the main actor until `condition` holds or a short budget elapses.
    private func settle(_ condition: () -> Bool, timeoutMs: Int = 1000) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
    }

    /// A committed repo made DIRTY (uncommitted tracked change + an untracked file)
    /// then checkpointed → a stash snapshot commit + a real untracked snapshot dir.
    private func makeDirtyCheckpoint() throws -> (repo: URL, checkpoint: GitCheckpoint) {
        let repo = makeRepo()
        write(repo, "tracked.txt", "v1\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-m", "baseline")
        write(repo, "tracked.txt", "v1-dirty\n")   // dirty tracked
        write(repo, "untracked.txt", "u1\n")        // pre-existing untracked
        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        XCTAssertNotNil(checkpoint.stashSha)
        if let snap = checkpoint.untrackedSnapshotDir { snapshotDirs.append(snap) }
        return (repo, checkpoint)
    }

    private func sampleMarker(repo: URL) -> DevRecoveryMarker {
        DevRecoveryMarker(
            projectPath: repo.path, baseSha: "abc123", stashSha: nil,
            untrackedSnapshotPath: nil, untrackedRelativePaths: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), agentName: "Claude Code"
        )
    }

    private func makeRepo() -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-teardown-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        repos.append(repo)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "test@zerro.local")
        git(repo, "config", "user.name", "Zerro Test")
        git(repo, "config", "commit.gpgsign", "false")
        return repo
    }

    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-teardown-marker-\(UUID().uuidString).json")
        tempFiles.append(url)
        return url
    }

    @discardableResult
    private func git(_ repo: URL, _ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { XCTFail("git \(args) spawn failed: \(error)"); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 { XCTFail("git \(args.joined(separator: " ")) failed: \(out)") }
        return out
    }

    private func write(_ repo: URL, _ rel: String, _ contents: String) {
        let url = repo.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try contents.write(to: url, atomically: true, encoding: .utf8) }
        catch { XCTFail("write \(rel) failed: \(error)") }
    }

    private func read(_ repo: URL, _ rel: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
    }

    private func exists(_ repo: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(rel).path)
    }
}
