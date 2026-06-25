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
//    • Parse `stream-json` events → a `DevAgentEvent` stream the pill consumes as
//      a live activity feed (one line per tool call / read / run / search /
//      message / thought, each carrying its specifics) plus a coarse legacy
//      substatus for the single-line pill until the feed lands (Part 5).
//    • Stall NOTIFICATION — never a kill. A 0.5s watchdog tracks the time since
//      the last process output; after `DevRunTimeouts.stall` seconds of silence it
//      fires `onStall(true)` ONCE so the UI can ask the user whether to keep
//      waiting — the process is left running underneath. The next output fires
//      `onStall(false)`. The ONLY thing that terminates the agent is an explicit
//      `cancel()` (the user's Kill/Cancel, or app quit).
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

/// Coarse legacy progress for the pill's single-line `agentRunning` substatus.
/// Retained as a bridge while the rich live feed (`DevAgentEvent`) lands in the
/// UI (Part 5); the runner now emits `DevAgentEvent` and derives this from it.
enum DevRunSubstatus: Equatable, Sendable {
    case readingFiles
    case editing(file: String)
    case running
    case working
    case done

    /// Short pill label.
    var label: String {
        switch self {
        case .readingFiles:     return "Exploring your codebase…"
        case .editing(let f):   return f.isEmpty ? "Editing files…" : "Editing \(f)…"
        case .running:          return "Running commands…"
        case .working:          return "Working on your changes…"
        case .done:             return "Done"
        }
    }
}

/// One meaningful event the agent emitted, captured WITH its specifics, for the
/// live activity feed (transparency: §9 + Phase 4). `detail` is the file name /
/// command / search pattern / message text the feed renders — it stays ON SCREEN
/// only and must NEVER reach analytics (§14.5 keeps telemetry metadata-only).
///
/// `kind` drives the feed icon + verb; `detail` fills in the specifics. The
/// parser produces one event per agent message (preferring a concrete tool action
/// over narration). `id`/`timestamp` are per-emission identity + ordering for the
/// SwiftUI feed and are deliberately excluded from value equality.
struct DevAgentEvent: Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case thinking      // detail: nil
        case reading       // detail: file
        case searching     // detail: pattern
        case listing       // detail: directory
        case editing       // detail: file
        case running       // detail: command
        case message       // detail: the agent's narration text
        case toolResult    // detail: a short result summary (reserved)
        case working       // generic motion (unknown/initial)
        case done          // the terminal `result` event
    }

    let id: UUID
    let kind: Kind
    let detail: String?
    let timestamp: Date

    init(kind: Kind, detail: String? = nil, id: UUID = UUID(), timestamp: Date = Date()) {
        self.kind = kind
        self.detail = detail
        self.id = id
        self.timestamp = timestamp
    }

    /// Coarse legacy substatus for the single-line pill (Part 5 replaces this with
    /// the feed). Collapses the rich kinds back to the original five.
    var substatus: DevRunSubstatus {
        switch kind {
        case .editing:                                   return .editing(file: detail ?? "")
        case .reading, .searching, .listing:             return .readingFiles
        case .running:                                   return .running
        case .done:                                      return .done
        case .thinking, .message, .toolResult, .working: return .working
        }
    }
}

extension DevAgentEvent: Equatable {
    /// Value equality compares the semantic payload (kind + detail) only; `id`
    /// and `timestamp` are per-emission identity/ordering, not value — so a parsed
    /// event can be compared against an expected payload in tests.
    static func == (lhs: DevAgentEvent, rhs: DevAgentEvent) -> Bool {
        lhs.kind == rhs.kind && lhs.detail == rhs.detail
    }
}

enum DevRunFailureReason: Equatable, Sendable {
    /// The process exited non-zero. `stderrTail` is the trimmed tail of stderr.
    case nonZeroExit(code: Int32, stderrTail: String)
    /// The process couldn't be spawned (missing binary, etc.).
    case spawnFailed(String)
    /// A run was already in flight (concurrency cap-1).
    case busy
    /// The run was terminated by an explicit user action — Cancel, the stall
    /// prompt's "Kill the process", or app quit. The SOLE termination path: the
    /// stall watchdog only notifies and never lands here. A distinct reason so the
    /// caller can treat it as a user action (revert / keep-edits) rather than an
    /// error.
    case cancelled
}

enum DevRunResult: Equatable, Sendable {
    /// Clean exit. `summary` is the agent's final message text captured from the
    /// terminal stream-json `result` event (its `result` string), or nil when the
    /// event carried no usable text — the UI then falls back to a generated
    /// change line (the result-card handoff, Part A).
    case succeeded(summary: String?)
    case failed(DevRunFailureReason)
}

/// Run configuration (design §9 + Phase 4). Injectable so tests can use a short
/// stall threshold. There is NO wall-clock or inactivity *kill* — the only
/// termination is an explicit user action (see `DevRunFailureReason.cancelled`).
struct DevRunTimeouts: Sendable {
    /// Seconds of silence (no process output) before the stall NOTIFICATION
    /// (`onStall(true)`) fires. The process is never touched — the next output
    /// fires `onStall(false)` and re-arms.
    var stall: TimeInterval
    /// Grace between SIGTERM and SIGKILL on the user-initiated terminate path.
    var killGrace: TimeInterval

    static let `default` = DevRunTimeouts(stall: 180, killGrace: 2)
}

// MARK: - Protocol

