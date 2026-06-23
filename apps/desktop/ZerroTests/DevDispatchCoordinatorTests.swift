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
        let runner = FakeRunner(result: .succeeded(summary: nil))
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

        // The fake "agent" edits the tracked file after the checkpoint is taken
        // and reports a closing summary (threaded out as `success.summary`).
        let runner = FakeRunner(result: .succeeded(summary: "Recolored the button.")) { [repo] _ in
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
        // Part A: the agent's summary rides out on the success.
        XCTAssertEqual(success.summary, "Recolored the button.")
        // Part B: the readable unified diff rides out too, showing the edit.
        XCTAssertTrue(success.diffText.contains("app.css"), "diffText should name the file:\n\(success.diffText)")
        XCTAssertTrue(success.diffText.contains("+.btn { color: teal; }"), "diffText should show the edit:\n\(success.diffText)")
    }

    func testDispatchThreadsSelectedModelToRunner() async throws {
        initRepo()
        write("app.css", ".btn { color: blue; }\n")
        git("add", "-A"); git("commit", "-m", "baseline")

        let runner = FakeRunner(result: .succeeded(summary: nil))
        let coordinator = DevDispatchCoordinator(runner: runner)

        _ = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            model: "claude-opus-4-8",
            onPhase: { _ in }
        )
        // Phase 2: the selected model is forwarded to the runner verbatim.
        XCTAssertEqual(runner.lastModel, "claude-opus-4-8")
    }

    // MARK: - Do-not-commit guard is appended to every dispatched prompt

    func testDispatchAppendsNoCommitGuardToPrompt() async throws {
        initRepo()
        write("app.css", ".btn { color: blue; }\n")
        git("add", "-A"); git("commit", "-m", "baseline")

        let runner = FakeRunner(result: .succeeded(summary: nil))
        let coordinator = DevDispatchCoordinator(runner: runner)

        let spec = "Goal: recolor the button\n\nChanges:\n1. blue -> teal"
        _ = await coordinator.dispatch(
            prompt: spec, projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onPhase: { _ in }
        )

        let dispatched = try XCTUnwrap(runner.lastPrompt, "the runner must have been handed a prompt")
        // The original change spec rides through verbatim …
        XCTAssertTrue(dispatched.contains(spec),
                      "the generated change spec must be preserved:\n\(dispatched)")
        // … and the do-not-commit invariant is appended as the closing block.
        XCTAssertTrue(dispatched.contains(DevDispatchCoordinator.noCommitInstruction),
                      "the do-not-commit guard must be appended:\n\(dispatched)")
        XCTAssertTrue(dispatched.hasSuffix(DevDispatchCoordinator.noCommitInstruction),
                      "the guard belongs at the end so it's the last thing the agent reads")
        // Spot-check the guard actually forbids the publishing commands.
        for forbidden in ["git commit", "git push", "git add"] {
            XCTAssertTrue(dispatched.contains(forbidden),
                          "the guard must explicitly forbid `\(forbidden)`")
        }
    }

    // MARK: - Stale index lock maps to the actionable failure

    func testStaleIndexLockFailsAsIndexLockedWithoutDispatching() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b")
        write("a.txt", "x\ndirty\n") // dirty so the checkpoint must write the index

        // An interrupted-run leftover lock blocks the checkpoint's snapshot.
        let lock = repo.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: lock) }

        let runner = FakeRunner(result: .succeeded(summary: nil))
        let coordinator = DevDispatchCoordinator(runner: runner)
        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onPhase: { _ in }
        )

        guard case .failed(let failure, let checkpoint, _, _) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(failure, .indexLocked, "a stale lock surfaces the actionable lock failure")
        XCTAssertNil(checkpoint, "no checkpoint when the snapshot couldn't be taken")
        XCTAssertEqual(runner.runCount, 0, "the agent must NOT run without a checkpoint")
        // The user-facing message carries the one-line fix.
        XCTAssertTrue(failure.userMessage.contains("rm -f .git/index.lock"),
                      "the lock failure must give the fix: \(failure.userMessage)")
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
        let coordinator = DevDispatchCoordinator(runner: FakeRunner(result: .succeeded(summary: nil)) { _ in
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

        let runner = FakeRunner(result: .succeeded(summary: nil))
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

    // MARK: - Pre-edit confirm gate (Ask Permission review)

    func testConfirmGateDeclineSkipsTheAgentAfterCheckpoint() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b"); backdate("a.txt")

        let runner = FakeRunner(result: .succeeded(summary: nil))
        let coordinator = DevDispatchCoordinator(runner: runner)
        // The gate runs AFTER the checkpoint, BEFORE the agent. A declined gate
        // aborts with the checkpoint (so the caller discards it) and the agent
        // NEVER runs.
        var checkpointSurfaced = false
        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            onCheckpoint: { _, _ in checkpointSurfaced = true },
            confirmGate: {
                XCTAssertTrue(checkpointSurfaced, "the gate runs AFTER the checkpoint (§8)")
                return false // user declined
            },
            onPhase: { _ in }
        )
        guard case .failed(let failure, let checkpoint, let service, _) = outcome else {
            return XCTFail("expected declined failure, got \(outcome)")
        }
        XCTAssertEqual(failure, .confirmDeclined)
        XCTAssertNotNil(checkpoint, "checkpoint rides back so the caller can discard it")
        XCTAssertNotNil(service)
        XCTAssertEqual(runner.runCount, 0, "agent must NOT run when the gate is declined")
    }

    func testConfirmGateAcceptRunsTheAgent() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b"); backdate("a.txt")

        let runner = FakeRunner(result: .succeeded(summary: nil))
        let coordinator = DevDispatchCoordinator(runner: runner)
        let outcome = await coordinator.dispatch(
            prompt: "go", projectURL: repo, agent: agentEntry(), permission: .editsOnly,
            confirmGate: { true }, // user confirmed
            onPhase: { _ in }
        )
        guard case .succeeded = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(runner.runCount, 1, "agent runs after the gate is confirmed")
    }

    // MARK: - Phase reporting

    func testReportsCheckpointingThenDispatching() async throws {
        initRepo()
        write("a.txt", "x\n"); git("add", "-A"); git("commit", "-m", "b"); backdate("a.txt")

        let phases = PhaseRecorder()
        let coordinator = DevDispatchCoordinator(runner: FakeRunner(result: .succeeded(summary: nil)))
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
    private var _lastModel: String?
    private var _lastPrompt: String?
    var runCount: Int { lock.lock(); defer { lock.unlock() }; return _runCount }
    /// The `model` forwarded on the most recent run (Phase 2) — lets a test
    /// assert the dispatch threads the selected model through to the runner.
    var lastModel: String? { lock.lock(); defer { lock.unlock() }; return _lastModel }
    /// The exact `prompt` forwarded on the most recent run — lets a test assert
    /// the dispatch appends the do-not-commit guard to the change spec.
    var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return _lastPrompt }

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
        model: String?,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void,
        onStall: @escaping @Sendable (Bool) -> Void
    ) async -> DevRunResult {
        lock.lock(); _runCount += 1; _lastModel = model; _lastPrompt = prompt; lock.unlock()
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
