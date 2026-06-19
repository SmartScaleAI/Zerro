//
//  DevAgentRunnerTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 4) — the agent runner's spawn / stream /
//  timeout / kill behavior, exercised with throwaway shell-script "agents" so
//  no real CLI is needed. Covers: clean success, non-zero exit (+ stderr tail),
//  the inactivity timeout (and the SIGTERM→SIGKILL path), the wall-clock
//  timeout, and the cap-1 concurrency rejection. Plus a unit pass over the
//  stream-json substatus parser.
//

import XCTest
@testable import Zerro

final class DevAgentRunnerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // NOT a `zerro-` prefix: a parallel worker's `WorkingDirectory.sweep()`
        // (PendingPaidGenerationTests) deletes every `zerro-*` temp dir, which
        // would remove these fake-agent scripts mid-run.
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-runner-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Outcomes

    func testCleanSuccess() async throws {
        let bin = try makeScript("success", """
        #!/bin/sh
        echo '{"type":"result"}'
        exit 0
        """)
        // Substatus is delivered fire-and-forget on the main queue, so asserting
        // a specific substatus right after run() returns is racy — the terminal
        // result is the contract here. The "result"→.done mapping is covered
        // deterministically by testParseStreamJSONLine.
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .succeeded)
    }

    func testNonZeroExitCarriesStderrTail() async throws {
        let bin = try makeScript("fail", """
        #!/bin/sh
        echo "kaboom" 1>&2
        exit 3
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(code: 3, stderrTail: "kaboom")))
    }

    func testInactivityTimeoutKillsHungAgent() async throws {
        // No output, sleeps well past the inactivity cap → must be killed.
        let bin = try makeScript("hang", """
        #!/bin/sh
        sleep 30
        """)
        let start = Date()
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(wallClock: 30, inactivity: 1, killGrace: 1),
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .failed(.timeout(.inactivity)))
        // Should resolve promptly (cap 1s + grace 1s), not after the 30s sleep.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testWallClockTimeoutFiresDespiteContinuousOutput() async throws {
        // Streams constantly (inactivity never trips) but never exits → the
        // wall-clock cap must terminate it.
        let bin = try makeScript("chatty", """
        #!/bin/sh
        while true; do echo '{"type":"system"}'; sleep 0.2; done
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(wallClock: 1, inactivity: 10, killGrace: 1),
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .failed(.timeout(.wallClock)))
    }

    func testSecondConcurrentRunIsRejected() async throws {
        let bin = try makeScript("slow", """
        #!/bin/sh
        sleep 1
        exit 0
        """)
        let runner = ClaudeCodeAgentRunner()
        let e = entry(path: bin, format: .streamJSON)

        async let first = runner.run(
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(wallClock: 30, inactivity: 10, killGrace: 1),
            onSubstatus: { _ in }
        )
        // Let the first run acquire the cap-1 flag.
        try await Task.sleep(nanoseconds: 250_000_000)
        let second = await runner.run(
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onSubstatus: { _ in }
        )
        XCTAssertEqual(second, .failed(.busy))
        let firstResult = await first
        XCTAssertEqual(firstResult, .succeeded)
    }

    func testCancelTerminatesRunningAgent() async throws {
        // Streams (so it's clearly alive) but never exits → only cancel ends it.
        let bin = try makeScript("cancelme", """
        #!/bin/sh
        while true; do echo '{"type":"system"}'; sleep 0.2; done
        """)
        let runner = ClaudeCodeAgentRunner()
        let e = entry(path: bin, format: .streamJSON)
        let start = Date()

        async let runResult = runner.run(
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
            // Long caps so neither timeout fires — the cancel must be what ends it.
            timeouts: DevRunTimeouts(wallClock: 60, inactivity: 60, killGrace: 1),
            onSubstatus: { _ in }
        )
        // Let the process spawn + start streaming, then cancel.
        try await Task.sleep(nanoseconds: 400_000_000)
        runner.cancel()

        let result = await runResult
        XCTAssertEqual(result, .failed(.cancelled))
        // Resolves on the SIGTERM (well under the 60s caps).
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testCancelWhenIdleIsHarmless() {
        // No run in flight → cancel is a no-op, must not crash.
        ClaudeCodeAgentRunner().cancel()
    }

    func testMissingExecutablePathFailsToSpawn() async throws {
        var e = entry(path: scratch.appendingPathComponent("does-not-exist"), format: .streamJSON)
        e = DevAgentEntry(
            id: e.id, displayName: e.displayName, executableName: e.executableName,
            promptDelivery: e.promptDelivery, outputFormat: e.outputFormat,
            baseArgs: e.baseArgs, editsOnlyArgs: e.editsOnlyArgs,
            allowCommandsArgs: e.allowCommandsArgs,
            installed: false, absolutePath: nil
        )
        let result = await ClaudeCodeAgentRunner().run(
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
            onSubstatus: { _ in }
        )
        guard case .failed(.spawnFailed) = result else {
            return XCTFail("expected .spawnFailed, got \(result)")
        }
    }

    // MARK: - Parser

    func testParseStreamJSONLine() {
        XCTAssertEqual(ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(#"{"type":"result"}"#), .done)
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/proj/src/App.css"}}]}}"#),
            .editing(file: "App.css")
        )
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"x"}}]}}"#),
            .readingFiles
        )
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#),
            .running
        )
        // `Agent` is the current subagent tool name (verified at M9); maps like
        // the old `Task`.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}"#),
            .running
        )
        // Write carries `file_path` like Edit.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/p/src/index.html"}}]}}"#),
            .editing(file: "index.html")
        )
        // An unknown/future tool degrades to "working…", never nil-crashes.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SomeFutureTool","input":{}}]}}"#),
            .working
        )
        // Non-progress / garbage lines yield no substatus.
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(#"{"type":"system"}"#))
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamJSONLineForTesting("not json"))
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(""))
    }

    // MARK: - Helpers

    private func fastTimeouts() -> DevRunTimeouts {
        DevRunTimeouts(wallClock: 30, inactivity: 10, killGrace: 1)
    }

    private func entry(path: URL, format: DevAgentOutputFormat) -> DevAgentEntry {
        DevAgentEntry(
            id: "fake", displayName: "Fake", executableName: path.lastPathComponent,
            promptDelivery: .stdin, outputFormat: format,
            baseArgs: [], editsOnlyArgs: [], allowCommandsArgs: [],
            installed: true, absolutePath: path
        )
    }

    private func makeScript(_ name: String, _ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("\(name).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