protocol DevAgentRunner: AnyObject, Sendable {
    /// Run `entry` against `projectURL` with `prompt`. `model` is the selected
    /// `--model` id (Phase 2) appended to argv only when non-nil AND the entry
    /// declares a `modelFlagName`; nil ⇒ the agent's own default.
    ///
    /// `onEvent` is invoked on the main queue for each meaningful agent event (the
    /// live feed). `onStall` is invoked on the main queue with `true` once the
    /// agent has been silent for `timeouts.stall` seconds, and `false` on the next
    /// output after a stall — a NOTIFICATION only; it never terminates the process.
    /// Returns the terminal result.
    func run(
        entry: DevAgentEntry,
        tier: DevPermissionTier,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        model: String?,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void,
        onStall: @escaping @Sendable (Bool) -> Void
    ) async -> DevRunResult

    /// Terminate the in-flight run (SIGTERM, then SIGKILL after the grace) so
    /// the agent stops editing immediately. A no-op when nothing is running.
    /// The pending `run(...)` resolves `.failed(.cancelled)`. Safe to call from
    /// any thread. THE ONLY termination path (the stall watchdog never calls it).
    func cancel()
}

extension DevAgentRunner {
    /// Convenience: default timeouts, no model, no stall handler (the agent's own
    /// default model — used by simple test paths).
    func run(
        entry: DevAgentEntry,
        tier: DevPermissionTier,
        prompt: String,
        projectURL: URL,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void
    ) async -> DevRunResult {
        await run(entry: entry, tier: tier, prompt: prompt,
                  projectURL: projectURL, timeouts: .default, model: nil,
                  onEvent: onEvent, onStall: { _ in })
    }

    /// Convenience: explicit timeouts, no model, no stall handler.
    func run(
        entry: DevAgentEntry,
        tier: DevPermissionTier,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void
    ) async -> DevRunResult {
        await run(entry: entry, tier: tier, prompt: prompt,
                  projectURL: projectURL, timeouts: timeouts, model: nil,
                  onEvent: onEvent, onStall: { _ in })
    }

