//
//  DevAgentRunner.swift
//  Zerro
//
//  Dev Mode (Phase 1, Milestone 4) — spawns a coding-agent CLI in the project
//  and streams its progress to the pill (design §9). A protocol fronts the
//  concrete `ClaudeCodeAgentRunner` so a future first-party API agent loop is a
//  clean substitution.
//
//  Responsibilities:
//    • Spawn via `Process` at the registry-resolved ABSOLUTE binary path
//      (GUI PATH is stripped — §11), `currentDirectoryURL = projectURL`, the
//      registry args, with the prompt written to STDIN (no shell-quoting a long
//      multi-line prompt). stdin is closed right after (defensive hang guard).
//    • Parse `stream-json` events → a `DevRunSubstatus` stream the pill consumes
//      ("reading files", "editing <file>", "running", "working…", "done").
//    • Two timeouts: an overall wall-clock cap (default 5 min) and an inactivity
//      cap (no output for 60s → presumed hung). Either fires SIGTERM, then
//      SIGKILL after a short grace → `.failed(.timeout)`.
//    • Non-zero exit → `.failed(.nonZeroExit)`; clean exit → `.succeeded`.
//    • Concurrency: at most one run at a time (§9); a second is rejected
//      `.failed(.busy)`.
//
//  Isolation: the module defaults to MainActor isolation, but all process I/O
//  runs on a private serial queue (terminationHandler / readability handlers /
//  timers fire off-main). The execution type is therefore explicitly
//  `nonisolated` throughout, with its queue-guarded mutable state marked
//  `nonisolated(unsafe)` — the serial queue is the synchronization, not the
//  actor.
//
//  The `stream-json` event field names were verified at Milestone 9 against the
//  Claude Code schema (code.claude.com docs, June 2026) — see
//  `parseStreamJSONLine`. Parsing stays defensive regardless: unknown shapes
//  degrade to "working…", never crash, so a future CLI revision can't break a run.
//

import Foundation
import os

// MARK: - Public result/status types

/// Live progress for the pill's `agentRunning` substatus line.
enum DevRunSubstatus: Equatable, Sendable {
    case readingFiles
    case editing(file: String)
    case running
    case working
    case done

    /// Short pill label.
    var label: String {
        switch self {
        case .readingFiles:     return "reading files"
        case .editing(let f):   return f.isEmpty ? "editing files" : "editing \(f)"
        case .running:          return "running"
        case .working:          return "working…"
        case .done:             return "done"
        }
    }
}

enum DevRunFailureReason: Equatable, Sendable {
    enum TimeoutKind: Equatable, Sendable { case wallClock, inactivity }
    /// The agent process exceeded a timeout and was killed.
    case timeout(TimeoutKind)
    /// The process exited non-zero. `stderrTail` is the trimmed tail of stderr.
    case nonZeroExit(code: Int32, stderrTail: String)
    /// The process couldn't be spawned (missing binary, etc.).
    case spawnFailed(String)
    /// A run was already in flight (concurrency cap-1).
    case busy
    /// The run was cancelled (the user aborted the dispatch). Same SIGTERM→
    /// SIGKILL teardown as a timeout, but a distinct reason so the caller can
    /// treat it as a user action (auto-revert) rather than an error.
    case cancelled
}

enum DevRunResult: Equatable, Sendable {
    case succeeded
    case failed(DevRunFailureReason)
}

/// Timeout configuration (design §9). Injectable so tests can use short caps.
struct DevRunTimeouts: Sendable {
    var wallClock: TimeInterval
    var inactivity: TimeInterval
    /// Grace between SIGTERM and SIGKILL.
    var killGrace: TimeInterval

    static let `default` = DevRunTimeouts(wallClock: 300, inactivity: 60, killGrace: 2)
}

// MARK: - Protocol

protocol DevAgentRunner: AnyObject, Sendable {
    /// Run `entry` against `projectURL` with `prompt`. `onSubstatus` is invoked
    /// on the main queue as progress events arrive. Returns the terminal result.
    func run(
        entry: DevAgentEntry,
        permission: DevAgentPermission,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        onSubstatus: @escaping @Sendable (DevRunSubstatus) -> Void
    ) async -> DevRunResult

    /// Terminate the in-flight run (SIGTERM, then SIGKILL after the grace) so
    /// the agent stops editing immediately. A no-op when nothing is running.
    /// The pending `run(...)` resolves `.failed(.cancelled)`. Safe to call from
    /// any thread.
    func cancel()
}

