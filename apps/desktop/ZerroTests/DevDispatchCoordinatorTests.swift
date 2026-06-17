//
//  DevDispatchCoordinatorTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 6) — the dispatch orchestration. Uses a fake
//  DevAgentRunner (no real CLI) against a throwaway git repo to pin the
//  load-bearing invariants:
//    • a non-git folder fails gracefully as `.notAGitRepo` and NEVER dispatches
//      the agent (no checkpoint → no edit);
//    • success carries the checkpoint + a real diff stat;
//    • agent failure KEEPS the checkpoint (so Revert can use it) and does NOT
//      auto-revert (the partial edit is left on disk).
//

import XCTest
@testable import Zerro

@MainActor
final class DevDispatchCoordinatorTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-dispatch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try super.tearDownWithError()
    }

    private func agentEntry() -> DevAgentEntry {
        DevAgentEntry(
            id: "fake", displayName: "Fake", executableName: "fake",
            promptDelivery: .stdin, outputFormat: .streamJSON,
            baseArgs: [], editsOnlyArgs: [], allowCommandsArgs: [],
            installed: true, absolutePath: repo.appendingPathComponent("fake")
        )
    }

    // MARK: - Git-repo gate

    func testNonGitFolderFailsGracefullyWithoutDispatching() async throws {
        // `repo` was never `git init`'d.
        let runner = FakeRunner(result: .succeeded)
        let coordinator = DevDispatchCoordinator(runner: runner)

        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onPhase: { _ in }
        )

        guard case .failed(let failure, let checkpoint, let service, let diff) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(failure, .notAGitRepo)
        XCTAssertNil(checkpoint, "no checkpoint when the folder isn't a repo")
        XCTAssertNil(service)
        XCTAssertNil(diff, "no diff without a checkpoint")
        XCTAssertEqual(runner.runCount, 0, "must NOT dispatch the agent without a checkpoint")
    }

    // MARK: - Success

    func testSuccessCarriesCheckpointAndDiff() async throws {
        initRepo()
        write("app.css", ".btn { color: blue; }\n")
        git("add", "-A"); git("commit", "-m", "baseline")
        backdate("app.css")

        // The fake "agent" edits the tracked file after the checkpoint is taken.
        let runner = FakeRunner(result: .succeeded) { [repo] _ in
            try? ".btn { color: teal; }\n".write(
                to: repo!.appendingPathComponent("app.css"), atomically: true, encoding: .utf8
            )
        }
        let coordinator = DevDispatchCoordinator(runner: runner)

        let outcome = await coordinator.dispatch(
            prompt: "make it teal", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onPhase: { _ in }
        )

        guard case .succeeded(let success) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(runner.runCount, 1)
        XCTAssertEqual(success.diff.filesChanged, 1)
        XCTAssertEqual(success.diff.added, 1)
        XCTAssertEqual(success.diff.removed, 1)
        XCTAssertEqual(success.service.projectURL, repo)
    }

    // MARK: - Failure keeps the checkpoint, no auto-revert

    func testAgentFailureKeepsCheckpointAndLeavesEdits() async throws {
        initRepo()
        write("app.css", "blue\n")
        git("add", "-A"); git("commit", "-m", "baseline")
        backdate("app.css")

        // The agent edits the file then "fails" — the coordinator must NOT
        // revert (design §8); the edit stays and the checkpoint is retained.
        let runner = FakeRunner(result: .failed(.nonZeroExit(code: 1, stderrTail: "boom"))) { [repo] _ in
            try? "teal\n".write(
                to: repo!.appendingPathComponent("app.css"), atomically: true, encoding: .utf8
            )
        }
        let coordinator = DevDispatchCoordinator(runner: runner)

        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onPhase: { _ in }
        )

        guard case .failed(let failure, let checkpoint, let service, let diff) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(failure, .agent(.nonZeroExit(code: 1, stderrTail: "boom")))
        XCTAssertNotNil(checkpoint, "checkpoint kept so the user can Revert")
        XCTAssertNotNil(service)
        // No auto-revert: the partial edit is still on disk.
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("app.css"), encoding: .utf8), "teal\n")
        // M8: the partial-edit stat rides back for analytics (one file changed).
        XCTAssertEqual(diff?.filesChanged, 1)
    }

    // MARK: - Checkpoint surfacing + cancel (Milestone 7)

    func testSurfacesCheckpointBeforeDispatching() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b"); backdate("a.txt")

        // The checkpoint must be surfaced (so cancel/quit can revert) BEFORE the
        // agent runs.
        let order = PhaseRecorder()
        let sawCheckpoint = LockedFlag()
        let coordinator = DevDispatchCoordinator(runner: FakeRunner(result: .succeeded) { _ in
            // Agent side effect runs during `.dispatching`; the checkpoint must
            // already have been surfaced by then.
            XCTAssertTrue(sawCheckpoint.value, "checkpoint must be surfaced before the agent runs")
        })
        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onCheckpoint: { _, _ in sawCheckpoint.set(true) },
            onPhase: { order.append($0) }
        )
        guard case .succeeded = outcome else { return XCTFail("expected success") }
        XCTAssertTrue(sawCheckpoint.value)
    }

    func testCancelBeforeAgentSkipsDispatchButKeepsCheckpoint() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b"); backdate("a.txt")

        let runner = FakeRunner(result: .succeeded)
        let coordinator = DevDispatchCoordinator(runner: runner)
        // Cancel as soon as the checkpoint is surfaced (i.e. before the agent
        // would run) — the run must be skipped, but the checkpoint must ride
        // back so the caller can revert/teardown uniformly.
        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onCheckpoint: { _, _ in coordinator.cancel() },
            onPhase: { _ in }
        )
        guard case .failed(let failure, let checkpoint, let service, _) = outcome else {
            return XCTFail("expected cancelled failure, got \(outcome)")
        }
        XCTAssertEqual(failure, .agent(.cancelled))
        XCTAssertNotNil(checkpoint, "checkpoint kept so the caller can revert")
        XCTAssertNotNil(service)
        XCTAssertEqual(runner.runCount, 0, "agent must NOT run after a pre-dispatch cancel")
    }

    // MARK: - Phase reporting

    func testReportsCheckpointingThenDispatching() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b"); backdate("a.txt")

        let phases = PhaseRecorder()
        let coordinator = DevDispatchCoordinator(runner: FakeRunner(result: .succeeded))
        _ = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onPhase: { phases.append($0) }
        )
        let seen = phases.values()
        XCTAssertEqual(seen.first, .checkpointing)
        XCTAssertTrue(seen.contains(.dispatching))
    }

    // MARK: - Git + file helpers

    private func initRepo() {
        git("init", "-q")
        git("config", "user.email", "t@zerro.local")
        git("config", "user.name", "Zerro Test")
        git("config", "commit.gpgsign", "false")
    }

    @discardableResult
    private func git(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { XCTFail("git spawn: \(error)"); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func write(_ rel: String, _ contents: String) {
        try? contents.write(to: repo.appendingPathComponent(rel), atomically: true, encoding: .utf8)
    }

    private func backdate(_ rel: String) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: repo.appendingPathComponent(rel).path
        )
    }
}

// MARK: - Test doubles

/// A DevAgentRunner that records its call count and runs an optional side effect
/// (simulating the agent editing files), then returns a canned result.
private final class FakeRunner: DevAgentRunner, @unchecked Sendable {
    private let result: DevRunResult
    private let sideEffect: (@Sendable (URL) -> Void)?
    private let lock = NSLock()
    private var _runCount = 0
    var runCount: Int { lock.lock(); defer { lock.unlock() }; return _runCount }

    init(result: DevRunResult, sideEffect: (@Sendable (URL) -> Void)? = nil) {
        self.result = result
        self.sideEffect = sideEffect
    }

    func run(
        entry: DevAgentEntry,
        permission: DevAgentPermission,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        onSubstatus: @escaping @Sendable (DevRunSubstatus) -> Void
    ) async -> DevRunResult {
        lock.lock(); _runCount += 1; lock.unlock()
        sideEffect?(projectURL)
        return result
    }

    func cancel() {}
}

private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DevDispatchPhase] = []
    func append(_ p: DevDispatchPhase) { lock.lock(); items.append(p); lock.unlock() }
    func values() -> [DevDispatchPhase] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}