    /// Convenience: explicit timeouts + model, no stall handler (the test path
    /// that asserts argv/model threading without exercising the stall prompt).
    func run(
        entry: DevAgentEntry,
        tier: DevPermissionTier,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        model: String?,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void
    ) async -> DevRunResult {
        await run(entry: entry, tier: tier, prompt: prompt,
                  projectURL: projectURL, timeouts: timeouts, model: model,
                  onEvent: onEvent, onStall: { _ in })
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

    /// Factory for the §8 network filter proxy. Defaults to the real one; a test can
    /// substitute a proxy that fails to start to exercise the fail-closed path.
    nonisolated(unsafe) var makeNetworkProxy: @Sendable () -> DevNetworkProxy = { DevNetworkProxy() }

    nonisolated init() {}

    // Matches the protocol requirement's isolation (the module defaults to
    // MainActor). The body's only main-actor touch is the brief cap-1 flag flip
    // via `queue.sync`; all process I/O is off-main on `queue`.
    func run(
        entry: DevAgentEntry,
        tier: DevPermissionTier,
        prompt: String,
        projectURL: URL,
        timeouts: DevRunTimeouts,
        model: String?,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void,
        onStall: @escaping @Sendable (Bool) -> Void
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

        // §8 network filter proxy: started below for a network-filtered fenced run
        // and ALWAYS torn down here (run() awaits the agent to completion before
        // returning, so this fires after the agent exits — including cancel/quit).
        var networkProxy: DevNetworkProxy?
        defer { networkProxy?.stop() }

        guard let executableURL = entry.absolutePath else {
            return .failed(.spawnFailed("agent '\(entry.id)' has no resolved executable path"))
        }

        // Build argv + decide prompt delivery. Claude Code reads the prompt on
        // STDIN (`.stdin`); Codex takes it as a POSITIONAL argument (`.argument`)
        // — appended last, after the flags — and reads stdin only when piped, so
        // for `.argument` we write nothing and just close stdin (EOF).
        var argv = entry.arguments(tier: tier, model: model)
        let deliverPromptViaStdin = entry.promptDelivery == .stdin
        if entry.promptDelivery == .argument {
            argv.append(prompt)
        }

        // §5c filesystem confinement: the FENCED tiers run the agent under a
        // Zerro-owned Seatbelt profile (`sandbox-exec`) that physically blocks
        // file-writes outside the project dir; `.unrestricted` spawns the agent
        // DIRECTLY (today's behavior), no wrapper. Everything else (cwd = project,
        // the §5b scrubbed env keyed on the REAL agent, the stdin prompt + close)
        // is identical either way — sandbox-exec exec's into the agent in the same
        // PID, inheriting stdin/stdout/stderr, so stream-json parsing is unchanged.
        //
        // NO NESTING (spec §10): Seatbelt sandboxes can't nest, so this wrapper
        // REQUIRES each agent's own native sandbox to be OFF — which the fenced
        // tiers already guarantee (Claude: bypassPermissions/none; Codex:
        // danger-full-access; Cursor: --force). Pairing the wrapper with an agent's
        // own Seatbelt sandbox would fail with "Operation not permitted".
        var spawnExecutableURL = executableURL
        var spawnArguments = argv
        var proxyURL: String?
        if tier.isFenced && !DevSeatbeltSandbox.isWrapperDisabled() {
            // Fail CLOSED: if sandbox-exec is missing (or the safety valve is off
            // but the binary vanished), abort — never silently drop the fence.
            guard DevSeatbeltSandbox.isAvailable() else {
                Log.dev.error("Dev agent run aborted — \(DevSeatbeltSandbox.sandboxExecPath, privacy: .public) unavailable; refusing to run a fenced-tier agent unsandboxed")
                return .failed(.spawnFailed(
                    "filesystem sandbox unavailable — \(DevSeatbeltSandbox.sandboxExecPath) is missing, so the agent can't be confined to the project. Refusing to run unsandboxed in this tier."))
            }

            // §8 network egress filter: start a loopback host-allowlisting proxy and
            // lock the Seatbelt profile's egress to its port (the agent's ONLY net
            // path). Requires the Seatbelt wrapper (above) to be active — egress is
            // enforced by Seatbelt — so it's nested inside this block. The Phase 3
            // valve can disable it (keeps the fs fence, opens the network).
            var proxyPort: UInt16?
            if !DevNetworkProxy.isFilterDisabled() {
                let proxy = makeNetworkProxy()
                do {
                    let port = try proxy.start()
                    networkProxy = proxy            // retained → torn down by the defer
                    proxyPort = port
                    proxyURL = "http://127.0.0.1:\(port)"
                } catch {
                    // Fail CLOSED: never run a fenced agent with OPEN egress.
                    proxy.stop()
                    Log.dev.error("Dev agent run aborted — network filter proxy failed to start: \(String(describing: error), privacy: .public)")
                    return .failed(.spawnFailed(
                        "network egress filter unavailable — \(String(describing: error)). Refusing to run with open network in this tier."))
                }
            }

            let wrapped = DevSeatbeltSandbox.wrap(
                executableURL: executableURL, arguments: argv,
                projectDirectory: projectURL, proxyPort: proxyPort)
            spawnExecutableURL = wrapped.executableURL
            spawnArguments = wrapped.arguments
        }

        let execution = DevAgentProcessExecution(
            executableURL: spawnExecutableURL,
            // The env-scrub (§5b) + PATH fixup key off the REAL agent binary, not
            // the sandbox-exec wrapper — its basename picks the auth var to keep
            // and its dir is prepended to PATH.
            agentExecutableURL: executableURL,
            arguments: spawnArguments,
            // §8: when network-filtered, the agent's egress is routed through the
            // loopback proxy via these env vars; nil ⇒ network open.
            proxyURL: proxyURL,
            prompt: prompt,
            deliverPromptViaStdin: deliverPromptViaStdin,
            projectURL: projectURL,
            outputFormat: entry.outputFormat,
            tier: tier,
            timeouts: timeouts,
            queue: queue,
            onEvent: onEvent,
            onStall: onStall
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

    /// Testing seam for the `stream-json` event parser (the parser lives on the
    /// file-private execution type).
    nonisolated static func parseStreamJSONLineForTesting(_ line: String) -> DevAgentEvent? {
        DevAgentProcessExecution.parseStreamJSONLine(line)
    }

    /// Testing seam for the `result`-event summary parser (Part A).
    nonisolated static func parseResultSummaryForTesting(_ line: String) -> String? {
        DevAgentProcessExecution.parseResultSummary(line)
    }

    /// Testing seam for the `result`-event error parser (the failure-detail path).
    nonisolated static func parseResultErrorForTesting(_ line: String) -> String? {
        DevAgentProcessExecution.parseResultError(line)
    }

    /// Testing seam for the Cursor `error`-event capture (the failure-detail path).
    nonisolated static func parseStreamErrorEventForTesting(_ line: String) -> String? {
        DevAgentProcessExecution.parseStreamErrorEvent(line)
    }

    /// Testing seam for the question-stripping pass applied to dev summaries.
    nonisolated static func summaryDroppingQuestionsForTesting(_ text: String) -> String? {
        DevAgentProcessExecution.summaryDroppingQuestions(text)
    }

    /// Testing seam for the §5b env-scrub allowlist (`DevAgentProcessExecution` is
    /// private). `baseEnvironment` is injected so a test can plant a `DATABASE_URL`
    /// and assert the fenced tiers strip it while keeping PATH + the agent's auth.
    /// `proxyURL` (§8) exercises the egress-proxy env injection.
    nonisolated static func spawnEnvironmentForTesting(
        for executableURL: URL,
        tier: DevPermissionTier,
        proxyURL: String? = nil,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        DevAgentProcessExecution.spawnEnvironment(
            for: executableURL, tier: tier, proxyURL: proxyURL, baseEnvironment: baseEnvironment)
    }
}

// MARK: - One process execution

/// Encapsulates a single agent process: spawn, stream-parse, the stall watchdog,
/// and a once-only completion. All mutable state is touched on the runner's
/// serial `queue` so the termination handler, the stall timer, and the
/// readability handlers can't race the completion. Explicitly `nonisolated` (see
/// file header): the queue is the synchronization domain.
private final class DevAgentProcessExecution: @unchecked Sendable {

    nonisolated(unsafe) private let process = Process()
    nonisolated(unsafe) private let stdinPipe = Pipe()
    nonisolated(unsafe) private let stdoutPipe = Pipe()
    nonisolated(unsafe) private let stderrPipe = Pipe()

    nonisolated private let arguments: [String]
    nonisolated private let prompt: String
    /// Whether to write `prompt` to the child's stdin (`.stdin` delivery). When
    /// false (`.argument` delivery — the prompt rides in argv), stdin is closed
    /// immediately with no data so a CLI that reads stdin only when piped (Codex)
    /// gets EOF and uses the positional prompt.
    nonisolated private let deliverPromptViaStdin: Bool
    nonisolated private let outputFormat: DevAgentOutputFormat
    nonisolated private let timeouts: DevRunTimeouts
    nonisolated private let queue: DispatchQueue
    nonisolated private let onEvent: @Sendable (DevAgentEvent) -> Void
    /// Stall NOTIFIER — `true` when the agent crosses the silence threshold,
    /// `false` on the next output after a stall. NEVER terminates the process.
    nonisolated private let onStall: @Sendable (Bool) -> Void

    nonisolated(unsafe) private var completion: ((DevRunResult) -> Void)?
    nonisolated(unsafe) private var finished = false
    /// Set when the run was terminated by the user (Cancel / Kill / quit) so
    /// `handleTermination` resolves `.cancelled` rather than an exit code.
    nonisolated(unsafe) private var cancelled = false
    /// Whether the stall threshold has been crossed and not yet cleared by new
    /// output — gates `onStall(true)` to fire exactly once per stall window.
    nonisolated(unsafe) private var stalled = false
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    /// Wall-clock of the last process output — the stall watchdog's reference.
    nonisolated(unsafe) private var lastActivity = Date()
    nonisolated(unsafe) private var stdoutBuffer = Data()
    nonisolated(unsafe) private var stderrTail = ""
    /// The agent's final message text, captured from the terminal stream-json
    /// `result` event. nil until that event is seen (or if it carried no usable
    /// text); rides out on `.succeeded(summary:)` for the result card (Part A).
    nonisolated(unsafe) private var resultSummary: String?
    /// The agent's error text from a stream-json event that marks a failure —
    /// Claude Code's terminal `result` (`is_error`/error subtype, enriched with the
    /// denied command) OR a Cursor top-level `error` event mid-stream (Cursor often
    /// ends WITHOUT a terminal `result`, so its error rides here or on stderr). Last
    /// writer wins. Rides out as the `.nonZeroExit` detail so the pill shows the real
    /// reason instead of the generic fallback. nil until/unless such an event is seen.
    nonisolated(unsafe) private var resultError: String?
    /// The last non-empty line a `.text`-format agent (Codex) printed to stdout.
    /// Codex prints its fatal error as a normal text line; kept here as the FLOOR of
    /// the failure-detail chain (below stream-json error and stderr) so a non-zero
    /// exit can still surface it. nil until the first non-empty `.text` line.
    nonisolated(unsafe) private var lastTextLine: String?

    nonisolated init(
        executableURL: URL,
        agentExecutableURL: URL? = nil,
        arguments: [String],
        proxyURL: String? = nil,
        prompt: String,
        deliverPromptViaStdin: Bool = true,
        projectURL: URL,
        outputFormat: DevAgentOutputFormat,
        tier: DevPermissionTier,
        timeouts: DevRunTimeouts,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (DevAgentEvent) -> Void,
        onStall: @escaping @Sendable (Bool) -> Void
    ) {
        self.arguments = arguments
        self.prompt = prompt
        self.deliverPromptViaStdin = deliverPromptViaStdin
        self.outputFormat = outputFormat
        self.timeouts = timeouts
        self.queue = queue
        self.onEvent = onEvent
        self.onStall = onStall

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = projectURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // §5b env-scrub: the fenced tiers get an allowlist (no DB/cloud creds);
        // `.unrestricted` forwards the full environment. Keyed on the REAL agent
        // binary (`agentExecutableURL`), NOT `executableURL` — under the §5c
        // wrapper the latter is `/usr/bin/sandbox-exec`, whose basename would pick
        // the wrong auth var + PATH dir. Defaults to `executableURL` when unwrapped.
        // §8: `proxyURL` (when set) injects the egress-proxy env vars.
        process.environment = DevAgentProcessExecution.spawnEnvironment(
            for: agentExecutableURL ?? executableURL, tier: tier, proxyURL: proxyURL)
    }

    nonisolated func start(completion: @escaping (DevRunResult) -> Void) {
        queue.async { self.startOnQueue(completion: completion) }
    }

    nonisolated private func startOnQueue(completion: @escaping (DevRunResult) -> Void) {
        self.completion = completion
        lastActivity = Date()

        process.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.handleTermination(status: proc.terminationStatus) }
        }

        // Stream stdout: accumulate, split on newlines, parse → event.
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
        // prompt blocking on a slow reader can't stall the run loop. For
        // `.argument` delivery (Codex) the prompt is already in argv, so write
        // nothing and just close stdin → the child reads EOF immediately.
        let promptData = deliverPromptViaStdin ? Data(prompt.utf8) : Data()
        let handle = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            if !promptData.isEmpty { try? handle.write(contentsOf: promptData) }
            try? handle.close()
        }

        // Emit an initial generic event so the pill shows motion before the
        // first parsed event.
        emit(DevAgentEvent(kind: .working))

        startStallTimer()
    }

