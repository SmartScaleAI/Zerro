//
//  DevAgentRunnerTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 4 + Phase 4) — the agent runner's spawn / stream
//  / stall-notify behavior, exercised with throwaway shell-script "agents" so no
//  real CLI is needed. Covers: clean success, non-zero exit (+ stderr tail), the
//  cap-1 concurrency rejection, user cancel as the SOLE terminator, and — Phase 4
//  — the stall watchdog that NOTIFIES without ever killing the process. Plus a
//  unit pass over the stream-json event parser.
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
        // Events are delivered fire-and-forget on the main queue, so asserting a
        // specific event right after run() returns is racy — the terminal result
        // is the contract here. The "result"→.done mapping is covered
        // deterministically by testParseStreamJSONLine.
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
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
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: "Updated the login screen layout."))
    }

    func testArgumentDeliveryAppendsPromptToArgvAndClosesStdin() async throws {
        // Codex-style `.argument` delivery: the prompt rides as the LAST argv
        // element (after the tier flags + --model + the G-05 `--` end-of-options
        // separator) and stdin is closed empty. Every tier maps to
        // commands-enabled, so the posture flags live in `allowCommandsArgs`;
        // `.unrestricted` adds no MCP-disable flags.
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
            editsOnlyArgs: [], allowCommandsArgs: ["--sandbox", "danger-full-access"],
            installed: true, absolutePath: bin, modelFlagName: "--model"
        )
        let result = await ClaudeCodeAgentRunner().run(
            entry: e, tier: .unrestricted, prompt: "make it teal",
            projectURL: scratch, timeouts: fastTimeouts(), model: "gpt-5.5",
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: nil))
        let argv = try String(contentsOf: scratch.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, ["exec", "--skip-git-repo-check", "--sandbox", "danger-full-access", "--model", "gpt-5.5", "--", "make it teal"])
        let stdin = try String(contentsOf: scratch.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.isEmpty, "argument delivery must not write the prompt to stdin")
    }

    func testEndOfOptionsSeparatorGuardsDashLeadingPrompts() async throws {
        // G-05: `.argument` delivery must emit `--` IMMEDIATELY before the
        // positional prompt, so a prompt starting with '-'/'--' (or matching a
        // subcommand like codex exec's `resume`) can never be parsed as a flag
        // by the agent's own CLI parser. argv goes straight to posix_spawn (no
        // shell), so the separator is the whole defense. Live-verified that
        // codex exec 0.140.0 and cursor-agent 2026.06.24 both honor `--`.
        let bin = try makeScript("dashcap", """
        #!/bin/sh
        printf '%s\\n' "$@" > "$PWD/argv.txt"
        cat > /dev/null
        exit 0
        """)
        let e = DevAgentEntry(
            id: "dashy", displayName: "X", executableName: bin.lastPathComponent,
            promptDelivery: .argument, outputFormat: .text,
            baseArgs: ["exec"], editsOnlyArgs: [], allowCommandsArgs: [],
            installed: true, absolutePath: bin
        )
        let result = await ClaudeCodeAgentRunner().run(
            entry: e, tier: .unrestricted, prompt: "--version",
            projectURL: scratch, timeouts: fastTimeouts(), onEvent: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: nil))
        let argv = try String(contentsOf: scratch.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(argv.suffix(2)), ["--", "--version"],
                       "the prompt must be the positional immediately after the end-of-options separator")
    }

    func testStdinDeliveryKeepsThePromptOutOfArgv() async throws {
        // G-05 companion: `.stdin` delivery (Claude Code) has no positional to
        // protect — the prompt must not appear in argv (and no stray `--`
        // either); it rides on stdin.
        let bin = try makeScript("stdincap", """
        #!/bin/sh
        printf '%s\\n' "$@" > "$PWD/argv.txt"
        cat > "$PWD/stdin.txt"
        exit 0
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .text),
            tier: .unrestricted, prompt: "make it teal",
            projectURL: scratch, timeouts: fastTimeouts(), onEvent: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: nil))
        let argv = try String(contentsOf: scratch.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(argv.contains("make it teal"), "stdin delivery must not put the prompt in argv")
        XCTAssertFalse(argv.contains("--"), "no end-of-options separator without a positional prompt")
        let stdin = try String(contentsOf: scratch.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.contains("make it teal"), "the prompt rides on stdin")
    }

    func testNonZeroExitCarriesStderrTail() async throws {
        let bin = try makeScript("fail", """
        #!/bin/sh
        echo "kaboom" 1>&2
        exit 3
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(code: 3, stderrTail: "kaboom")))
    }

    func testNonZeroExitPrefersResultEventError() async throws {
        // The stream-json agents report their fatal error in the terminal `result`
        // event on stdout (NOT stderr) and exit non-zero. The run must carry that
        // text as the failure detail — and the user-facing message must be it, not
        // the generic fallback.
        let bin = try makeScript("modelerr", #"""
        #!/bin/sh
        echo '{"type":"result","subtype":"error","is_error":true,"result":"ActionRequiredError: Named models unavailable. Free plans can only use Auto."}'
        exit 1
        """#)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(
            code: 1,
            stderrTail: "ActionRequiredError: Named models unavailable. Free plans can only use Auto.")))
        // The pill shows the real reason, not the generic line.
        let message = DevDispatchFailure.agent(
            .nonZeroExit(code: 1,
                         stderrTail: "ActionRequiredError: Named models unavailable. Free plans can only use Auto.")
        ).userMessage
        XCTAssertEqual(message, "ActionRequiredError: Named models unavailable. Free plans can only use Auto.")
        XCTAssertNotEqual(message, "The agent exited with an error.")
    }

    func testCursorShapedFailureSurfacesStderr() async throws {
        // Cursor's contract: the stream may end early WITHOUT a terminal `result`
        // event; the error is written to stderr. Detail must be the stderr text.
        let bin = try makeScript("cursorfail", #"""
        #!/bin/sh
        echo '{"type":"system","subtype":"init"}'
        echo "ActionRequiredError: Named models unavailable. Free plans can only use Auto." 1>&2
        exit 1
        """#)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(
            code: 1,
            stderrTail: "ActionRequiredError: Named models unavailable. Free plans can only use Auto.")))
    }

    func testCursorErrorEventSurfacesWhenNoResultAndNoStderr() async throws {
        // Cursor emits a top-level `error` event then ends with no `result` and no
        // stderr — the captured error-event text must be the detail.
        let bin = try makeScript("cursorerrevent", #"""
        #!/bin/sh
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"error","message":"stream aborted by server"}'
        exit 1
        """#)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(code: 1, stderrTail: "stream aborted by server")))
    }

    func testCodexShapedFailureSurfacesLastStdoutLine() async throws {
        // Codex runs as `.text`: it prints its fatal error as a plain stdout line,
        // empty stderr. The detail must be that last line.
        let bin = try makeScript("codexfail", """
        #!/bin/sh
        echo "Thinking about the change…"
        echo "Error: rate limit exceeded, try again later"
        exit 1
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .text),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(
            code: 1, stderrTail: "Error: rate limit exceeded, try again later")))
    }

    func testCodexShapedFailurePrefersStderrOverStdoutLine() async throws {
        // Same `.text` agent, but a real stderr error — stderr beats the last
        // chatty stdout line (the §D ordering).
        let bin = try makeScript("codexstderr", """
        #!/bin/sh
        echo "Working on it…"
        echo "fatal: auth required" 1>&2
        exit 1
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .text),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(code: 1, stderrTail: "fatal: auth required")))
    }

    func testNonZeroExitWithNeitherDetailFallsBackToGeneric() async throws {
        // No result-event error and no stderr → empty detail, and the user message
        // floors to the generic line (graceful floor, never an empty pill).
        let bin = try makeScript("silentfail", """
        #!/bin/sh
        exit 7
        """)
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(code: 7, stderrTail: "")))
        XCTAssertEqual(DevDispatchFailure.agent(.nonZeroExit(code: 7, stderrTail: "")).userMessage,
                       "The agent exited with an error.")
    }

    // MARK: - Stall watchdog (NOTIFIES — never terminates)

    func testStallNotifierFiresButNeverKillsTheProcess() async throws {
        // Silent well past the stall threshold, then exits 0 on its OWN. The
        // watchdog must NOTIFY (onStall(true)) but never terminate — proven by the
        // clean `.succeeded` result and that the run lasts the full sleep, not
        // threshold+grace.
        let bin = try makeScript("quiet", """
        #!/bin/sh
        sleep 3
        echo '{"type":"result"}'
        exit 0
        """)
        let stalls = StallRecorder()
        let start = Date()
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(stall: 1, killGrace: 1), model: nil,
            onEvent: { _ in },
            onStall: { stalls.append($0) }
        )
        XCTAssertEqual(result, .succeeded(summary: nil),
                       "the stall watchdog must not terminate the process")
        XCTAssertTrue(stalls.values().contains(true), "onStall(true) should have fired after the silence")
        // It ran the full ~3s sleep, NOT killed at threshold(1) + grace(1).
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 2.5)
    }

    func testStallNotifierResetsOnOutputAndClears() async throws {
        // Output resets the silence clock; a later stall fires `true`; the next
        // output clears it with `false`. The `{"type":"system"}` line is a
        // non-displayed frame — it still counts as a sign of life (resets/clears).
        let bin = try makeScript("resume", """
        #!/bin/sh
        echo '{"type":"system"}'
        sleep 2
        echo '{"type":"result"}'
        exit 0
        """)
        let stalls = StallRecorder()
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(stall: 1, killGrace: 1), model: nil,
            onEvent: { _ in },
            onStall: { stalls.append($0) }
        )
        XCTAssertEqual(result, .succeeded(summary: nil))
        // First a stall, then a resume on the next output.
        XCTAssertEqual(stalls.values(), [true, false])
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
            entry: e, tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(stall: 30, killGrace: 1),
            onEvent: { _ in }
        )
        // Let the first run acquire the cap-1 flag.
        try await Task.sleep(nanoseconds: 250_000_000)
        let second = await runner.run(
            entry: e, tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in }
        )
        XCTAssertEqual(second, .failed(.busy))
        let firstResult = await first
        XCTAssertEqual(firstResult, .succeeded(summary: nil))
    }

    func testCancelTerminatesRunningAgent() async throws {
        // Streams (so it's clearly alive) but never exits → only cancel ends it.
        // Cancel is THE sole terminator now (no timeout kill exists).
        let bin = try makeScript("cancelme", """
        #!/bin/sh
        while true; do echo '{"type":"system"}'; sleep 0.2; done
        """)
        let runner = ClaudeCodeAgentRunner()
        let e = entry(path: bin, format: .streamJSON)
        let start = Date()

        async let runResult = runner.run(
            entry: e, tier: .askPermission, prompt: "go", projectURL: scratch,
            // Long stall threshold so the watchdog never even notifies — the
            // cancel must be what ends it.
            timeouts: DevRunTimeouts(stall: 60, killGrace: 1),
            onEvent: { _ in }
        )
        // Let the process spawn + start streaming, then cancel.
        try await Task.sleep(nanoseconds: 400_000_000)
        runner.cancel()

        let result = await runResult
        XCTAssertEqual(result, .failed(.cancelled))
        // Resolves on the SIGTERM (well under the 60s stall threshold).
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testCancelWhenIdleIsHarmless() {
        // No run in flight → cancel is a no-op, must not crash.
        ClaudeCodeAgentRunner().cancel()
    }

    // MARK: - G-02: terminate targets the process GROUP, not just the pid

    func testAgentSpawnsAsItsOwnProcessGroupLeader() async throws {
        // The group-kill mechanism rests on the agent LEADING its own process
        // group (descendants inherit it) — assert that directly, and that the
        // group is NOT Zerro's own (a group signal must never hit the app).
        let bin = try makeScript("groupleader", """
        #!/bin/sh
        echo $$ > "$PWD/pid.txt"
        while true; do echo '{"type":"system"}'; sleep 0.2; done
        """)
        let runner = ClaudeCodeAgentRunner()
        async let runResult = runner.run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .unrestricted, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(stall: 60, killGrace: 1),
            onEvent: { _ in })
        let pid = try await waitForPIDFile("pid.txt")

        XCTAssertEqual(getpgid(pid), pid, "the agent must lead its own process group")
        XCTAssertNotEqual(getpgid(pid), getpgid(0), "the agent must not share Zerro's group")

        runner.cancel()
        let result = await runResult
        XCTAssertEqual(result, .failed(.cancelled))
    }

    func testCancelKillsAgentsChildProcesses() async throws {
        // The G-02 orphan scenario: the agent backgrounds a child that writes a
        // sentinel file after a delay. Cancel must reap the WHOLE tree — the old
        // single-pid terminate left the child running, and the sentinel appeared
        // after the run "ended".
        let bin = try makeChildSentinelProbe("cancelchildren")
        let runner = ClaudeCodeAgentRunner()
        let start = Date()
        async let runResult = runner.run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .unrestricted, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(stall: 60, killGrace: 1),
            onEvent: { _ in })
        let childPID = try await waitForPIDFile("child.txt")

        runner.cancel()
        let result = await runResult
        XCTAssertEqual(result, .failed(.cancelled))

        // The backgrounded child dies with the group (SIGTERM suffices here).
        let childDied = await waitUntil(timeout: 5) { kill(childPID, 0) != 0 }
        XCTAssertTrue(childDied, "the agent's child must die with the group on cancel")
        // Outwait the sentinel delay from the spawn, then prove the child never
        // got to write — it was killed before its `sleep 2` elapsed.
        try await sleepPast(start, total: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelPath),
                       "the child was killed before it wrote — no orphan survived cancel")
    }

    func testCancelKillsChildrenUnderSandboxExecWrapper() async throws {
        // Same tree-reap contract under the §5c sandbox-exec wrapper (fenced
        // tier): sandbox-exec exec-replaces into the agent at the same pid, so
        // the process GROUP — created at spawn — must still cover the agent's
        // children.
        try XCTSkipUnless(DevSeatbeltSandbox.isAvailable(),
                          "sandbox-exec unavailable — the fenced spawn would fail closed")
        try await withWrapperValve(disabled: false) {
            let bin = try makeChildSentinelProbe("fencedchildren")
            let runner = ClaudeCodeAgentRunner()
            let start = Date()
            async let runResult = runner.run(
                entry: entry(path: bin, format: .streamJSON),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: DevRunTimeouts(stall: 60, killGrace: 1),
                onEvent: { _ in })
            let childPID = try await waitForPIDFile("child.txt")

            runner.cancel()
            let result = await runResult
            XCTAssertEqual(result, .failed(.cancelled))

            let childDied = await waitUntil(timeout: 5) { kill(childPID, 0) != 0 }
            XCTAssertTrue(childDied, "the child must die with the group even under sandbox-exec")
            try await sleepPast(start, total: 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelPath),
                           "no orphan may survive cancel under the wrapper")
        }
    }

    func testTerminateNowSynchronouslyKillsProcessGroup() async throws {
        // The quit path (G-02 problem 2). Both the agent and its child TRAP
        // SIGTERM, and the grace is far longer than the test — so the ONLY thing
        // that can kill them promptly is the inline group SIGKILL. Asserting the
        // tree is dead right after terminateNow() returns proves the kill was
        // sent synchronously (the old async cancel() would still work here, but
        // dies with the app on a real quit — see the runner's queue.sync doc)
        // and skipped the SIGTERM→grace shape entirely.
        let bin = try makeScript("terminatenow", """
        #!/bin/sh
        trap '' TERM
        ( trap '' TERM; sleep 2; echo escaped > "$PWD/sentinel.txt" ) &
        echo $! > "$PWD/child.txt"
        while true; do echo '{"type":"system"}'; sleep 0.2; done
        """)
        let runner = ClaudeCodeAgentRunner()
        let start = Date()
        async let runResult = runner.run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .unrestricted, prompt: "go", projectURL: scratch,
            // A grace far longer than the test: if terminateNow went through the
            // graceful SIGTERM→grace path, the TERM-trapping tree would outlive
            // every assertion below.
            timeouts: DevRunTimeouts(stall: 60, killGrace: 30),
            onEvent: { _ in })
        let childPID = try await waitForPIDFile("child.txt")

        let callStart = Date()
        runner.terminateNow()
        XCTAssertLessThan(Date().timeIntervalSince(callStart), 1.0,
                          "terminateNow must return promptly — quit must never hang")

        // SIGKILL was already SENT when the call returned; only scheduler/reap
        // latency remains. A TERM-trapping child dying at all proves SIGKILL; it
        // dying now (not after the 30s grace) proves it was inline.
        let childDied = await waitUntil(timeout: 5) { kill(childPID, 0) != 0 }
        XCTAssertTrue(childDied, "the TERM-trapping child must be SIGKILLed with the group")
        let result = await runResult
        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(callStart), 10,
                          "the whole teardown resolved without the 30s grace — the kill was inline")

        try await sleepPast(start, total: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelPath),
                       "the child was killed before it wrote — no orphan survived quit")
    }

    func testTerminateNowWhenIdleIsHarmless() {
        // No run in flight → the quit-path terminate is a no-op, must not crash
        // (and must not block).
        ClaudeCodeAgentRunner().terminateNow()
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
            entry: e, tier: .askPermission, prompt: "go", projectURL: scratch,
            onEvent: { _ in }
        )
        guard case .failed(.spawnFailed) = result else {
            return XCTFail("expected .spawnFailed, got \(result)")
        }
    }

    // MARK: - Parser (Claude Code)

    func testParseStreamJSONLine() {
        // Terminal result.
        XCTAssertEqual(parse(#"{"type":"result"}"#), DevAgentEvent(kind: .done))
        // Edits carry the file at `file_path` (basename only).
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/proj/src/App.css"}}]}}"#),
            DevAgentEvent(kind: .editing, detail: "App.css"))
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/p/src/index.html"}}]}}"#),
            DevAgentEvent(kind: .editing, detail: "index.html"))
        // Read captures the file it's reading.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/package.json"}}]}}"#),
            DevAgentEvent(kind: .reading, detail: "package.json"))
        // Grep/Glob capture the search pattern.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"useState"}}]}}"#),
            DevAgentEvent(kind: .searching, detail: "useState"))
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Glob","input":{"pattern":"**/*.ts"}}]}}"#),
            DevAgentEvent(kind: .searching, detail: "**/*.ts"))
        // LS (legacy) captures the listed directory.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"LS","input":{"path":"/proj/src"}}]}}"#),
            DevAgentEvent(kind: .listing, detail: "src"))
        // Bash captures the command's first line (capped).
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm install"}}]}}"#),
            DevAgentEvent(kind: .running, detail: "npm install"))
        // Bash with no command → running, no detail.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#),
            DevAgentEvent(kind: .running))
        // `Agent` is the current subagent tool (verified at M9) → generic running.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}"#),
            DevAgentEvent(kind: .running))
        // Assistant narration (no tool_use) surfaces as a message / thought so the
        // feed shows motion even on a talk-only turn.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll edit it."}]}}"#),
            DevAgentEvent(kind: .message, detail: "I'll edit it."))
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"…"}]}}"#),
            DevAgentEvent(kind: .thinking))
        // An unknown/future tool degrades to `.working`, never nil-crashes.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SomeFutureTool","input":{}}]}}"#),
            DevAgentEvent(kind: .working))
        // Structural / garbage lines yield no event.
        XCTAssertNil(parse(#"{"type":"system"}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(""))
    }

    // MARK: - Parser (Cursor)

    func testParseStreamJSONLineCursorToolCalls() {
        // Cursor rides tool activity in its OWN `tool_call` event (distinct from
        // Claude's `assistant.tool_use`), emitting on the `started` twin — with
        // the file / command captured from `args`.
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"/private/tmp/proj/README.md"}},"toolCallId":"t","startedAtMs":"1"}}"#),
            DevAgentEvent(kind: .editing, detail: "README.md"))
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"/p/x.swift"}},"toolCallId":"t"}}"#),
            DevAgentEvent(kind: .reading, detail: "x.swift"))
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"echo hi"}},"toolCallId":"t"}}"#),
            DevAgentEvent(kind: .running, detail: "echo hi"))
        // grep → args.pattern; ls → args.path (basename); glob → args.globPattern.
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"grepToolCall":{"args":{"pattern":"useAuth"}},"toolCallId":"t"}}"#),
            DevAgentEvent(kind: .searching, detail: "useAuth"))
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"lsToolCall":{"args":{"path":"/proj/src/components"}},"toolCallId":"t"}}"#),
            DevAgentEvent(kind: .listing, detail: "components"))
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"globToolCall":{"args":{"globPattern":"**/*.ts"}},"toolCallId":"t"}}"#),
            DevAgentEvent(kind: .searching, detail: "**/*.ts"))
        // The `completed` twin must NOT re-emit (the `started` one already did).
        XCTAssertNil(
            parse(#"{"type":"tool_call","subtype":"completed","tool_call":{"editToolCall":{"args":{"path":"/p/README.md"}}}}"#))
        // An unknown/future tool kind degrades to `.working`, never nil-crashes.
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"frobToolCall":{"args":{}}}}"#),
            DevAgentEvent(kind: .working))
        // Cursor's terminal `result` event maps to `.done` like Claude's (shared).
        XCTAssertEqual(
            parse(#"{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"inputTokens":1}}"#),
            DevAgentEvent(kind: .done))
        // Cursor's `thinking` DELTA is per-token noise — skipped (nil).
        XCTAssertNil(parse(#"{"type":"thinking","subtype":"delta","text":"…"}"#))
        // A complete assistant text message surfaces as narration.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll edit it."}]}}"#),
            DevAgentEvent(kind: .message, detail: "I'll edit it."))
    }

    // MARK: - Parser (Codex `--json`)

    func testParseCodexJSONLineItemEvents() {
        // command_execution: emit on `item.started` with the shell wrapper stripped
        // (`bash -lc ls` → `ls`); the `item.completed` twin must NOT re-emit.
        XCTAssertEqual(
            parseCodex(#"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"bash -lc ls","exit_code":null,"status":"in_progress"}}"#),
            DevAgentEvent(kind: .running, detail: "ls"))
        XCTAssertNil(
            parseCodex(#"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"bash -lc ls","exit_code":0,"status":"completed"}}"#))
        // A quoted wrapped command unwraps one matching quote pair.
        XCTAssertEqual(
            parseCodex(#"{"type":"item.started","item":{"id":"i2","type":"command_execution","command":"bash -lc \"npm test\"","status":"in_progress"}}"#),
            DevAgentEvent(kind: .running, detail: "npm test"))
        // file_change: completed-only → `.editing` with the basename; multiple
        // changes append " +N" (the count of the OTHER files).
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i3","type":"file_change","changes":[{"path":"src/App.swift","kind":"update"}],"status":"completed"}}"#),
            DevAgentEvent(kind: .editing, detail: "App.swift"))
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i4","type":"file_change","changes":[{"path":"a/x.md","kind":"add"},{"path":"b/y.md","kind":"update"},{"path":"c/z.md","kind":"delete"}],"status":"completed"}}"#),
            DevAgentEvent(kind: .editing, detail: "x.md +2"))
        // file_change with no usable path → `.editing` with no detail.
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i5","type":"file_change","changes":[],"status":"completed"}}"#),
            DevAgentEvent(kind: .editing))
        // web_search: completed-only → `.searching` with the query.
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i6","type":"web_search","query":"codex exec json schema"}}"#),
            DevAgentEvent(kind: .searching, detail: "codex exec json schema"))
        // reasoning → `.thinking`; agent_message → `.message` with the text.
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i7","type":"reasoning","text":"Thinking about it"}}"#),
            DevAgentEvent(kind: .thinking))
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i8","type":"agent_message","text":"Done. Updated the docs."}}"#),
            DevAgentEvent(kind: .message, detail: "Done. Updated the docs."))
        // mcp_tool_call: emit on start as `.running` with `server/tool`; completed twin nil.
        XCTAssertEqual(
            parseCodex(#"{"type":"item.started","item":{"id":"i9","type":"mcp_tool_call","server":"github","tool":"create_issue","status":"in_progress"}}"#),
            DevAgentEvent(kind: .running, detail: "github/create_issue"))
        XCTAssertNil(
            parseCodex(#"{"type":"item.completed","item":{"id":"i9","type":"mcp_tool_call","server":"github","tool":"create_issue","status":"completed"}}"#))
        // turn.completed → `.done`.
        XCTAssertEqual(
            parseCodex(#"{"type":"turn.completed","usage":{"input_tokens":24763,"output_tokens":122}}"#),
            DevAgentEvent(kind: .done))
        // todo_list → a `.plan` step (Phase 3; see testCodexTodoListPlan for depth).
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i10","type":"todo_list","items":[{"text":"step","completed":false}]}}"#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 1, total: 1, title: "step"))))
        // Lifecycle frames carry no feed signal.
        XCTAssertNil(parseCodex(#"{"type":"thread.started","thread_id":"t"}"#))
        XCTAssertNil(parseCodex(#"{"type":"turn.started"}"#))
        XCTAssertNil(parseCodex(#"{"type":"turn.failed","error":{"message":"boom"}}"#))
        XCTAssertNil(parseCodex(#"{"type":"error","message":"boom"}"#))
        // An unknown/future item type and garbage degrade to nil, never crash.
        XCTAssertNil(parseCodex(#"{"type":"item.started","item":{"id":"i11","type":"future_thing"}}"#))
        XCTAssertNil(parseCodex("not json"))
        XCTAssertNil(parseCodex(""))
    }

    func testParseCodexSummary() {
        // The closing `agent_message` is the summary (question-stripped).
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseCodexSummaryForTesting(
                #"{"type":"item.completed","item":{"type":"agent_message","text":"Added the route. Want me to add tests?"}}"#),
            "Added the route.")
        // Non-agent_message / lifecycle lines yield no summary.
        XCTAssertNil(ClaudeCodeAgentRunner.parseCodexSummaryForTesting(
            #"{"type":"item.completed","item":{"type":"command_execution","command":"bash -lc ls","status":"completed"}}"#))
        XCTAssertNil(ClaudeCodeAgentRunner.parseCodexSummaryForTesting(
            #"{"type":"turn.completed","usage":{}}"#))
    }

    func testParseCodexErrorEvent() {
        // turn.failed → nested error.message (live-confirmed shape, codex 0.140.0).
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
                #"{"type":"turn.failed","error":{"message":"model response stream ended unexpectedly"}}"#),
            "model response stream ended unexpectedly")
        // Top-level fatal error → message (live-confirmed shape).
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
                #"{"type":"error","message":"You've hit your usage limit."}"#),
            "You've hit your usage limit.")
        // A "Reconnecting…" top-level error is a transient retry → ignored (nil).
        XCTAssertNil(ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
            #"{"type":"error","message":"Reconnecting... attempt 1/5"}"#))
        // A dedicated error item carries its own message.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
                #"{"type":"item.completed","item":{"type":"error","message":"patch failed to apply"}}"#),
            "patch failed to apply")
        // A failed command_execution item → a best-effort exit summary.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
                #"{"type":"item.completed","item":{"type":"command_execution","command":"bash -lc \"npm run build\"","exit_code":2,"status":"failed"}}"#),
            "Command failed (exit 2): npm run build")
        // A successful command / normal line → nil (not an error).
        XCTAssertNil(ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
            #"{"type":"item.completed","item":{"type":"command_execution","command":"bash -lc ls","exit_code":0,"status":"completed"}}"#))
        XCTAssertNil(ClaudeCodeAgentRunner.parseCodexErrorEventForTesting(
            #"{"type":"turn.completed","usage":{}}"#))
    }

    // MARK: - Substatus (single-line pill label)

    func testEventSubstatusCarriesDetailThrough() {
        // The pill substatus now preserves each kind's specifics instead of
        // collapsing reading/searching/listing/running to a generic line.
        XCTAssertEqual(
            DevAgentEvent(kind: .reading, detail: "authMiddleware.ts").substatus,
            .reading(file: "authMiddleware.ts"))
        XCTAssertEqual(
            DevAgentEvent(kind: .searching, detail: "useAuth").substatus,
            .searching(pattern: "useAuth"))
        XCTAssertEqual(
            DevAgentEvent(kind: .listing, detail: "src").substatus,
            .listing(dir: "src"))
        XCTAssertEqual(
            DevAgentEvent(kind: .running, detail: "npm test").substatus,
            .running(command: "npm test"))
        XCTAssertEqual(
            DevAgentEvent(kind: .editing, detail: "Button.tsx").substatus,
            .editing(file: "Button.tsx"))
        // A detail-less event of a specific kind maps to the empty-detail case.
        XCTAssertEqual(DevAgentEvent(kind: .running).substatus, .running(command: ""))
        // Narration / thinking / structural kinds have no specific → generic motion.
        XCTAssertEqual(DevAgentEvent(kind: .thinking).substatus, .working)
        XCTAssertEqual(DevAgentEvent(kind: .message, detail: "hi").substatus, .working)
        XCTAssertEqual(DevAgentEvent(kind: .working).substatus, .working)
        XCTAssertEqual(DevAgentEvent(kind: .done).substatus, .done)
    }

    func testSubstatusLabelRendersSpecificsAndFallsBack() {
        // Specifics surface in the label …
        XCTAssertEqual(DevRunSubstatus.reading(file: "authMiddleware.ts").label, "Reading authMiddleware.ts…")
        XCTAssertEqual(DevRunSubstatus.searching(pattern: "useAuth").label, "Searching for \u{201C}useAuth\u{201D}…")
        XCTAssertEqual(DevRunSubstatus.listing(dir: "src").label, "Listing src…")
        XCTAssertEqual(DevRunSubstatus.running(command: "npm test").label, "Running npm test…")
        XCTAssertEqual(DevRunSubstatus.editing(file: "Button.tsx").label, "Editing Button.tsx…")
        // … and an empty detail falls back to the generic phrasing (no dangling
        // "Reading …" / empty quotes).
        XCTAssertEqual(DevRunSubstatus.reading(file: "").label, "Reading files…")
        XCTAssertEqual(DevRunSubstatus.searching(pattern: "").label, "Searching your codebase…")
        XCTAssertEqual(DevRunSubstatus.listing(dir: "").label, "Listing files…")
        XCTAssertEqual(DevRunSubstatus.running(command: "").label, "Running commands…")
        XCTAssertEqual(DevRunSubstatus.editing(file: "").label, "Editing files…")
        XCTAssertEqual(DevRunSubstatus.working.label, "Working on your changes…")
    }

    func testSubstatusLabelTruncatesLongDetail() {
        // A long command is capped (40 chars) + ellipsis so the capsule can't blow
        // out and the " · Xs" elapsed suffix stays visible.
        let long = String(repeating: "x", count: 80)
        let label = DevRunSubstatus.running(command: long).label
        XCTAssertEqual(label, "Running \(String(repeating: "x", count: 40))…")
        XCTAssertTrue(label.hasSuffix("…"))
        // A detail at the cap boundary is untouched (no spurious ellipsis).
        let exact = String(repeating: "y", count: 40)
        XCTAssertEqual(DevRunSubstatus.reading(file: exact).label, "Reading \(exact)…")
    }

    // MARK: - Plan / to-do step (Phase 3)

    func testClaudeTodoWritePlan() {
        // TodoWrite → the `in_progress` item is the current step; its `activeForm`
        // ("Adding auth middleware") is the title.
        XCTAssertEqual(
            parse(#"""
            {"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Add auth middleware","status":"completed","activeForm":"Added auth middleware"},{"content":"Wire routes","status":"in_progress","activeForm":"Adding auth middleware"},{"content":"c","status":"pending","activeForm":"C"},{"content":"d","status":"pending","activeForm":"D"},{"content":"e","status":"pending","activeForm":"E"}]}}]}}
            """#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 2, total: 5, title: "Adding auth middleware"))))
        // No `activeForm` → fall back to `content`.
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Only step","status":"in_progress"}]}}]}}"#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 1, total: 1, title: "Only step"))))
        // All complete → no plan line (generic motion).
        XCTAssertEqual(
            parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"completed"}]}}]}}"#),
            DevAgentEvent(kind: .working))
    }

    func testCursorTodoPlan() {
        // todoToolCall: the `_IN_PROGRESS` item is current; a `_CANCELLED` item is
        // excluded from the total (so 4 todos, 1 cancelled → total 3, step 2).
        XCTAssertEqual(
            parse(#"""
            {"type":"tool_call","subtype":"started","tool_call":{"todoToolCall":{"args":{"todos":[{"content":"first","status":"TODO_STATUS_COMPLETED"},{"content":"second","status":"TODO_STATUS_IN_PROGRESS"},{"content":"third","status":"TODO_STATUS_PENDING"},{"content":"scrapped","status":"TODO_STATUS_CANCELLED"}]}}}}
            """#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 2, total: 3, title: "second"))))
        // `updateTodosToolCall` routes too (name contains "todo").
        XCTAssertEqual(
            parse(#"{"type":"tool_call","subtype":"started","tool_call":{"updateTodosToolCall":{"args":{"todos":[{"content":"x","status":"TODO_STATUS_IN_PROGRESS"},{"content":"y","status":"TODO_STATUS_PENDING"}]}}}}"#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 1, total: 2, title: "x"))))
    }

    func testCodexTodoListPlan() {
        // Codex has no in_progress flag — the FIRST incomplete item is current
        // (step = first-incomplete index + 1). Parses on item.updated …
        XCTAssertEqual(
            parseCodex(#"{"type":"item.updated","item":{"id":"i8","type":"todo_list","items":[{"text":"Scan docs","completed":true},{"text":"Plan","completed":true},{"text":"Write code","completed":false},{"text":"Test","completed":false}]}}"#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 3, total: 4, title: "Write code"))))
        // … and on item.completed (idempotent; last wins).
        XCTAssertEqual(
            parseCodex(#"{"type":"item.completed","item":{"id":"i8","type":"todo_list","items":[{"text":"a","completed":false}]}}"#),
            DevAgentEvent(kind: .plan(DevRunPlan(step: 1, total: 1, title: "a"))))
        // All complete → no feed signal (nil for the optional Codex parser).
        XCTAssertNil(
            parseCodex(#"{"type":"item.completed","item":{"id":"i8","type":"todo_list","items":[{"text":"a","completed":true}]}}"#))
    }

    func testPlanFromDerivation() {
        // Explicit `current` wins over the first-not-done fallback.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.planFromForTesting([
                (title: "a", done: true, current: false),
                (title: "b", done: false, current: false),
                (title: "c", done: false, current: true),
            ]),
            DevRunPlan(step: 3, total: 3, title: "c"))
        // No explicit current → first not-done.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.planFromForTesting([
                (title: "a", done: true, current: false),
                (title: "b", done: false, current: false),
            ]),
            DevRunPlan(step: 2, total: 2, title: "b"))
        // step never exceeds total (last item current → step == total).
        let p = ClaudeCodeAgentRunner.planFromForTesting([
            (title: "a", done: true, current: false),
            (title: "b", done: true, current: true),
        ])
        XCTAssertEqual(p?.step, 2)
        XCTAssertEqual(p?.total, 2)
        // All done / empty → nil.
        XCTAssertNil(ClaudeCodeAgentRunner.planFromForTesting([
            (title: "a", done: true, current: false),
            (title: "b", done: true, current: false),
        ]))
        XCTAssertNil(ClaudeCodeAgentRunner.planFromForTesting([]))
    }

    func testPlanStepLabelAndSubstatus() {
        XCTAssertEqual(DevRunSubstatus.planStep(step: 2, total: 5, title: "Adding auth middleware").label,
                       "[2/5] Adding auth middleware…")
        // Empty title → the bare "Step N of M" form.
        XCTAssertEqual(DevRunSubstatus.planStep(step: 2, total: 5, title: "").label, "Step 2 of 5…")
        // Long title is capped (40), and the label never contains the timer
        // separator " · " (which would break ProcessingPillContent's split).
        let long = DevRunSubstatus.planStep(step: 1, total: 3, title: String(repeating: "x", count: 80)).label
        XCTAssertEqual(long, "[1/3] \(String(repeating: "x", count: 40))…")
        XCTAssertFalse(long.contains(" \u{00B7} "))
        // The event's substatus carries the plan through unchanged.
        XCTAssertEqual(
            DevAgentEvent(kind: .plan(DevRunPlan(step: 2, total: 5, title: "x"))).substatus,
            .planStep(step: 2, total: 5, title: "x"))
    }

    func testEventValueEqualityIgnoresIdentityAndTimestamp() {
        // Two events with the same payload but different id/timestamp are equal —
        // the feed uses `id` for SwiftUI identity, not value.
        let a = DevAgentEvent(kind: .editing, detail: "App.css")
        let b = DevAgentEvent(kind: .editing, detail: "App.css")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, DevAgentEvent(kind: .editing, detail: "Other.css"))
        XCTAssertNotEqual(a, DevAgentEvent(kind: .reading, detail: "App.css"))
    }

    // MARK: - Result summary

    func testParseResultSummaryCursorResultEvent() {
        // Cursor's `result` event carries extra fields (duration_ms, usage, …) but
        // the same `result` summary string the existing parser reads.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultSummaryForTesting(
                #"{"type":"result","subtype":"success","duration_ms":8144,"is_error":false,"result":"  Appended the line.  ","usage":{"inputTokens":1}}"#),
            "Appended the line.")
    }

    func testCursorArgumentDeliveryArgv() async throws {
        // The Cursor entry's contract, end-to-end through the runner: prompt rides
        // as the LAST argv element (positional `.argument`), stdin is closed empty,
        // and --force (allow-commands) + --model are threaded in order.
        //
        // Run under `.unrestricted` (matching the Codex `.argument` twin above).
        // This test asserts ONLY the argv/stdin contract, which is tier-independent
        // for this entry: `allowCommandsArgs` (`--force`) is appended at EVERY tier
        // and `mcpDisableArgs` is empty, so `.autoApprove` and `.unrestricted`
        // produce identical argv here. A FENCED tier would additionally spin up the
        // real Seatbelt wrapper + network-filter proxy (sandbox-exec + a bound
        // loopback port) inside this unit test — heavyweight, host-dependent, and
        // not what's under test; the fenced wrap is covered by the `testFencedRun…`
        // tests (which gate on sandbox availability and inject a fake proxy).
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
            entry: e, tier: .unrestricted, prompt: "make this button bigger",
            projectURL: scratch, timeouts: fastTimeouts(), model: "claude-opus-4-8-high",
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .succeeded(summary: "ok"))
        let argv = try String(contentsOf: scratch.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, ["-p", "--output-format", "stream-json", "--trust", "--force",
                              "--model", "claude-opus-4-8-high", "--", "make this button bigger"])
        let stdin = try String(contentsOf: scratch.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.isEmpty, "argument delivery must not write the prompt to stdin")
    }

    // MARK: - Env scrub (§5b)

    /// A representative "leaky" environment a developer machine carries — secrets
    /// the fenced tiers must strip, plus the keep-list vars.
    private func leakyEnv(extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/dev", "USER": "dev", "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8", "LC_CTYPE": "en_US.UTF-8",
            "TMPDIR": "/tmp/x", "TERM": "xterm-256color",
            // Secrets / unrelated creds that MUST NOT reach the agent process.
            "DATABASE_URL": "postgres://u:p@host/db",
            "AWS_ACCESS_KEY_ID": "AKIAEXAMPLE",
            "AWS_SECRET_ACCESS_KEY": "shhh",
            "GCP_PROJECT": "proj", "GOOGLE_APPLICATION_CREDENTIALS": "/c.json",
            "STRIPE_SECRET_KEY": "sk_live_x",
            "SOME_SERVICE_TOKEN": "tok", "OTHER_API_KEY": "k", "MY_SECRET": "s",
        ]
        env.merge(extra) { _, new in new }
        return env
    }

    private func claudeURL() -> URL { URL(fileURLWithPath: "/opt/homebrew/bin/claude") }

    func testFencedTierAllowlistsEnvAndStripsSecrets() {
        // A planted DATABASE_URL (+ cloud creds + generic *_SECRET/*_TOKEN/*_API_KEY)
        // is stripped under a fenced tier; PATH + locale/shell vars survive.
        let env = ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: claudeURL(), tier: .askPermission,
            baseEnvironment: leakyEnv(extra: ["ANTHROPIC_API_KEY": "sk-ant-x"]))

        // Kept.
        XCTAssertNotNil(env["PATH"])
        XCTAssertTrue(env["PATH"]!.contains("/opt/homebrew/bin"), "binDir is prepended onto PATH")
        for k in ["HOME", "USER", "SHELL", "LANG", "LC_CTYPE", "TMPDIR", "TERM"] {
            XCTAssertNotNil(env[k], "\(k) must survive the allowlist")
        }
        // The active agent's own auth var is kept (only because it's present).
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-x")

        // Stripped — the whole point of §5b.
        for k in ["DATABASE_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                  "GCP_PROJECT", "GOOGLE_APPLICATION_CREDENTIALS", "STRIPE_SECRET_KEY",
                  "SOME_SERVICE_TOKEN", "OTHER_API_KEY", "MY_SECRET"] {
            XCTAssertNil(env[k], "\(k) must be stripped under a fenced tier")
        }
    }

    func testAutoApproveIsFencedToo() {
        // Auto-Approve gets the SAME allowlist as Ask Permission (both fenced).
        let env = ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: claudeURL(), tier: .autoApprove, baseEnvironment: leakyEnv())
        XCTAssertNil(env["DATABASE_URL"], "Auto-Approve is fenced — DB URL stripped")
        XCTAssertNotNil(env["PATH"])
    }

    func testUnrestrictedForwardsFullEnvironment() {
        // Unrestricted removes the fence: the full environment rides through
        // (PATH still rebuilt with the binary dir prepended).
        let env = ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: claudeURL(), tier: .unrestricted, baseEnvironment: leakyEnv())
        XCTAssertEqual(env["DATABASE_URL"], "postgres://u:p@host/db", "Unrestricted forwards everything")
        XCTAssertEqual(env["STRIPE_SECRET_KEY"], "sk_live_x")
        XCTAssertTrue(env["PATH"]!.contains("/opt/homebrew/bin"))
    }

    func testFencedKeepsOnlyTheActiveAgentsAuthVar() {
        // Codex keeps OPENAI_API_KEY / CODEX_API_KEY; a stray ANTHROPIC_API_KEY
        // (another agent's) is NOT the active agent's, so it's stripped.
        let base = leakyEnv(extra: [
            "OPENAI_API_KEY": "sk-openai", "CODEX_API_KEY": "cdx",
            "ANTHROPIC_API_KEY": "sk-ant-x",
        ])
        let codex = ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), tier: .askPermission, baseEnvironment: base)
        XCTAssertEqual(codex["OPENAI_API_KEY"], "sk-openai")
        XCTAssertEqual(codex["CODEX_API_KEY"], "cdx")
        XCTAssertNil(codex["ANTHROPIC_API_KEY"], "another agent's auth var is stripped")

        // Cursor keeps CURSOR_API_KEY; the OpenAI/Anthropic keys are stripped.
        let cursor = ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/cursor-agent"), tier: .askPermission,
            baseEnvironment: leakyEnv(extra: ["CURSOR_API_KEY": "cur", "OPENAI_API_KEY": "sk-openai"]))
        XCTAssertEqual(cursor["CURSOR_API_KEY"], "cur")
        XCTAssertNil(cursor["OPENAI_API_KEY"], "another agent's auth var is stripped")
    }

    func testParseResultSummary() {
        // A `result` event with text → the trimmed text.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultSummaryForTesting(
                #"{"type":"result","result":"  Reworked the nav.  "}"#),
            "Reworked the nav.")
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

    // MARK: - Question stripping (non-interactive dev result card)

    func testSummaryDropsTrailingQuestion() {
        // The screenshot case: a clean summary followed by an offer to do more.
        // The offer is a dead end here (no reply box) — drop it, end on the fact.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.summaryDroppingQuestionsForTesting(
                "Recolored the hero with the western palette. Want me to extend the western "
                + "palette to those sections too, or leave it scoped to the hero?"),
            "Recolored the hero with the western palette.")
    }

    func testSummaryDropsInlineMidParagraphQuestion() {
        // A question embedded between two statements (the "One thing to flag:"
        // shape) — the surrounding declarative sentences survive.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.summaryDroppingQuestionsForTesting(
                "Updated the nav. Should I also update the footer? I left it as-is for now."),
            "Updated the nav. I left it as-is for now.")
    }

    func testSummaryKeepsStatementsWithDotsAndUrls() {
        // A `?`/`.` mid-token is not a sentence end — file names and query
        // strings must not be mistaken for question boundaries.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.summaryDroppingQuestionsForTesting(
                "Edited west.css and patched https://x.test/p?ref=hero in the header."),
            "Edited west.css and patched https://x.test/p?ref=hero in the header.")
    }

    func testSummaryStatementOnlyUnchanged() {
        // No questions → byte-for-byte the same text.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.summaryDroppingQuestionsForTesting("Reworked the nav."),
            "Reworked the nav.")
    }

    func testSummaryAllQuestionsBecomesNil() {
        // Nothing declarative survives → nil, so the diff-stat fallback shows.
        XCTAssertNil(
            ClaudeCodeAgentRunner.summaryDroppingQuestionsForTesting(
                "Want me to proceed? Or should I wait?"))
    }

    func testSummaryDropsQuestionWithinResultEvent() {
        // End-to-end through the `result`-event parser: the wired-in stripping
        // runs on the real summary path, not just the standalone helper.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultSummaryForTesting(
                #"{"type":"result","result":"Scoped the palette to the hero. Want me to do the rest?"}"#),
            "Scoped the palette to the hero.")
    }

    // MARK: - Result error (failure detail)

    func testParseResultErrorClaudeCodeErrorResult() {
        // Claude Code's error result: `is_error:true` + an error subtype, text in
        // `result`. The parser returns it verbatim (no question stripping).
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Boom. Should I retry?"}"#),
            "Boom. Should I retry?")
        // The human text can live under `error` or `message` on other agents.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","subtype":"error","is_error":true,"error":"ActionRequiredError: Named models unavailable. Free plans can only use Auto."}"#),
            "ActionRequiredError: Named models unavailable. Free plans can only use Auto.")
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","is_error":true,"message":"quota exceeded"}"#),
            "quota exceeded")
        // No human text at all → fall back to the subtype so we surface *something*.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","subtype":"error_max_turns","is_error":true}"#),
            "error_max_turns")
    }

    func testParseResultErrorEnrichesWithPermissionDenial() {
        // Edits-only's most common failure: a denied shell command. `error` alone
        // ("Permission denied") is useless — the detail must name the command.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","subtype":"error","is_error":true,"result":"","error":"Permission denied","permission_denials":[{"tool_name":"Bash","tool_use_id":"x","tool_input":{"command":"git fetch origin main"}}]}"#),
            "Permission denied (Bash: git fetch origin main)")
        // Multiple denials are joined (capped at 3); a denial without a command
        // falls back to just the tool name.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","is_error":true,"error":"Permission denied","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}},{"tool_name":"WebFetch"}]}"#),
            "Permission denied (Bash: rm -rf /; WebFetch)")
        // Denials present but no base text → the denial summary stands alone.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","is_error":true,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm publish"}}]}"#),
            "Bash: npm publish")
        // A malformed denials array degrades to the plain error, never crashes.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseResultErrorForTesting(
                #"{"type":"result","is_error":true,"error":"Permission denied","permission_denials":"nope"}"#),
            "Permission denied")
    }

    func testParseStreamErrorEventCapturesCursorErrorEvent() {
        // Cursor emits a top-level `error` event mid-stream (no terminal `result`).
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamErrorEventForTesting(
                #"{"type":"error","message":"ActionRequiredError: Named models unavailable."}"#),
            "ActionRequiredError: Named models unavailable.")
        // Text can ride under `error` instead of `message`.
        XCTAssertEqual(
            ClaudeCodeAgentRunner.parseStreamErrorEventForTesting(
                #"{"type":"error","error":"stream aborted"}"#),
            "stream aborted")
        // A non-error line is never captured.
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamErrorEventForTesting(
            #"{"type":"result","subtype":"success","result":"ok"}"#))
        XCTAssertNil(ClaudeCodeAgentRunner.parseStreamErrorEventForTesting("not json"))
    }

    func testParseResultErrorIgnoresSuccessAndNonResult() {
        // A successful result is not an error — nil even though it has text.
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultErrorForTesting(
            #"{"type":"result","subtype":"success","is_error":false,"result":"Reworked the nav."}"#))
        // A non-result line is never an error.
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultErrorForTesting(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#))
        // Garbage / empty degrade to nil, never crash.
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultErrorForTesting("not json"))
        XCTAssertNil(ClaudeCodeAgentRunner.parseResultErrorForTesting(""))
    }

    // MARK: - Seatbelt wrapper (§5c filesystem confinement)

    /// A fake agent that ATTEMPTS to write `escapeTarget` (outside the project) and
    /// records ESCAPED/DENIED into `result.txt` in its cwd (the project dir, always
    /// writable). Also writes an in-repo marker to prove it ran. Emits a terminal
    /// `result` so the run resolves `.succeeded`.
    private func makeEscapeProbe(_ name: String, escapeTarget: String) throws -> URL {
        try makeScript(name, """
        #!/bin/sh
        if echo blocked > "\(escapeTarget)" 2>/dev/null; then
          echo ESCAPED > "$PWD/result.txt"
        else
          echo DENIED > "$PWD/result.txt"
        fi
        echo ran > "$PWD/in-repo.txt"
        echo '{"type":"result"}'
        exit 0
        """)
    }

    /// A fake agent that dumps its spawn environment to `env.txt` in its cwd (the
    /// project dir) so a test can assert the §5b allowlist held. Emits a terminal
    /// `result` so the run resolves `.succeeded`.
    private func makeEnvDumpProbe(_ name: String) throws -> URL {
        try makeScript(name, """
        #!/bin/sh
        /usr/bin/env > "$PWD/env.txt"
        echo '{"type":"result"}'
        exit 0
        """)
    }

    /// Pin the seatbelt-wrapper valve to a known value for `body`, restoring the
    /// prior `UserDefaults.standard` state after. The runner reads the standard
    /// domain, so without this a value left on the machine (or leaked from another
    /// test) can silently flip the wrap decision and make a wrapper test pass for
    /// the wrong reason.
    private func withWrapperValve(disabled: Bool, _ body: () async throws -> Void) async rethrows {
        let key = DevSeatbeltSandbox.wrapperDisabledDefaultsKey
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(disabled, forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    func testFencedRunIsWrappedAndDeniesWriteOutsideProject() async throws {
        try XCTSkipUnless(DevSeatbeltSandbox.isAvailable(),
                          "sandbox-exec unavailable — the fenced spawn would fail closed")
        // /private/var/tmp is writable normally but is NOT in the wrapper's allow
        // list (the profile allows /private/var/folders, not /private/var/tmp), so
        // a fenced run must be DENIED writing there — proving sandbox-exec wraps it.
        let escape = "/private/var/tmp/zerro-sb-escape-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: escape) }
        let bin = try makeEscapeProbe("fencedprobe", escapeTarget: escape)

        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })

        XCTAssertEqual(result, .succeeded(summary: nil))
        // The agent ran (in-repo write succeeded under the fence)…
        XCTAssertEqual(
            try String(contentsOf: scratch.appendingPathComponent("in-repo.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "ran", "an in-repo write must succeed under the wrapper")
        // …but the outside-repo write was blocked by the OS.
        XCTAssertEqual(
            try String(contentsOf: scratch.appendingPathComponent("result.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "DENIED", "the wrapper must deny a write outside the project dir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape),
                       "the escape file must NOT exist — the fence held")
    }

    func testUnrestrictedRunIsNotWrappedAndCanWriteOutsideProject() async throws {
        // The SAME probe under `.unrestricted` must spawn the agent DIRECTLY (no
        // sandbox-exec), so the outside-repo write SUCCEEDS — the contrast that
        // proves the wrapper is fenced-tiers-only and `.unrestricted` is unchanged.
        let escape = "/private/var/tmp/zerro-sb-escape-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: escape) }
        let bin = try makeEscapeProbe("unrestrictedprobe", escapeTarget: escape)

        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .unrestricted, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })

        XCTAssertEqual(result, .succeeded(summary: nil))
        XCTAssertEqual(
            try String(contentsOf: scratch.appendingPathComponent("result.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "ESCAPED", "an unrestricted (unwrapped) run can write outside the project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: escape),
                      "the unwrapped run actually created the outside file")
    }

    func testSafetyValveDisablesWrapperSoFencedRunCanWriteOutside() async throws {
        // The hidden safety valve: with the wrapper disabled, even a FENCED tier
        // spawns directly (escape hatch for a bad profile). Set on the SAME
        // UserDefaults the spawn path reads (`.standard`), and restore after.
        let key = DevSeatbeltSandbox.wrapperDisabledDefaultsKey
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let escape = "/private/var/tmp/zerro-sb-escape-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: escape) }
        let bin = try makeEscapeProbe("valveprobe", escapeTarget: escape)

        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })

        XCTAssertEqual(result, .succeeded(summary: nil))
        XCTAssertEqual(
            try String(contentsOf: scratch.appendingPathComponent("result.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "ESCAPED", "the safety valve disables the wrapper even for a fenced tier")
    }

    func testFencedClaudeNativeAgentIsNotSeatbeltWrappedSoBashCanWriteOutside() async throws {
        // `.claudeNative` confinement (Claude Code, the 401 fix): the runner must NOT
        // sandbox-exec-wrap it even on a FENCED tier — under sandbox-exec a GUI-spawned
        // child is denied securityd Keychain access (→ the agent's own 401). The REAL
        // containment for Bash is Claude Code's OWN built-in sandbox, configured via
        // the injected `--settings` file, which a fake shell "agent" doesn't honor —
        // so here the escape probe WRITES OUTSIDE (ESCAPED), proving ONLY that Zerro's
        // sandbox-exec wrapper is absent (the native sandbox's real OS enforcement is
        // covered by live validation, not this unit). The mirror of a `.zerroSeatbelt`
        // agent's DENIED.
        //
        // The Seatbelt valve is PINNED OFF (wrapper ON) so ESCAPED is attributable
        // SOLELY to `.claudeNative`: a `.zerroSeatbelt` agent here WOULD be wrapped →
        // DENIED, so the test FAILS if Claude's confinement regressed to .zerroSeatbelt.
        try await withWrapperValve(disabled: false) {
            try XCTSkipUnless(DevSeatbeltSandbox.isAvailable(),
                              "needs sandbox-exec so a .zerroSeatbelt agent WOULD be wrapped — the contrast under test")
            let escape = "/private/var/tmp/zerro-sb-escape-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: escape) }
            let bin = try makeEscapeProbe("claudenativeprobe", escapeTarget: escape)

            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })

            XCTAssertEqual(result, .succeeded(summary: nil))
            XCTAssertEqual(
                try String(contentsOf: scratch.appendingPathComponent("result.txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                "ESCAPED",
                "a .claudeNative agent must NOT be sandbox-exec-wrapped (else securityd denies its Keychain → 401)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: escape),
                          "the unwrapped .claudeNative run created the outside file (real fence is Claude's native sandbox)")
        }
    }

    func testFencedClaudeNativeAgentSkipsProxySoBrokenProxyDoesNotFailClosed() async throws {
        // `.claudeNative` never enters the §8-proxy block (that's the .zerroSeatbelt
        // branch), so a proxy that CAN'T start must NOT fail the run closed — the
        // mirror of testFencedRunFailsClosedWhenNetworkProxyCannotStart for a
        // .zerroSeatbelt agent. (Claude's egress is confined by its native sandbox's
        // own allowlist, not the loopback proxy.) The makeNetworkProxy factory must
        // never even be invoked here.
        let bin = try makeScript("claudenativenoproxy", """
        #!/bin/sh
        echo ran > "$PWD/in-repo.txt"
        echo '{"type":"result"}'
        exit 0
        """)
        let runner = ClaudeCodeAgentRunner()
        runner.makeNetworkProxy = { DevNetworkProxy(simulateStartFailure: true) }
        let result = await runner.run(
            entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })

        XCTAssertEqual(result, .succeeded(summary: nil),
                       "a .claudeNative agent must skip the proxy, so a broken proxy can't fail it closed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("in-repo.txt").path),
            "the .claudeNative agent should have run despite the simulated proxy-start failure")
    }

    func testFencedClaudeNativeAgentStillGetsScrubbedEnvThroughRun() async throws {
        // §5b containment must hold on the `.claudeNative` path: run() applies the
        // env-scrub independent of the confinement mode (spawnEnvironment is keyed on
        // tier.isFenced), so a fenced .claudeNative agent still receives the
        // allowlist — NOT the full environment. Detected via an xctest-injected var
        // the §5b allowlist does NOT keep: its ABSENCE in the spawned env proves the
        // scrub ran through run() (a future refactor that gated the scrub on the
        // wrapper would leak it → this fails). Skipped if the host env carries no
        // such non-allowlisted var to detect a leak with.
        let leakKey = "XCTestConfigurationFilePath"
        try XCTSkipUnless(ProcessInfo.processInfo.environment[leakKey] != nil,
                          "needs an xctest-injected non-allowlisted var to detect a scrub leak")
        let bin = try makeEnvDumpProbe("claudenativeenvprobe")
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })

        XCTAssertEqual(result, .succeeded(summary: nil))
        let env = try String(contentsOf: scratch.appendingPathComponent("env.txt"), encoding: .utf8)
        XCTAssertFalse(env.contains(leakKey),
                       "§5b env-scrub must strip non-allowlisted vars even on the unwrapped keychain path")
        XCTAssertTrue(env.contains("PATH="), "the §5b allowlist keeps PATH")
        XCTAssertTrue(env.contains("HOME="), "the §5b allowlist keeps HOME")
    }

    func testFencedRunFailsClosedWhenNetworkProxyCannotStart() async throws {
        try XCTSkipUnless(DevSeatbeltSandbox.isAvailable(), "needs sandbox-exec")
        // The network filter proxy can't start → the fenced run must ABORT (never
        // spawn with open egress). The fake agent would write a marker if it ran; it
        // must NOT, and the result must be .spawnFailed.
        let escape = "/private/var/tmp/zerro-sb-escape-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: escape) }
        let bin = try makeEscapeProbe("failclosedprobe", escapeTarget: escape)

        let runner = ClaudeCodeAgentRunner()
        runner.makeNetworkProxy = { DevNetworkProxy(simulateStartFailure: true) }
        let result = await runner.run(
            entry: entry(path: bin, format: .streamJSON),
            tier: .askPermission, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })

        guard case .failed(.spawnFailed) = result else {
            return XCTFail("expected .spawnFailed (fail-closed), got \(result)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("in-repo.txt").path),
            "the agent must NOT have run when the egress filter failed to start")
    }

    // MARK: - Helpers

    private func parse(_ line: String) -> DevAgentEvent? {
        ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(line)
    }

    private func parseCodex(_ line: String) -> DevAgentEvent? {
        ClaudeCodeAgentRunner.parseCodexJSONLineForTesting(line)
    }

    // MARK: - Claude native sandbox (.claudeNative confinement)

    /// A fake Claude agent that records its full argv to `argv.txt` (one per line —
    /// empty args preserved via the trailing-newline convention) and copies the
    /// `--settings` file's CONTENT to `captured-settings.json` in its cwd (proving
    /// the file existed during the run), writes an in-repo marker, and exits `code`.
    private func makeClaudeSettingsProbe(_ name: String, exit code: Int = 0) throws -> URL {
        try makeScript(name, """
        #!/bin/sh
        printf '%s\\n' "$@" > "$PWD/argv.txt"
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--settings" ]; then cp "$a" "$PWD/captured-settings.json"; fi
          prev="$a"
        done
        echo ran > "$PWD/in-repo.txt"
        echo '{"type":"result"}'
        exit \(code)
        """)
    }

    /// Read the argv the probe recorded, preserving an empty argument (the
    /// `--setting-sources ""` value) and dropping only the trailing-newline blank.
    private func readArgv(_ dir: URL) throws -> [String] {
        var lines = try String(contentsOf: dir.appendingPathComponent("argv.txt"), encoding: .utf8)
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The value after `--settings` in a recorded argv (the transient file path).
    private func settingsPath(in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: "--settings"), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    /// Pin the `.claudeNative` valve for `body`, restoring `UserDefaults.standard`
    /// after (mirrors `withWrapperValve`).
    private func withClaudeNativeValve(disabled: Bool, _ body: () async throws -> Void) async rethrows {
        let key = DevClaudeNativeSandbox.disabledDefaultsKey
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(disabled, forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    func testClaudeNativeFencedRunInjectsSettingsAndStripsBypass() async throws {
        // The core of the native-sandbox path: a fenced `.claudeNative` run STRIPS the
        // registry's `bypassPermissions`, substitutes `--permission-mode dontAsk`,
        // loads NO user/project/local settings (`--setting-sources ""`), and points
        // `--settings` at a transient file whose content enables the native sandbox +
        // permission fence. That file is deleted after the run (success path).
        try await withClaudeNativeValve(disabled: false) {
            let bin = try makeClaudeSettingsProbe("claudenativeargv")
            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                             allowCommandsArgs: ["--permission-mode", "bypassPermissions"]),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            XCTAssertEqual(result, .succeeded(summary: nil))

            let argv = try readArgv(scratch)
            XCTAssertFalse(argv.contains("bypassPermissions"), "fenced .claudeNative must strip bypassPermissions")
            let pmIdx = try XCTUnwrap(argv.firstIndex(of: "--permission-mode"))
            XCTAssertEqual(argv[pmIdx + 1], "dontAsk", "must run in dontAsk")
            let ssIdx = try XCTUnwrap(argv.firstIndex(of: "--setting-sources"))
            XCTAssertEqual(argv[ssIdx + 1], "", "--setting-sources value must be empty (load none)")
            let path = try XCTUnwrap(settingsPath(in: argv))
            XCTAssertTrue(path.hasSuffix(".json"))

            // The settings file existed during the run (the probe copied it)…
            let captured = try String(
                contentsOf: scratch.appendingPathComponent("captured-settings.json"), encoding: .utf8)
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any])
            let sandbox = try XCTUnwrap(json["sandbox"] as? [String: Any])
            XCTAssertEqual(sandbox["enabled"] as? Bool, true)
            XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true)
            XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false)
            let net = try XCTUnwrap(sandbox["network"] as? [String: Any])
            XCTAssertEqual(net["allowLocalBinding"] as? Bool, true)
            let domains = try XCTUnwrap(net["allowedDomains"] as? [String])
            XCTAssertTrue(domains.contains("anthropic.com"))
            XCTAssertTrue(domains.contains("*.npmjs.org"), "production allowlist + subdomain wildcard")
            let perms = try XCTUnwrap(json["permissions"] as? [String: Any])
            XCTAssertEqual(perms["defaultMode"] as? String, "dontAsk")
            let allow = try XCTUnwrap(perms["allow"] as? [String])
            XCTAssertTrue(allow.contains("Bash"))
            XCTAssertTrue(allow.contains { $0.hasPrefix("Edit(//") && $0.hasSuffix("/**)") },
                          "in-repo Edit is allow-scoped with the //-absolute form")
            let deny = try XCTUnwrap(perms["deny"] as? [String])
            XCTAssertTrue(deny.contains("Read(~/.ssh/**)"), "sensitive-path Read deny")

            // …and was deleted after the run (the defer cleanup).
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "the transient --settings file must be deleted after a successful run")
        }
    }

    func testClaudeNativeSettingsFileDeletedOnFailure() async throws {
        // Cleanup must fire on EVERY exit path — here a non-zero exit.
        try await withClaudeNativeValve(disabled: false) {
            let bin = try makeClaudeSettingsProbe("claudenativefail", exit: 1)
            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
            let path = try XCTUnwrap(settingsPath(in: try readArgv(scratch)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "the transient --settings file must be deleted even when the run fails")
        }
    }

    func testClaudeNativeDegradesToUnwrappedWhenSettingsBuildFails() async throws {
        // GRACEFUL DEGRADE: a settings-build/write failure must fall back to today's
        // unwrapped Claude — the run still succeeds, no --settings is injected, and
        // the base bypassPermissions posture is left intact (never a 401/crash/hang).
        try await withClaudeNativeValve(disabled: false) {
            let bin = try makeClaudeSettingsProbe("claudenativedegrade")
            let runner = ClaudeCodeAgentRunner()
            struct Boom: Error {}
            runner.makeClaudeNativeSettingsURL = { _ in throw Boom() }
            let result = await runner.run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                             allowCommandsArgs: ["--permission-mode", "bypassPermissions"]),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            XCTAssertEqual(result, .succeeded(summary: nil), "settings-build failure must degrade, not fail")
            let argv = try readArgv(scratch)
            XCTAssertFalse(argv.contains("--settings"), "degraded run must not inject --settings")
            XCTAssertTrue(argv.contains("bypassPermissions"), "degraded run keeps today's unwrapped posture")
        }
    }

    func testClaudeNativeValveDisablesNativeSandboxSoRunIsUnwrapped() async throws {
        // The hidden safety valve: with it set, a fenced .claudeNative run spawns
        // directly (no --settings) — the escape hatch for a bad settings build.
        try await withClaudeNativeValve(disabled: true) {
            let bin = try makeClaudeSettingsProbe("claudenativevalve")
            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                             allowCommandsArgs: ["--permission-mode", "bypassPermissions"]),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            XCTAssertEqual(result, .succeeded(summary: nil))
            let argv = try readArgv(scratch)
            XCTAssertFalse(argv.contains("--settings"), "valve disabled ⇒ native sandbox off ⇒ no --settings")
            XCTAssertTrue(argv.contains("bypassPermissions"), "valve disabled ⇒ unwrapped Claude")
        }
    }

    func testClaudeNativeUnrestrictedTierIsNotConfined() async throws {
        // `.unrestricted` is never fenced, so even a .claudeNative agent spawns
        // directly with no --settings (today's behavior).
        let bin = try makeClaudeSettingsProbe("claudenativeunrestricted")
        let result = await ClaudeCodeAgentRunner().run(
            entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                         allowCommandsArgs: ["--permission-mode", "bypassPermissions"]),
            tier: .unrestricted, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(), onEvent: { _ in })
        XCTAssertEqual(result, .succeeded(summary: nil))
        let argv = try readArgv(scratch)
        XCTAssertFalse(argv.contains("--settings"), "unrestricted ⇒ no native sandbox")
        XCTAssertTrue(argv.contains("bypassPermissions"), "unrestricted keeps the base posture")
    }

    // MARK: - Claude native sandbox — minimum-version gate

    func testClaudeNativeAtMinimumVersionAppliesNativeSettings() async throws {
        // Boundary: a version EQUAL to the minimum is supported → native flags applied.
        try await withClaudeNativeValve(disabled: false) {
            let bin = try makeClaudeSettingsProbe("claudenativeminver")
            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                             allowCommandsArgs: ["--permission-mode", "bypassPermissions"],
                             detectedVersion: DevClaudeNativeSandbox.minimumSupportedVersionString + " (Claude Code)"),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            XCTAssertEqual(result, .succeeded(summary: nil))
            let argv = try readArgv(scratch)
            XCTAssertTrue(argv.contains("--settings"), "version == min ⇒ native settings applied")
            XCTAssertTrue(argv.contains("--setting-sources"))
            XCTAssertFalse(argv.contains("bypassPermissions"))
        }
    }

    func testClaudeNativeBelowMinimumVersionRunsUnwrapped() async throws {
        // An OLDER Claude (below the floor) would reject our flags → degrade to
        // unwrapped (no --settings, base posture intact), and the run still succeeds.
        try await withClaudeNativeValve(disabled: false) {
            let bin = try makeClaudeSettingsProbe("claudenativeoldver")
            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                             allowCommandsArgs: ["--permission-mode", "bypassPermissions"],
                             detectedVersion: "2.1.0 (Claude Code)"),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            XCTAssertEqual(result, .succeeded(summary: nil), "old version must degrade, not fail")
            let argv = try readArgv(scratch)
            XCTAssertFalse(argv.contains("--settings"), "below-min ⇒ no native settings")
            XCTAssertFalse(argv.contains("--setting-sources"))
            XCTAssertTrue(argv.contains("bypassPermissions"), "below-min ⇒ unwrapped Claude")
        }
    }

    func testClaudeNativeUndetectableVersionRunsUnwrapped() async throws {
        // Version unknown (probe failed / unparseable) → degrade to unwrapped, no failure.
        try await withClaudeNativeValve(disabled: false) {
            let bin = try makeClaudeSettingsProbe("claudenativenover")
            let result = await ClaudeCodeAgentRunner().run(
                entry: entry(path: bin, format: .streamJSON, confinement: .claudeNative,
                             allowCommandsArgs: ["--permission-mode", "bypassPermissions"],
                             detectedVersion: nil),
                tier: .askPermission, prompt: "go", projectURL: scratch,
                timeouts: fastTimeouts(), onEvent: { _ in })
            XCTAssertEqual(result, .succeeded(summary: nil), "undetectable version must degrade, not fail")
            let argv = try readArgv(scratch)
            XCTAssertFalse(argv.contains("--settings"), "undetectable ⇒ no native settings")
            XCTAssertTrue(argv.contains("bypassPermissions"), "undetectable ⇒ unwrapped Claude")
        }
    }

    private func fastTimeouts() -> DevRunTimeouts {
        DevRunTimeouts(stall: 30, killGrace: 1)
    }

    private func entry(path: URL, format: DevAgentOutputFormat,
                       credentialStore: DevAgentCredentialStore = .file,
                       confinement: DevAgentConfinement = .zerroSeatbelt,
                       allowCommandsArgs: [String] = [],
                       // Defaults to a clearly-supported version so `.claudeNative`
                       // tests exercise the native path; the version-gate tests pass
                       // an explicit below-min / nil value.
                       detectedVersion: String? = "9999.0.0") -> DevAgentEntry {
        DevAgentEntry(
            id: "fake", displayName: "Fake", executableName: path.lastPathComponent,
            promptDelivery: .stdin, outputFormat: format,
            baseArgs: [], editsOnlyArgs: [], allowCommandsArgs: allowCommandsArgs,
            installed: true, absolutePath: path,
            credentialStore: credentialStore, confinement: confinement,
            detectedVersion: detectedVersion
        )
    }

    private func makeScript(_ name: String, _ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("\(name).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: G-02 process-tree helpers

    /// A fake agent that backgrounds a child which writes `sentinel.txt` after a
    /// 2s delay, records the child's pid in `child.txt`, then streams forever.
    /// If a terminate reaps only the agent pid, the orphaned child survives and
    /// the sentinel appears — the G-02 failure the tree tests assert against.
    private func makeChildSentinelProbe(_ name: String) throws -> URL {
        try makeScript(name, """
        #!/bin/sh
        ( sleep 2; echo escaped > "$PWD/sentinel.txt" ) &
        echo $! > "$PWD/child.txt"
        while true; do echo '{"type":"system"}'; sleep 0.2; done
        """)
    }

    private var sentinelPath: String { scratch.appendingPathComponent("sentinel.txt").path }

    /// Wait for the probe to write its pid file (spawn is async), then parse it.
    private func waitForPIDFile(_ name: String, timeout: TimeInterval = 5) async throws -> pid_t {
        let url = scratch.appendingPathComponent(name)
        let appeared = await waitUntil(timeout: timeout) {
            // Written by `echo` (create + write aren't atomic): require the
            // trailing newline so a half-written file isn't parsed as pid 0.
            (try? String(contentsOf: url, encoding: .utf8))?.contains("\n") == true
        }
        guard appeared,
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else {
            struct NoPID: Error {}
            XCTFail("probe never wrote a usable \(name)")
            throw NoPID()
        }
        return pid
    }

    /// Poll `condition` (~every 50ms) until it holds or `timeout` elapses.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// Sleep until `total` seconds have passed since `start` (no-op if already
    /// past) — used to outwait the sentinel child's write delay.
    private func sleepPast(_ start: Date, total: TimeInterval) async throws {
        let remaining = total - Date().timeIntervalSince(start)
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }
}

/// Thread-safe collector for the runner's `onStall` callbacks (fired off-main).
private final class StallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func append(_ v: Bool) { lock.lock(); items.append(v); lock.unlock() }
    func values() -> [Bool] { lock.lock(); defer { lock.unlock() }; return items }
}
