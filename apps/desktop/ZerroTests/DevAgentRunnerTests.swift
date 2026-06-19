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
            permission: .editsOnly, prompt: "go", projectURL: scratch,
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
            permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: fastTimeouts(),
            onEvent: { _ in }
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
            onEvent: { _ in }
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
            onEvent: { _ in }
        )
        XCTAssertEqual(result, .failed(.nonZeroExit(code: 3, stderrTail: "kaboom")))
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
            permission: .editsOnly, prompt: "go", projectURL: scratch,
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
            permission: .editsOnly, prompt: "go", projectURL: scratch,
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
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
            timeouts: DevRunTimeouts(stall: 30, killGrace: 1),
            onEvent: { _ in }
        )
        // Let the first run acquire the cap-1 flag.
        try await Task.sleep(nanoseconds: 250_000_000)
        let second = await runner.run(
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
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
            entry: e, permission: .editsOnly, prompt: "go", projectURL: scratch,
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
            onEvent: { _ in }
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

    // MARK: - Helpers

    private func parse(_ line: String) -> DevAgentEvent? {
        ClaudeCodeAgentRunner.parseStreamJSONLineForTesting(line)
    }

    private func fastTimeouts() -> DevRunTimeouts {
        DevRunTimeouts(stall: 30, killGrace: 1)
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

/// Thread-safe collector for the runner's `onStall` callbacks (fired off-main).
private final class StallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func append(_ v: Bool) { lock.lock(); items.append(v); lock.unlock() }
    func values() -> [Bool] { lock.lock(); defer { lock.unlock() }; return items }
}
