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
        // No `result` text in this event → summary is nil (the UI then falls back
        // to a generated change line; Part A).
        XCTAssertEqual(result, .succeeded(summary: nil))
    }

    func testSuccessCapturesResultSummary() async throws {
        // A terminal `result` event carrying the agent's closing text → that text
        // rides out on `.succeeded(summary:)` (Part A).
        let bin = try makeScript("summary", """
        #!/bin/sh
        echo '{"type":"result","result":"Updated the login screen layout."}'
        exit 0
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: "Updated the login screen layout."))
    }

    func testArgumentDeliveryAppendsPromptToArgvAndClosesStdin() async throws {
        // Codex-style `.argument` delivery: the prompt rides as the LAST argv
        // element (after the flags + --model) and stdin is closed empty.
        let bin = try makeScript("argcap", """
        #!/bin/sh
        printf '%s\\n' "$@" > "$PWD/argv.txt"
        cat > "$PWD/stdin.txt"
        exit 0
        """)
        let e = DevAgentEntry(
            id: "codexlike", displayName: "X", executableName: bin.lastPathComponent,
            promptDelivery: .argument, outputFormat: .text,
            baseArgs: ["exec", "--skip-git-repo-check"],
            editsOnlyArgs: ["--sandbox", "workspace-write"], allowCommandsArgs: [],
            installed: true, absolutePath: bin, modelFlagName: "--model"
        )
        let result = await ClaudeCodeAgentRunner().run(
            entry: e, permission: .editsOnly, prompt: "make it teal",
            projectURL: scratch, timeouts: fastTimeouts(), model: "gpt-5.5",
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: nil))
        let argv = try String(contentsOf: scratch.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--model", "gpt-5.5", "make it teal"])
        let stdin = try String(contentsOf: scratch.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.isEmpty, "argument delivery must not write the prompt to stdin")
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
        XCTAssertEqual(firstResult, .succeeded(summary: nil))
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

    func testParseStreamJSONLineCursorToolCalls() {
        // Cursor rides tool activity in its OWN `tool_call` event (distinct from
        // Claude's `assistant.tool_use`), emitting on the `started` twin.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"/private/tmp/proj/README.md"}},"toolCallId":"t","startedAtMs":"1"}}"#),
            .editing(file: "README.md")
        )
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"x"}},"toolCallId":"t"}}"#),
            .readingFiles
        )
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"echo hi"}},"toolCallId":"t"}}"#),
            .running
        )
        // The `completed` twin must NOT re-emit (the `started` one already did).
        XCTAssertNil(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"tool_call","subtype":"completed","tool_call":{"editToolCall":{"args":{"path":"/p/README.md"}}}}"#))
        // An unknown/future tool kind degrades to "working…", never nil-crashes.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"tool_call","subtype":"started","tool_call":{"frobToolCall":{"args":{}}}}"#),
            .working
        )
        // Cursor's terminal `result` event maps to `.done` like Claude's (shared).
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
                #"{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"inputTokens":1}}"#),
            .done
        )
        // Cursor's other top-level events carry no progress signal.
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(#"{"type":"thinking","subtype":"delta","text":"…"}"#))
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll edit it."}]}}"#))
        // Regression guard: the Claude Code branch is unchanged — its tool_use
        // mapping is still covered exhaustively by testParseStreamJSONLine above.
    }

    func testParseResultSummaryCursorResultEvent() {
        // Cursor's `result` event carries extra fields (duration_ms, usage, …) but
        // the same `result` summary string the existing parser reads.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultSummaryForTesting(
                #"{"type":"result","subtype":"success","duration_ms":8144,"is_error":false,"result":"  Appended the line.  ","usage":{"inputTokens":1}}"#),
            "Appended the line."
        )
    }

    func testCursorArgumentDeliveryArgv() async throws {
        // The Cursor entry's contract, end-to-end through the runner: prompt rides
        // as the LAST argv element (positional `.argument`), stdin is closed empty,
        // and --force (allow-commands) + --model are threaded in order.
        let bin = try makeScript("cursorlike", """
        #!/bin/sh
        printf '%s\\n' "$@" > "$PWD/argv.txt"
        cat > "$PWD/stdin.txt"
        echo '{"type":"result","subtype":"success","result":"ok"}'
        exit 0
        """)
        let e = DevAgentEntry(
            id: "cursorlike", displayName: "Cursor", executableName: bin.lastPathComponent,
            promptDelivery: .argument, outputFormat: .streamJSON,
            baseArgs: ["-p", "--output-format", "stream-json", "--trust"],
            editsOnlyArgs: [], allowCommandsArgs: ["--force"],
            installed: true, absolutePath: bin, modelFlagName: "--model"
        )
        let result = await ClaudeCodeAgentRunner().run(
            entry: e, permission: .allowCommands, prompt: "make this button bigger",
            projectURL: scratch, timeouts: fastTimeouts(), model: "claude-opus-4-8-high",
            onSubstatus: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: "ok"))
        let argv = try String(contentsOf: scratch.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, ["-p", "--output-format", "stream-json", "--trust", "--force",
                              "--model", "claude-opus-4-8-high", "make this button bigger"])
        let stdin = try String(contentsOf: scratch.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.isEmpty, "argument delivery must not write the prompt to stdin")
    }

    func testParseResultSummary() {
        // A `result` event with text → the trimmed text.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultSummaryForTesting(
                #"{"type":"result","result":"  Reworked the nav.  "}"#),
            "Reworked the nav."
        )
        // A `result` event with no `result` field, or an empty one → nil.
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultSummaryForTesting(#"{"type":"result"}"#))
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultSummaryForTesting(#"{"type":"result","result":"   "}"#))
        // A non-result event never yields a summary.
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultSummaryForTesting(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#))
        // Garbage degrades to nil, never crashes.
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultSummaryForTesting("not json"))
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultSummaryForTesting(""))
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
