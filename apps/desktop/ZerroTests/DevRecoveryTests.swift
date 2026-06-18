//
//  DevRecoveryTests.swift
//  ZerroTests
//
//  Dev Mode quit-recovery (cross-launch undo). Covers the deterministic units
//  behind offering an Undo for a dispatch a quit (⌘Q / kill -9) interrupted
//  mid-edit:
//    • DevRecoveryMarker Codable round-trip + checkpoint reconstruction.
//    • DevRecoveryStore save/load/clear against an isolated temp file (no global
//      Application Support bleed).
//    • The Part 3 validation matrix → offered vs cleared. Every non-happy case
//      (missing project, non-repo, unresolvable restore ref, missing untracked
//      snapshot dir, zero diff) must CLEAR the marker and make NO offer — the
//      non-destructive default (keeping the edits is the safe failure).
//    • The Part 5 state machine: a seeded valid marker → `.confirmingDevRecovery`;
//      `resolveDevRecovery(undo:true)` reverts + clears + idle; `undo:false` keeps
//      (no revert) + clears + idle.
//    • The Part 2 marker-lifetime guards on `prepareForTermination`: a mid-dispatch
//      quit KEEPS the marker (recoverable); a `.confirmAnchors` quit leaves NONE;
//      the offer state keeps it (re-offer next launch); teardown clears it.
//
//  The real marker WRITE at dispatch start (applyDevPhase(.dispatching), after the
//  confirm gate) is driven by the coordinator/runner and exercised by the manual
//  kill test in the handoff (Part 6), not here — AppState's coordinator isn't
//  injectable.
//

import XCTest
@testable import Zerro

@MainActor
final class DevRecoveryTests: XCTestCase {

    private var repos: [URL] = []
    private var tempFiles: [URL] = []
    private var snapshotDirs: [URL] = []

    override func tearDownWithError() throws {
        for url in repos + tempFiles + snapshotDirs { try? FileManager.default.removeItem(at: url) }
        repos = []; tempFiles = []; snapshotDirs = []
    }

    // MARK: - Marker round-trip