    // MARK: Stall watchdog (NOTIFIES — never terminates)

    nonisolated private func startStallTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Tick at 0.5s so a short test stall threshold is observed promptly.
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkStall() }
        timer = t
        t.resume()
    }

    /// The watchdog: after `timeouts.stall` seconds of silence, fire `onStall(true)`
    /// ONCE. This is a NOTIFICATION — the process is never touched. `onStall(false)`
    /// is fired by `noteActivity()` on the next output. The `false → true` is gated
    /// by `stalled`; the `true → false` clears it (see `noteActivity`).
    nonisolated private func checkStall() {
        guard !finished, !cancelled, !stalled else { return }
        if Date().timeIntervalSince(lastActivity) >= timeouts.stall {
            stalled = true
            Log.dev.notice("Dev agent stalled — notifying (process left running)")
            emitStall(true)
        }
    }

    /// Record process output: reset the silence clock and, if we'd flagged a stall,
    /// clear it and tell the UI the agent resumed. Called for ANY output (stdout
    /// or stderr), including frames we don't render — they're signs of life.
    nonisolated private func noteActivity() {
        lastActivity = Date()
        guard stalled else { return }
        stalled = false
        emitStall(false)
    }

    /// User-initiated cancel — the SOLE termination path (the stall watchdog never
    /// calls this). Flagged `cancelled` so termination resolves `.cancelled`. Runs
    /// on the serial `queue` (the runner forwards it there). A no-op once finished
    /// or already tearing down — so a cancel that races a normal exit is harmless.
    nonisolated func cancel() {
        guard !finished, !cancelled else { return }
        cancelled = true
        Log.dev.notice("Dev agent cancelled — terminating")
        terminateWithGrace()
    }

    /// SIGTERM now, SIGKILL after the grace if it hasn't exited. The cancel path
    /// only (no timeout path exists).
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
        // ANY output resets the stall clock (and clears a pending stall) — even
        // frames we don't render below. Sign of life, not transparency.
        if !data.isEmpty { noteActivity() }
        stdoutBuffer.append(data)
        // Process complete lines; keep the trailing partial in the buffer.
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            processStreamLine(line)
        }
    }

    /// Parse one output line into a feed event and emit it. For `stream-json`,
    /// each meaningful event maps to a `DevAgentEvent` (a structural/noise frame
    /// parses to nil and is skipped — DISPLAY only, the stall clock already reset
    /// in `ingestStdout`). When it's the terminal `result` event, also capture the
    /// agent's final message text for the success summary (Part A) AND its error
    /// text for the failure detail (the stream-json agents report fatal errors in
    /// the `result` event, not on stderr). For `.text`
    /// (Codex) every non-empty line becomes a coarse `.message` event — still live,
    /// still resets the clock.
    nonisolated private func processStreamLine(_ line: String) {
        switch outputFormat {
        case .streamJSON:
            // Cursor can emit a top-level `error` event mid-stream and then end
            // WITHOUT a terminal `result` — capture its text (NOT rendered; it
            // parses to nil below) so the failure still has detail even if stderr
            // was empty. Last one wins. Checked before the render guard since the
            // event has no feed representation.
            if let errText = DevAgentProcessExecution.parseStreamErrorEvent(line) {
                resultError = errText
            }
            guard let event = DevAgentProcessExecution.parseStreamJSONLine(line) else { return }
            // `.done` is produced ONLY by the `result` event, so parse its summary
            // here rather than re-inspecting every line. (Pattern-match rather than
            // `==` so the comparison stays nonisolated under the module's default
            // MainActor isolation.)
            if case .done = event.kind {
                if let summary = DevAgentProcessExecution.parseResultSummary(line) {
                    resultSummary = summary
                }
                if let errText = DevAgentProcessExecution.parseResultError(line) {
                    resultError = errText
                }
            }
            emit(event)
        case .text:
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lastTextLine = trimmed          // remember for the failure detail (Codex)
            emit(DevAgentEvent(kind: .message, detail: trimmed))
        }
    }

    nonisolated private func ingestStderr(_ data: Data) {
        guard !finished else { return }
        noteActivity()
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
        // FINAL DRAIN (fast-exit race). The process `terminationHandler` and the
        // stdout `readabilityHandler` both hop onto this serial queue with NO
        // ordering guarantee, so a quick agent that prints its terminal `result`
        // line and exits can land here with that line still unread in the pipe —
        // the stream-json agents report a fatal error in `result` on STDOUT, not
        // stderr, so losing it drops the whole failure detail. Stop the live
        // handlers and synchronously read whatever remains now. The child has
        // already exited (its write ends are closed), so the read hits EOF
        // promptly — no hang. Best-effort: a read error degrades to the prior
        // behavior, never crashes.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil, !out.isEmpty {
            ingestStdout(out)
        }
        if let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil, !err.isEmpty {
            ingestStderr(err)
        }
        // Flush any buffered final line (the terminal `result` event commonly
        // arrives without a trailing newline).
        if !stdoutBuffer.isEmpty, let line = String(data: stdoutBuffer, encoding: .utf8) {
            processStreamLine(line)
        }
        if status == 0 {
            finish(.succeeded(summary: resultSummary))
        } else {
            // Best-available failure detail, most-specific first (handoff §D) — each
            // CLI reports failures differently:
            //   resultError  — stream-json error (Claude `result` / Cursor `error` event)
            //   stderrTail   — Cursor & Codex fatal errors (Claude's rare case)
            //   lastTextLine — Codex error printed to stdout (the floor)
            // stderr beats lastTextLine: a non-zero exit with real stderr is a truer
            // error than the last chatty stdout line. nil → userMessage floors to the
            // generic line. The associated value stays named `stderrTail` (now "best
            // available detail"); `DevDispatchFailure.userMessage` shows whatever
            // non-empty string it gets.
            let detail = resultError
                ?? DevAgentProcessExecution.nonEmpty(stderrTail)
                ?? lastTextLine
            finish(.failed(.nonZeroExit(code: status, stderrTail: detail ?? "")))
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

    nonisolated private func emit(_ event: DevAgentEvent) {
        DispatchQueue.main.async { [onEvent] in onEvent(event) }
    }

    nonisolated private func emitStall(_ isStalled: Bool) {
        DispatchQueue.main.async { [onStall] in onStall(isStalled) }
    }

    // MARK: - stream-json parsing (best-effort, defensive)

    /// Map one `stream-json` line to a feed `DevAgentEvent`, or nil when the line
    /// carries no renderable signal (a structural/noise frame — it still reset the
    /// stall clock upstream; we just don't display it). Tolerant of unknown shapes
    /// (returns nil rather than crashing). This ONE parser serves BOTH Claude Code
    /// and Cursor — each branch is keyed strictly to that agent's distinct
    /// top-level `type` values, so they never cross-react (Cursor never emits
    /// Anthropic-shaped `assistant.tool_use`; the `assistant` text/thinking
    /// fallback is harmless for either). The terminal `result` event is shared.
    ///
    /// Claude Code — verified at M9 against the Claude Code stream-json schema
    /// (code.claude.com docs, June 2026): without `--include-partial-messages`
    /// (we don't pass it), the stream is line-delimited COMPLETE messages —
    /// `system`(init/…), `assistant` (tool_use / text / thinking blocks), `user`
    /// (tool results), and a terminal `result`. The `tool_use` block is the
    /// Anthropic Messages API shape (`{type,id,name,input}`). Tool names span CLI
    /// versions: current builds use `Edit`/`Write`/`Read`/`Glob`/`Grep`/`Bash`/
    /// `Agent` (the subagent tool; `Task` is now the task-list family) and route
    /// directory listing through `Bash` (the old `LS` tool is gone). We keep the
    /// legacy names too so an older installed CLI still maps; unknown → `.working`.
    /// One event per message: a `tool_use` (the concrete action) is preferred over
    /// `text`/`thinking` narration.
    ///
    /// Cursor — verified against cursor-agent 2026.06.16 (2026-06-18): the
    /// top-level vocabulary is `system`/`user`/`assistant`/`thinking`/`tool_call`/
    /// `result`. Tool activity rides in its OWN `tool_call` event
    /// (`{type:"tool_call", subtype:"started"|"completed", tool_call:{ <kind>ToolCall:{args:{…}} }}`),
    /// distinct from Claude's `assistant.tool_use`. We emit on the `started` twin
    /// (the `completed` one would re-emit) and map the tool kind by name. The
    /// standalone `thinking` event is a per-token DELTA — too noisy for the feed,
    /// so it's skipped (nil); the stall clock still reset on the raw bytes.
    nonisolated static func parseStreamJSONLine(_ line: String) -> DevAgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        switch obj["type"] as? String {
        case "result":
            // Terminal event — shared by Claude Code and Cursor.
            return DevAgentEvent(kind: .done)
        case "assistant":
            // Claude Code: message.content blocks. Prefer the concrete action.
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            for item in content where item["type"] as? String == "tool_use" {
                return event(forTool: item["name"] as? String,
                             input: item["input"] as? [String: Any])
            }
            // No tool_use → fall back to narration so the feed shows motion.
            for item in content {
                switch item["type"] as? String {
                case "text":
                    if let text = cleanedText(item["text"]) {
                        return DevAgentEvent(kind: .message, detail: text)
                    }
                case "thinking", "redacted_thinking":
                    return DevAgentEvent(kind: .thinking)
                default:
                    continue
                }
            }
            return nil
        case "tool_call":
            // Cursor: emit once, on the `started` twin. Defensive — a missing
            // payload or an unknown tool kind degrades to `.working`, never crashes.
            guard obj["subtype"] as? String == "started",
                  let call = obj["tool_call"] as? [String: Any] else { return nil }
            return cursorToolCallEvent(call)
        default:
            // Cursor `thinking` deltas and `system`/`user` frames carry no
            // renderable signal (the deltas would be per-token noise).
            return nil
        }
    }

    /// Trim a JSON text value; nil if absent or blank. The feed line truncates;
    /// we keep the full text here (on-screen only — never telemetry).
    nonisolated private static func cleanedText(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Map a Cursor `tool_call` event's payload to a feed event. The payload has
    /// exactly one `<kind>ToolCall` key (alongside bookkeeping like `toolCallId` /
    /// `startedAtMs`) naming the tool; we match it by substring so an unseen kind
    /// still routes sensibly, capturing its specifics from `args`. Verified kinds:
    /// `editToolCall` (args.path) / `readToolCall` (args.path) / `shellToolCall`
    /// (args.command).
    nonisolated private static func cursorToolCallEvent(_ call: [String: Any]) -> DevAgentEvent {
        guard let kind = call.keys.first(where: { $0.hasSuffix("ToolCall") }) else {
            return DevAgentEvent(kind: .working)
        }
        let args = (call[kind] as? [String: Any])?["args"] as? [String: Any]
        let lower = kind.lowercased()
        func fileArg() -> String? { lastComponent(args?["path"] as? String) }
        if lower.contains("edit") || lower.contains("write") || lower.contains("create") {
            return DevAgentEvent(kind: .editing, detail: fileArg())
        }
        if lower.contains("search") || lower.contains("grep") || lower.contains("glob") {
            return DevAgentEvent(kind: .searching,
                                 detail: nonEmpty(args?["pattern"] as? String ?? args?["query"] as? String))
        }
        if lower.contains("list") || lower.contains("ls") {
            return DevAgentEvent(kind: .listing, detail: fileArg())
        }
        if lower.contains("read") {
            return DevAgentEvent(kind: .reading, detail: fileArg())
        }
        if lower.contains("shell") || lower.contains("command") || lower.contains("terminal")
            || lower.contains("run") || lower.contains("exec") || lower.contains("bash") {
            return DevAgentEvent(kind: .running, detail: commandLine(args?["command"] as? String))
        }
        return DevAgentEvent(kind: .working)
    }

    /// Extract the agent's final message text from a terminal `result` event
    /// (Part A). The Claude Code stream-json `result` event carries the assistant's
    /// closing text in its `result` string on a successful run; an error subtype
    /// omits it. Returns the trimmed text, or nil when the line isn't a result
    /// event or carries no usable text. Defensive — unknown shapes degrade to nil.
    nonisolated static func parseResultSummary(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "result",
              let result = obj["result"] as? String
        else { return nil }
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // The dev result card is non-interactive — there's no reply box, so a
        // "Want me to also…?" the agent tacks on is a dead end. Drop questions
        // (trailing OR mid-paragraph) so the summary ends on a statement.
        return summaryDroppingQuestions(text)
    }

    /// Extract the agent's error text from a terminal `result` event that marks a
    /// FAILURE, so a non-zero exit can surface the real reason instead of the
    /// generic fallback. The stream-json agents (Claude Code, cursor-agent) report
    /// their fatal error in the `result` event on stdout, not on stderr — the
    /// success-only `parseResultSummary` skips it because the Claude Code error
    /// subtype omits the top-level `result` string.
    ///
    /// A `result` event counts as an error when `is_error == true` OR `subtype` is
    /// anything other than `"success"` (Claude Code uses `success` /
    /// `error_max_turns` / `error_during_execution`; cursor-agent/Codex vary — we
    /// don't hard-code one). Returns the first non-empty string among `result`,
    /// `error`, `message`, `subtype` (agents disagree on which field carries the
    /// human text; `subtype` is the last resort so we at least surface
    /// `error_max_turns` rather than nothing). Unlike the success path this does NOT
    /// strip questions — errors are shown verbatim. nil for a success result, a
    /// non-result line, or an error with no usable text. Defensive — unknown shapes
    /// degrade to nil, never crash.
    nonisolated static func parseResultError(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "result"
        else { return nil }
        // Only treat it as an error result — a clean `success` is not our concern.
        let isError = (obj["is_error"] as? Bool) == true
        let subtype = obj["subtype"] as? String
        let subtypeIsFailure = subtype != nil && subtype != "success"
        guard isError || subtypeIsFailure else { return nil }
        // First non-empty human text, in order of preference; `subtype` last so we
        // surface a category rather than nothing.
        var base: String?
        for key in ["result", "error", "message", "subtype"] {
            if let s = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                base = s
                break
            }
        }
        // Edits-only is our default posture (Bash disallowed / sandboxed), so the
        // most common Claude Code failure is a denied shell command — `error`
        // ("Permission denied") is true but useless without *which* command. Enrich
        // from `permission_denials` when present.
        let denials = permissionDenialSummary(obj["permission_denials"])
        switch (base, denials) {
        case let (b?, d?):  return "\(b) — \(d)"
        case let (b?, nil): return b
        case let (nil, d?): return d
        case (nil, nil):    return nil
        }
    }

    /// Summarize Claude Code's `permission_denials` array into one line — the denied
    /// tool + its command per denial (`"Bash: git fetch origin main"`), capped at the
    /// first 3 so the pill stays sane. Defensive: a non-array, or a denial missing
    /// `tool_name`, is skipped; nil when nothing usable survives.
    nonisolated private static func permissionDenialSummary(_ value: Any?) -> String? {
        guard let denials = value as? [[String: Any]], !denials.isEmpty else { return nil }
        let parts: [String] = denials.prefix(3).compactMap { denial in
            guard let tool = (denial["tool_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else { return nil }
            if let cmd = ((denial["tool_input"] as? [String: Any])?["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                return "\(tool): \(cmd)"
            }
            return tool
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Capture a Cursor top-level `error` event's text (NOT rendered to the feed).
    /// Cursor can emit `{"type":"error", …}` mid-stream and then end the stream
    /// WITHOUT a terminal `result` event — stashing its message gives the failure a
    /// detail even when stderr was empty. Returns the `message`/`error` string, or
    /// nil for a non-error line. Defensive — unknown shapes degrade to nil.
    nonisolated static func parseStreamErrorEvent(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "error"
        else { return nil }
        for key in ["message", "error"] {
            if let s = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Remove question sentences from an agent's free-text summary so the
    /// (read-only) dev result card never asks the user something it can't accept
    /// an answer to. Operates per markdown line to preserve list/paragraph
    /// structure: within each line, a sentence whose terminating punctuation is a
    /// `?` is dropped — whether it's the last sentence or embedded between
    /// declarative ones ("Did X. Should I also Y? Left it as-is." → "Did X. Left
    /// it as-is."). A `?` mid-token (a URL query, `foo?bar`) isn't a sentence end
    /// and is left alone. Returns the surviving declarative text, or nil when the
    /// summary was nothing but questions (so the diff-stat fallback takes over).
    nonisolated static func summaryDroppingQuestions(_ text: String) -> String? {
        let cleanedLines = text
            .components(separatedBy: "\n")
            .map(lineDroppingQuestions)
        // Rejoin, then collapse the blank-line runs that fully-dropped lines can
        // leave behind, and trim the whole thing.
        var joined = cleanedLines.joined(separator: "\n")
        while joined.contains("\n\n\n") {
            joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        let result = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Drop question sentences from a single line (no embedded newlines). A
    /// sentence ends at a run of `.`/`!`/`?` (plus any trailing closing quotes or
    /// brackets) when followed by whitespace or end-of-line; the run "is a
    /// question" when it contains a `?`. Whitespace is collapsed and the line
    /// trimmed after filtering.
    nonisolated private static func lineDroppingQuestions(_ line: String) -> String {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
        let chars = Array(line)
        let n = chars.count
        let terminators: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}"] // " ' ) ] ” ’
        var kept = ""
        var sentence = ""
        var i = 0
        while i < n {
            let ch = chars[i]
            if terminators.contains(ch) {
                var k = i
                var run = ""
                while k < n, terminators.contains(chars[k]) { run.append(chars[k]); k += 1 }
                while k < n, closers.contains(chars[k]) { run.append(chars[k]); k += 1 }
                sentence += run
                let atEnd = k >= n
                let nextIsSpace = !atEnd && chars[k].isWhitespace
                if atEnd || nextIsSpace {
                    // A real sentence boundary: keep it unless it's a question.
                    if !run.contains("?") { kept += sentence }
                    sentence = ""
                }
                // else: a `.`/`?` mid-token (e.g. "west.css", "a?b") — not a
                // boundary; the run stays in `sentence` and we read on.
                i = k
            } else {
                sentence.append(ch)
                i += 1
            }
        }
        // A trailing fragment with no terminal punctuation is declarative by
        // definition (any `?` end would have been a boundary), so keep it.
        kept += sentence
        let collapsed = kept.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Map one Claude Code `tool_use` block to a feed event WITH its specifics:
    /// the edited file, the read file, the search pattern, the listed directory,
    /// the shell command. Unknown/future tools degrade to `.working`.
    nonisolated private static func event(forTool name: String?, input: [String: Any]?) -> DevAgentEvent {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            // `file_path` for Edit/Write; `notebook_path` for older NotebookEdit.
            // `MultiEdit` is legacy (merged into Edit's `replace_all`) — kept for
            // older CLIs.
            let path = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String)
            return DevAgentEvent(kind: .editing, detail: lastComponent(path))
        case "Read":
            return DevAgentEvent(kind: .reading, detail: lastComponent(input?["file_path"] as? String))
        case "Glob", "Grep":
            return DevAgentEvent(kind: .searching, detail: nonEmpty(input?["pattern"] as? String))
        case "LS":
            // Legacy (directory listing now goes through Bash); kept for older CLIs.
            return DevAgentEvent(kind: .listing, detail: lastComponent(input?["path"] as? String))
        case "Bash":
            return DevAgentEvent(kind: .running, detail: commandLine(input?["command"] as? String))
        case "Agent", "Task":
            // `Agent` is the current subagent tool; `Task` was its old name. No
            // single file/command to name — show generic "running" motion.
            return DevAgentEvent(kind: .running)
        default:
            return DevAgentEvent(kind: .working)
        }
    }

    // MARK: Detail helpers (on-screen specifics — never telemetry)

    /// Last path component of a non-empty path, else nil.
    nonisolated private static func lastComponent(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Trimmed string, or nil if absent/blank.
    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// A command's first line, capped, for the feed (a multi-line heredoc renders
    /// as one tidy line). Full command stays out of telemetry regardless.
    nonisolated private static func commandLine(_ command: String?) -> String? {
        guard let first = command?.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    // MARK: - Spawn environment

    /// The spawn environment for the agent process. Always guarantees a usable
    /// PATH: GUI apps inherit a stripped PATH, and the CLIs (Node etc.) shell out
    /// to `node` and friends. Prefer the LOGIN-SHELL PATH captured during detection
    /// (`DevAgentBinaryResolver`) — it contains the version-manager `node` dir
    /// (nvm/asdf) that a hand-built list would miss — falling back to a static list
    /// only when detection hasn't warmed it. The binary's own dir is always
    /// prepended. The CLIs read their own auth config (~/.claude, …), readable
    /// since we're non-sandboxed.
    ///
    /// §5b ENV-SCRUB: for the FENCED tiers (`.askPermission` / `.autoApprove`) the
    /// result is an ALLOWLIST — only PATH, a handful of locale/shell vars, and the
    /// ACTIVE agent's own auth var (if present) survive; everything else (DB URLs,
    /// cloud creds, unrelated `*_SECRET`/`*_TOKEN`/`*_API_KEY`) is stripped, so a
    /// command has no credentials to mutate an external system. For `.unrestricted`
    /// the FULL environment is forwarded (today's behavior), PATH fixed up.
    /// `baseEnvironment` is injectable for tests; production passes the process env.
    ///
    /// §8 PROXY ROUTING: for a network-filtered fenced run, `proxyURL`
    /// (`http://127.0.0.1:<port>`) is injected as the standard proxy vars so the
    /// agent + npm route ALL egress through the Dev network filter proxy (the
    /// Seatbelt egress rule denies every other destination). nil ⇒ no proxy vars
    /// (network open). `.unrestricted` never receives a proxy.
    nonisolated static func spawnEnvironment(
        for executableURL: URL,
        tier: DevPermissionTier,
        proxyURL: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
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
        let inherited = baseEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        // De-dupe while preserving order (binDir first so the agent's own
        // toolchain dir wins, then the login PATH, then anything inherited).
        var seen = Set<String>()
        let path = ([binDir] + base + inherited)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")

        // Unrestricted: forward the FULL environment (today's behavior), PATH fixed up.
        guard tier.isFenced else {
            var env = baseEnvironment
            env["PATH"] = path
            return env
        }

        // Fenced: ALLOWLIST. Keep PATH + what node/npm + a shell need, plus the
        // active agent's own auth var only. Everything else is dropped.
        var env: [String: String] = ["PATH": path]
        let keepExact: Set<String> = ["HOME", "USER", "SHELL", "LANG", "TMPDIR", "TERM"]
        let authKeys = agentAuthEnvKeys(for: executableURL.lastPathComponent)
        for (key, value) in baseEnvironment {
            if keepExact.contains(key) || key.hasPrefix("LC_") || authKeys.contains(key) {
                env[key] = value
            }
        }

        // §8: route ALL egress through the Dev network filter proxy. The standard
        // proxy vars (upper + lower case) cover curl/git/the agent's HTTP client;
        // `npm_config_*` covers npm explicitly. `NO_PROXY` is set EMPTY so nothing
        // bypasses the filter (a bypassed host would be denied by the Seatbelt
        // egress rule anyway, but empty NO_PROXY keeps intent unambiguous).
        if let proxyURL, !proxyURL.isEmpty {
            for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
                        "ALL_PROXY", "all_proxy",
                        "npm_config_proxy", "npm_config_https_proxy"] {
                env[key] = proxyURL
            }
            env["NO_PROXY"] = ""
            env["no_proxy"] = ""
        }
        return env
    }

    /// The auth env var names the ACTIVE agent reads, derived from the executable's
    /// basename — kept under the §5b allowlist only if present (most agents read
    /// auth from their own config dir: ~/.claude, ~/.codex, ~/.cursor, so these are
    /// usually absent). An agent's own key is kept; every OTHER agent's key (and any
    /// unrelated `*_API_KEY`/`*_TOKEN`) is stripped.
    nonisolated private static func agentAuthEnvKeys(for executableName: String) -> Set<String> {
        switch executableName {
        case "claude":       return ["ANTHROPIC_API_KEY"]
        case "codex":        return ["OPENAI_API_KEY", "CODEX_API_KEY"]
        case "cursor-agent": return ["CURSOR_API_KEY"]
        default:             return []
        }
    }
}