extension DevAgentRunner {
    func run(
        entry: DevAgentEntry,
        permission: DevAgentPermission,
        prompt: String,
        projectURL: URL,
        onSubstatus: @escaping @Sendable (DevRunSubstatus) -> Void
    ) async -> DevRunResult {
        await run(entry: entry, permission: permission, prompt: prompt,
                  projectURL: projectURL, timeouts: .default, onSubstatus: onSubstatus)
    }
}

// MARK: - Claude Code runner

final class ClaudeCodeAgentRunner: DevAgentRunner, @unchecked Sendable {

    /// Serializes process lifecycle + the cap-1 concurrency flag.
    nonisolated private let queue = DispatchQueue(label: "com.zerro.dev.agentRunner")
    nonisolated(unsafe) private var isRunning = false
    /// Strong reference that keeps the in-flight execution alive for the whole
    /// run. Without it the execution — referenced only weakly by its own
    /// process/timer handlers — would deallocate the moment `start()` returns,
    /// so the termination handler's `[weak self]` would be nil, `finish()` would
    /// never fire, and the continuation would never resume (run() would hang).
    nonisolated(unsafe) private var activeExecution: DevAgentProcessExecution?

    nonisolated init() {}

    // Matches the protocol requirement's isolation (the module defaults to
    // MainActor). The body's only main-actor touch is the brief cap-1 flag flip
    // via `queue.sync`; all process I/O is off-main on `queue`.
    func run(
        entry: DevAgentEntry,
        permission: DevAgentPermission,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        onSubstatus: @escaping @Sendable (DevRunSubstatus) -> Void
    ) async -> DevRunResult {
        // Concurrency cap-1: reject a second dispatch (design §9).
        let acquired: Bool = queue.sync {
            if isRunning { return false }
            isRunning = true
            return true
        }
        guard acquired else {
            Log.dev.notice("Dev agent run rejected — already running")
            return .failed(.busy)
        }
        // Release the cap-1 flag AND drop the execution retention on exit.
        defer { queue.sync { isRunning = false; activeExecution = nil } }

        guard let executableURL = entry.absolutePath else {
            return .failed(.spawnFailed("agent '\(entry.id)' has no resolved executable path"))
        }

        let execution = DevAgentProcessExecution(
            executableURL: executableURL,
            arguments: entry.arguments(permission: permission),
            prompt: prompt,
            projectURL: projectURL,
            outputFormat: entry.outputFormat,
            timeouts: timeouts,
            queue: queue,
            onSubstatus: onSubstatus
        )
        // Keep it alive for the duration (see `activeExecution`).
        queue.sync { activeExecution = execution }
        return await withCheckedContinuation { continuation in
            execution.start { result in continuation.resume(returning: result) }
        }
    }

    /// Terminate any in-flight execution. Forwarded onto the runner's serial
    /// queue so it can't race the spawn/finish bookkeeping; the active
    /// execution (if any) runs the same SIGTERM→SIGKILL teardown the timeouts
    /// use and resolves `.failed(.cancelled)`.
    nonisolated func cancel() {
        queue.async { [weak self] in self?.activeExecution?.cancel() }
    }

    /// Testing seam for the `stream-json` substatus parser (the parser lives on
    /// the file-private execution type).
    nonisolated static func parseStreamJSONLineForTesting(_ line: String) -> DevRunSubstatus? {
        DevAgentProcessExecution.parseStreamJSONLine(line)
    }
}

// MARK: - One process execution

/// Encapsulates a single agent process: spawn, stream-parse, dual timeouts, and
/// a once-only completion. All mutable state is touched on the runner's serial
/// `queue` so the termination handler, the timeout timer, and the readability
/// handlers can't race the completion. Explicitly `nonisolated` (see file
/// header): the queue is the synchronization domain.
private final class DevAgentProcessExecution: @unchecked Sendable {

    nonisolated(unsafe) private let process = Process()
    nonisolated(unsafe) private let stdinPipe = Pipe()
    nonisolated(unsafe) private let stdoutPipe = Pipe()
    nonisolated(unsafe) private let stderrPipe = Pipe()

    nonisolated private let arguments: [String]
    nonisolated private let prompt: String
    nonisolated private let outputFormat: DevAgentOutputFormat
    nonisolated private let timeouts: DevRunTimeouts
    nonisolated private let queue: DispatchQueue
    nonisolated private let onSubstatus: @Sendable (DevRunSubstatus) -> Void

    nonisolated(unsafe) private var completion: ((DevRunResult) -> Void)?
    nonisolated(unsafe) private var finished = false
    nonisolated(unsafe) private var killReason: DevRunFailureReason.TimeoutKind?
    /// Set when the run was cancelled (vs. timed out) so `handleTermination`
    /// resolves `.cancelled` rather than a timeout/exit.
    nonisolated(unsafe) private var cancelled = false
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    nonisolated(unsafe) private var startTime = Date()
    nonisolated(unsafe) private var lastActivity = Date()
    nonisolated(unsafe) private var stdoutBuffer = Data()
    nonisolated(unsafe) private var stderrTail = ""