    func testMarkerCodableRoundTrip() throws {
        let marker = DevRecoveryMarker(
            projectPath: "/tmp/proj",
            baseSha: "abc123",
            stashSha: "def456",
            untrackedSnapshotPath: "/tmp/dev-checkpoint-x",
            untrackedRelativePaths: ["a.txt", "sub/b.txt"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            agentName: "Claude Code"
        )
        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(DevRecoveryMarker.self, from: data)
        XCTAssertEqual(decoded, marker)
    }

    func testMarkerReconstructsCheckpointAndURLs() {
        let marker = DevRecoveryMarker(
            projectPath: "/tmp/proj",
            baseSha: "base",
            stashSha: "stash",
            untrackedSnapshotPath: "/tmp/snap",
            untrackedRelativePaths: ["x"],
            createdAt: Date(),
            agentName: nil
        )
        let cp = marker.checkpoint
        XCTAssertEqual(cp.baseSha, "base")
        XCTAssertEqual(cp.stashSha, "stash")
        XCTAssertEqual(cp.untrackedSnapshotDir?.path, "/tmp/snap")
        XCTAssertEqual(cp.untrackedRelativePaths, ["x"])
        XCTAssertEqual(cp.restoreRef, "stash") // stash wins over base
        XCTAssertEqual(marker.projectURL.path, "/tmp/proj")
    }

    func testMarkerNilSnapshotReconstructsNilDir() {
        let marker = DevRecoveryMarker(
            projectPath: "/p", baseSha: "b", stashSha: nil,
            untrackedSnapshotPath: nil, untrackedRelativePaths: [],
            createdAt: Date(), agentName: nil
        )
        XCTAssertNil(marker.checkpoint.untrackedSnapshotDir)
        XCTAssertEqual(marker.checkpoint.restoreRef, "b") // no stash → HEAD base
    }

    // MARK: - Store save / load / clear

    func testStoreSaveLoadClearIsolated() throws {
        let file = makeTempFile()
        let store = DevRecoveryStore(fileURL: file)
        XCTAssertNil(store.load(), "empty store loads nil")

        let marker = sampleMarker(projectPath: "/tmp/p")
        store.save(marker)
        XCTAssertEqual(store.load(), marker, "saved marker round-trips through the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.clear()
        XCTAssertNil(store.load(), "cleared store loads nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStoreClearIsIdempotent() {
        let store = DevRecoveryStore(fileURL: makeTempFile())
        store.clear() // nothing saved
        XCTAssertNil(store.load())
    }

    // MARK: - Validation matrix → OFFERED

    func testValidMarkerIsOffered() async throws {
        let (repo, checkpoint) = try makeDirtyCheckpoint()
        // Agent-like edits so the diff vs the checkpoint is non-empty.
        write(repo, "tracked.txt", "agent-edit\n")
        write(repo, "agent-new.txt", "new\n")

        let app = makeApp(savingMarker: marker(checkpoint, repo: repo, agent: "Claude Code"))
        let offered = await app.recoverInterruptedDevCheckpointIfAny()

        XCTAssertTrue(offered, "a valid, non-empty checkpoint must be offered")
        XCTAssertEqual(app.state, .confirmingDevRecovery)
        XCTAssertNotNil(app.devRecoveryStore.load(), "the marker stays on disk while the offer is open")
        XCTAssertNotNil(app.pendingDevRecovery)
        XCTAssertGreaterThan(app.pendingDevRecovery?.diffStat.filesChanged ?? 0, 0)
        XCTAssertEqual(app.pendingDevRecovery?.agentName, "Claude Code")
    }

    // MARK: - Validation matrix → CLEARED (no offer)

    func testMissingProjectClearsAndDoesNotOffer() async throws {
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-recovery-test-gone-\(UUID().uuidString)")
        let m = DevRecoveryMarker(
            projectPath: phantom.path, baseSha: "abc", stashSha: nil,
            untrackedSnapshotPath: nil, untrackedRelativePaths: [],
            createdAt: Date(), agentName: nil
        )
        try await assertClearedNoOffer(m)
    }

    func testNonRepoClearsAndDoesNotOffer() async throws {
        // A real directory that was never `git init`'d.
        let dir = makeBareDir()
        let m = DevRecoveryMarker(
            projectPath: dir.path, baseSha: "abc", stashSha: nil,
            untrackedSnapshotPath: nil, untrackedRelativePaths: [],
            createdAt: Date(), agentName: nil
        )
        try await assertClearedNoOffer(m)
    }

    func testUnresolvableRestoreRefClearsAndDoesNotOffer() async throws {
        let (repo, checkpoint) = try makeDirtyCheckpoint()
        write(repo, "tracked.txt", "agent-edit\n")
        // A real repo, but the restore ref is a bogus dangling sha (as if the
        // stash-create commit had been GC'd) → `git diff <ref>` throws.
        var m = marker(checkpoint, repo: repo)
        m.stashSha = "0000000000000000000000000000000000000000"
        try await assertClearedNoOffer(m)
    }

    func testMissingUntrackedSnapshotDirClearsAndDoesNotOffer() async throws {
        let (repo, checkpoint) = try makeDirtyCheckpoint()
        write(repo, "tracked.txt", "agent-edit\n")
        // The dirty checkpoint captured untracked files into a snapshot dir; a
        // reboot that cleared $TMPDIR would delete it. Simulate by removing it.
        let snapshot = try XCTUnwrap(checkpoint.untrackedSnapshotDir)
        try FileManager.default.removeItem(at: snapshot)
        try await assertClearedNoOffer(marker(checkpoint, repo: repo))
    }

    func testZeroDiffClearsAndDoesNotOffer() async throws {
        // A checkpoint with NO subsequent edits → diffStat is empty → nothing to
        // undo → clear, no offer.
        let (repo, checkpoint) = try makeCleanCheckpoint()
        try await assertClearedNoOffer(marker(checkpoint, repo: repo))
    }

    func testNonIdleStateLeavesMarkerForNextLaunch() async throws {
        let (repo, checkpoint) = try makeDirtyCheckpoint()
        write(repo, "tracked.txt", "agent-edit\n")
        let app = makeApp(savingMarker: marker(checkpoint, repo: repo))
        // Not idle (e.g. a restored paid-block recording) → no-op, marker kept.
        app.state = .failed(reason: .outOfCredits)

        let offered = await app.recoverInterruptedDevCheckpointIfAny()

        XCTAssertFalse(offered)
        XCTAssertNotNil(app.devRecoveryStore.load(), "a non-idle launch must leave the marker for the next launch")
    }

    // MARK: - Resolve: Undo

    func testResolveUndoRevertsClearsAndIdles() async throws {
        let (repo, checkpoint) = try makeCleanCheckpoint("v1\n")
        // Agent edited the tracked file after the checkpoint.
        write(repo, "tracked.txt", "agent-edit\n")
        let app = makeApp(savingMarker: marker(checkpoint, repo: repo))

        let offered = await app.recoverInterruptedDevCheckpointIfAny()
        XCTAssertTrue(offered)

        app.resolveDevRecovery(undo: true)
        // Undo reverts off-main: it passes through .devReverting, then settles idle.
        await settle { app.state == .idle }

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(read(repo, "tracked.txt"), "v1\n", "Undo must restore the pre-run tree")
        XCTAssertNil(app.devRecoveryStore.load(), "marker cleared after Undo")
        XCTAssertNil(app.pendingDevRecovery)
    }

    // MARK: - Resolve: Keep

    func testResolveKeepRetainsEditsClearsAndIdles() async throws {
        let (repo, checkpoint) = try makeCleanCheckpoint("v1\n")
        write(repo, "tracked.txt", "agent-edit\n")
        let app = makeApp(savingMarker: marker(checkpoint, repo: repo))

        let offered = await app.recoverInterruptedDevCheckpointIfAny()
        XCTAssertTrue(offered)

        app.resolveDevRecovery(undo: false)

        XCTAssertEqual(app.state, .idle, "Keep is synchronous — straight to idle")
        XCTAssertEqual(read(repo, "tracked.txt"), "agent-edit\n", "Keep must retain the agent's edits")
        XCTAssertNil(app.devRecoveryStore.load(), "marker cleared after Keep")
        XCTAssertNil(app.pendingDevRecovery)
    }

    func testResolveIsNoOpOutsideConfirmingDevRecovery() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
        app.state = .idle

        app.resolveDevRecovery(undo: true)

        XCTAssertEqual(app.state, .idle, "no-op outside .confirmingDevRecovery")
        XCTAssertNotNil(app.devRecoveryStore.load(), "an unrelated marker is untouched")
    }

    // MARK: - Marker lifetime guards (prepareForTermination)

    func testQuitMidDispatchKeepsMarker() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
        // A dispatch in flight — the agent may have edited, so the marker (the only
        // cross-launch undo) MUST survive the quit.
        for s in [RecordingState.devCheckpointing, .devAgentDispatching, .devAgentRunning] {
            app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
            app.state = s
            app.prepareForTermination()
            XCTAssertNotNil(app.devRecoveryStore.load(), "\(s): a mid-dispatch quit must keep the marker")
        }
    }

    func testQuitAtConfirmAnchorsLeavesNoMarker() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        // Belt-and-suspenders: even if a marker somehow existed at the gate, the
        // .confirmAnchors quit branch discards the snapshot and clears it — no
        // marker may survive pointing at a discarded snapshot.
        app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
        app.state = .confirmAnchors
        app.prepareForTermination()
        XCTAssertNil(app.devRecoveryStore.load(), "a .confirmAnchors quit must leave no marker")
    }

    func testQuitAtDevDoneKeepsMarker() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
        // .devDone keeps the checkpoint alive (the in-session Undo is still
        // available), so a quit there is still recoverable across launch.
        app.state = .devDone
        app.prepareForTermination()
        XCTAssertNotNil(app.devRecoveryStore.load(), "a .devDone quit must keep the marker")
    }

    func testQuitWhileOfferingKeepsMarkerForReoffer() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
        app.state = .confirmingDevRecovery
        app.prepareForTermination()
        XCTAssertNotNil(app.devRecoveryStore.load(), "quitting past the offer must re-present it next launch")
    }

    func testTeardownClearsMarker() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(sampleMarker(projectPath: "/tmp/p"))
        app.state = .idle // not dev-busy → resetToIdle runs the plain teardown
        app.resetToIdle()
        XCTAssertNil(app.devRecoveryStore.load(), "every teardown clears the marker")
    }

    // MARK: - Helpers (AppState + assertions)

    private func makeApp(savingMarker marker: DevRecoveryMarker) -> AppState {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        app.devRecoveryStore.save(marker)
        return app
    }

    /// Run recovery against `marker` and assert it cleared the marker and made no
    /// offer (the non-destructive default for every stale/missing case).
    private func assertClearedNoOffer(_ marker: DevRecoveryMarker,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let app = makeApp(savingMarker: marker)
        let offered = await app.recoverInterruptedDevCheckpointIfAny()
        XCTAssertFalse(offered, "must not offer", file: file, line: line)
        XCTAssertEqual(app.state, .idle, "must stay idle", file: file, line: line)
        XCTAssertNil(app.devRecoveryStore.load(), "must clear the marker", file: file, line: line)
        XCTAssertNil(app.pendingDevRecovery, file: file, line: line)
    }

    private func sampleMarker(projectPath: String) -> DevRecoveryMarker {
        // A WHOLE-second timestamp: the store encodes dates at second precision
        // (.secondsSince1970, like the codebase's other on-disk stores), so a
        // fractional `Date()` would drift on round-trip and make exact-equality
        // comparison non-deterministic. A whole second is exactly representable.
        DevRecoveryMarker(
            projectPath: projectPath, baseSha: "abc123", stashSha: nil,
            untrackedSnapshotPath: nil, untrackedRelativePaths: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), agentName: "Claude Code"
        )
    }

    private func marker(_ cp: GitCheckpoint, repo: URL, agent: String? = nil) -> DevRecoveryMarker {
        DevRecoveryMarker(
            projectPath: repo.path,
            baseSha: cp.baseSha,
            stashSha: cp.stashSha,
            untrackedSnapshotPath: cp.untrackedSnapshotDir?.path,
            untrackedRelativePaths: cp.untrackedRelativePaths,
            createdAt: Date(),
            agentName: agent
        )
    }

    // MARK: - Git fixtures

    /// A committed repo + a checkpoint of the CLEAN tree (restoreRef = HEAD).
    private func makeCleanCheckpoint(_ contents: String = "v1\n") throws -> (repo: URL, checkpoint: GitCheckpoint) {
        let repo = makeRepo()
        write(repo, "tracked.txt", contents)
        git(repo, "add", "-A")
        git(repo, "commit", "-m", "baseline")
        backdate(repo, "tracked.txt")
        let service = try GitCheckpointService(projectURL: repo)
        let checkpoint = try service.checkpoint()
        if let snap = checkpoint.untrackedSnapshotDir { snapshotDirs.append(snap) }
        return (repo, checkpoint)
    }

    /// A committed repo made DIRTY (uncommitted tracked change + an untracked
    /// file) then checkpointed → a stash snapshot commit + a real untracked
    /// snapshot dir.
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
        let snap = try XCTUnwrap(checkpoint.untrackedSnapshotDir)
        snapshotDirs.append(snap)
        return (repo, checkpoint)
    }

    private func makeRepo() -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-recovery-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        repos.append(repo)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "test@zerro.local")
        git(repo, "config", "user.name", "Zerro Test")
        git(repo, "config", "commit.gpgsign", "false")
        return repo
    }

    private func makeBareDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-recovery-test-bare-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repos.append(dir)
        return dir
    }

    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-recovery-marker-\(UUID().uuidString).json")
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

    private func backdate(_ repo: URL, _ rel: String) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: repo.appendingPathComponent(rel).path
        )
    }

    private func settle(_ condition: () -> Bool, timeoutMs: Int = 2000) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
    }
}