    nonisolated init(
        executableURL: URL,
        arguments: [String],
        prompt: String,
        projectURL: URL,
        outputFormat: DevAgentOutputFormat,
        timeouts: DevRunTimeouts,
        queue: DispatchQueue,
        onSubstatus: @escaping @Sendable (DevRunSubstatus) -> Void
    ) {
        self.arguments = arguments
        self.prompt = prompt
        self.outputFormat = outputFormat
        self.timeouts = timeouts
        self.queue = queue
        self.onSubstatus = onSubstatus

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = projectURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = DevAgentProcessExecution.spawnEnvironment(for: executableURL)
    }

    nonisolated func start(completion: @escaping (DevRunResult) -> Void) {
        queue.async { self.startOnQueue(completion: completion) }
    }

    nonisolated private func startOnQueue(completion: @escaping (DevRunResult) -> Void) {
        self.completion = completion
        startTime = Date()
        lastActivity = startTime

        process.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.handleTermination(status: proc.terminationStatus) }
        }

        // Stream stdout: accumulate, split on newlines, parse → substatus.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.ingestStdout(data) }
        }
        // Drain stderr (keep a tail for the failure message) + count as activity.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.ingestStderr(data) }
        }

        do {
            try process.run()
        } catch {
            finish(.failed(.spawnFailed(String(describing: error))))
            return
        }

        // Deliver the prompt on stdin and close it (the defensive hang guard —
        // a CLI waiting on stdin EOF won't stall). Write off-queue so a large
        // prompt blocking on a slow reader can't stall the run loop.
        let promptData = Data(prompt.utf8)
        let handle = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? handle.write(contentsOf: promptData)
            try? handle.close()
        }

        // Emit an initial generic substatus so the pill shows motion before the
        // first parsed event.
        emit(.working)

        startTimeoutTimer()
    }

    // MARK: Timers

    nonisolated private func startTimeoutTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Tick at 0.5s so a 1s test inactivity cap is observed promptly.
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkTimeouts() }
        timer = t
        t.resume()
    }

    nonisolated private func checkTimeouts() {
        guard !finished else { return }
        let now = Date()
        if now.timeIntervalSince(startTime) >= timeouts.wallClock {
            beginTimeoutKill(reason: .wallClock)
        } else if now.timeIntervalSince(lastActivity) >= timeouts.inactivity {
            beginTimeoutKill(reason: .inactivity)
        }
    }

    nonisolated private func beginTimeoutKill(reason: DevRunFailureReason.TimeoutKind) {
        guard !finished, killReason == nil, !cancelled else { return }
        killReason = reason
        Log.dev.notice("Dev agent timeout (\(String(describing: reason), privacy: .public)) — terminating")
        terminateWithGrace()
    }

    /// User-initiated cancel. Same SIGTERM→SIGKILL teardown as a timeout, but
    /// flagged `cancelled` so termination resolves `.cancelled`. Runs on the
    /// serial `queue` (the runner forwards it there). A no-op once finished or
    /// already tearing down — so a cancel that races a timeout/normal exit is
    /// harmless.
    nonisolated func cancel() {
        guard !finished, killReason == nil, !cancelled else { return }
        cancelled = true
        Log.dev.notice("Dev agent cancelled — terminating")
        terminateWithGrace()
    }

    /// SIGTERM now, SIGKILL after the grace if it hasn't exited. Shared by the
    /// timeout and cancel paths.
    nonisolated private func terminateWithGrace() {
        // `process.terminate()` throws if the process never started; guard on
        // isRunning so a cancel during spawn is a safe no-op.
        if process.isRunning { process.terminate() } // SIGTERM
        queue.asyncAfter(deadline: .now() + timeouts.killGrace) { [weak self] in
            guard let self, !self.finished, self.process.isRunning else { return }
            _ = kill(self.process.processIdentifier, SIGKILL)
        }
    }

    // MARK: Stream ingestion

    nonisolated private func ingestStdout(_ data: Data) {
        guard !finished else { return }
        if !data.isEmpty { lastActivity = Date() }
        stdoutBuffer.append(data)
        // Process complete lines; keep the trailing partial in the buffer.
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if outputFormat == .streamJSON,
               let status = DevAgentProcessExecution.parseStreamJSONLine(line) {
                emit(status)
            }
        }
    }

    nonisolated private func ingestStderr(_ data: Data) {
        guard !finished else { return }
        lastActivity = Date()
        if let s = String(data: data, encoding: .utf8) {
            stderrTail = String((stderrTail + s).suffix(1000))
        }
    }

    // MARK: Termination + completion

    nonisolated private func handleTermination(status: Int32) {
        if cancelled {
            finish(.failed(.cancelled))
            return
        }
        if let killReason {
            finish(.failed(.timeout(killReason)))
            return
        }
        // Flush any buffered final line.
        if outputFormat == .streamJSON, !stdoutBuffer.isEmpty,
           let line = String(data: stdoutBuffer, encoding: .utf8),
           let s = DevAgentProcessExecution.parseStreamJSONLine(line) {
            emit(s)
        }
        if status == 0 {
            finish(.succeeded)
        } else {
            finish(.failed(.nonZeroExit(
                code: status,
                stderrTail: stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            )))
        }
    }

    /// Resolve exactly once; tear down timer + handlers.
    nonisolated private func finish(_ result: DevRunResult) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    nonisolated private func emit(_ status: DevRunSubstatus) {
        DispatchQueue.main.async { [onSubstatus] in onSubstatus(status) }
    }

    // MARK: - stream-json parsing (best-effort, defensive)

    /// Map one `stream-json` line to a substatus, or nil when the line carries
    /// no progress signal. Tolerant of unknown shapes (returns nil rather than
    /// crashing).
    ///
    /// Verified at M9 against the Claude Code stream-json schema (code.claude.com
    /// docs, June 2026): without `--include-partial-messages` (we don't pass it),
    /// the stream is line-delimited COMPLETE messages — `system`(init/…),
    /// `assistant` (tool_use blocks), `user` (tool results), and a terminal
    /// `result`. The `tool_use` block is the Anthropic Messages API shape
    /// (`{type,id,name,input}`). Tool names span CLI versions: current builds use
    /// `Edit`/`Write`/`Read`/`Glob`/`Grep`/`Bash`/`Agent` (the subagent tool;
    /// `Task` is now the task-list family) and route directory listing through
    /// `Bash` (the old `LS` tool is gone). We keep the legacy names too so an
    /// older installed CLI still maps; an unknown tool degrades to "working…".
    nonisolated static func parseStreamJSONLine(_ line: String) -> DevRunSubstatus? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        switch obj["type"] as? String {
        case "result":
            return .done
        case "assistant":
            // message.content: [{ type: "tool_use", name: "Edit", input: {...} }]
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for item in content where item["type"] as? String == "tool_use" {
                    return substatus(forTool: item["name"] as? String,
                                     input: item["input"] as? [String: Any])
                }
            }
            return nil
        default:
            return nil
        }
    }

    nonisolated private static func substatus(forTool name: String?, input: [String: Any]?) -> DevRunSubstatus {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            // `file_path` for Edit/Write; `notebook_path` for older NotebookEdit.
            // `MultiEdit` is legacy (merged into Edit's `replace_all`) — kept for
            // older CLIs.
            let path = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String) ?? ""
            return .editing(file: (path as NSString).lastPathComponent)
        case "Read", "Glob", "Grep", "LS":
            // `LS` is legacy (directory listing now goes through Bash); kept for
            // older CLIs.
            return .readingFiles
        case "Bash", "Agent", "Task":
            // `Agent` is the current subagent tool; `Task` was its old name.
            return .running
        default:
            return .working
        }
    }

    // MARK: - Spawn environment

    /// Forward the user's environment, but guarantee a usable PATH: GUI apps
    /// inherit a stripped PATH, and Claude Code (a Node CLI) shells out to
    /// `node` and friends. Prefer the LOGIN-SHELL PATH captured during detection
    /// (`DevAgentBinaryResolver`) — it contains the version-manager `node` dir
    /// (nvm/asdf) that a hand-built list would miss — falling back to a static
    /// list only when detection hasn't warmed it. The binary's own dir is always
    /// prepended. The CLIs read their own auth config (~/.claude, …), readable
    /// since we're non-sandboxed.
    nonisolated static func spawnEnvironment(for executableURL: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = executableURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let base: [String]
        if let login = DevAgentBinaryResolver.cachedLoginShellPATH(), !login.isEmpty {
            base = login.split(separator: ":").map(String.init)
        } else {
            base = [
                "/opt/homebrew/bin", "/usr/local/bin",
                "\(home)/.local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            ]
        }
        let inherited = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        // De-dupe while preserving order (binDir first so the agent's own
        // toolchain dir wins, then the login PATH, then anything inherited).
        var seen = Set<String>()
        let merged = ([binDir] + base + inherited)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        env["PATH"] = merged
        return env
    }
}
