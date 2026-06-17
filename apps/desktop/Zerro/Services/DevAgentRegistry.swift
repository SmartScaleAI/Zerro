//
//  DevAgentRegistry.swift
//  Zerro
//
//  Dev Mode (Phase 1) — the registry of coding agents a recording can be
//  dispatched to. Modeled on `ModelRegistry`: pure declarative data describing
//  each agent's CLI contract (executable, how the prompt is delivered, the
//  non-interactive flags, how its output is parsed), so a `DevAgentRunner`
//  (Milestone 4) can spawn any of them from data alone — and a future
//  first-party API agent is a clean substitution.
//
//  Phase 1 ships exactly ONE agent: Claude Code. Codex / Cursor / a custom
//  command escape hatch + the auto-detect dropdown are Phase 3 (design §2).
//
//  CLI contract (verified against current Claude Code docs, design §11):
//    claude -p --output-format stream-json --verbose
//           --permission-mode acceptEdits --disallowedTools Bash   (edits-only)
//           --permission-mode bypassPermissions                    (allow commands)
//  The prompt is delivered on STDIN (avoids shell-quoting a long prompt).
//  `installed` / `absolutePath` come from a login-shell PATH probe
//  (`DevAgentBinaryResolver`) since GUI apps inherit a stripped PATH.
//

import Foundation

// MARK: - CLI contract enums

/// How a recording's prompt reaches the agent process.
enum DevAgentPromptDelivery: Equatable, Sendable {
    /// Written to the process's stdin (Claude Code). Avoids shell-quoting a
    /// long, multi-line prompt as an argument.
    case stdin
    /// Passed as a trailing positional argument.
    case argument
    /// Passed via a `--message`-style flag.
    case messageFlag
}

/// How the agent's stdout is interpreted by the runner.
enum DevAgentOutputFormat: Equatable, Sendable {
    /// Line-delimited JSON events (`--output-format stream-json`) → parsed to
    /// pill substatus.
    case streamJSON
    /// Opaque text → spinner + tail of the last line.
    case text
}

/// The unattended permission posture for a run. Edits-only is the Phase 1
/// default (design §11 ★): the agent changes files but cannot run shell
/// commands without supervision. "Allow commands" is an opt-in for users who
/// want the agent to add deps / run builds.
enum DevAgentPermission: Equatable, Sendable {
    case editsOnly
    case allowCommands

    static let `default`: DevAgentPermission = .editsOnly
}

// MARK: - DevAgentEntry

/// One dispatchable agent. Declarative — no I/O beyond the `installed` /
/// `absolutePath` fields that the registry populates from detection.
struct DevAgentEntry: Identifiable, Equatable, Sendable {
    /// Stable wire id persisted in `PreferencesStore.selectedAgentID`.
    let id: String
    /// User-facing chip label.
    let displayName: String
    /// Bare executable name probed on PATH (e.g. "claude").
    let executableName: String
    let promptDelivery: DevAgentPromptDelivery
    let outputFormat: DevAgentOutputFormat

    /// Flags that are always passed, before the per-run permission flags.
    let baseArgs: [String]
    /// Flags appended for `.editsOnly` (files yes, shell no).
    let editsOnlyArgs: [String]
    /// Flags appended for `.allowCommands` (full access).
    let allowCommandsArgs: [String]

    /// Whether the executable resolved on PATH this launch.
    let installed: Bool
    /// Absolute path to the executable (GUI PATH is stripped, so the runner
    /// spawns this directly), or nil when not installed.
    let absolutePath: URL?

    /// Full argv (excluding the prompt, which is delivered per
    /// `promptDelivery`) for a run at `permission`.
    func arguments(permission: DevAgentPermission) -> [String] {
        switch permission {
        case .editsOnly:     return baseArgs + editsOnlyArgs
        case .allowCommands: return baseArgs + allowCommandsArgs
        }
    }
}

// MARK: - DevAgentRegistry

enum DevAgentRegistry {

    /// Wire id of the Phase 1 agent.
    static let claudeCodeID = "claude-code"

    /// The agent pre-selected when none is remembered. Phase 3 turns this into
    /// "recommended installed agent"; Phase 1 has exactly one.
    static let recommendedID = claudeCodeID

    /// All known agents with live detection applied. Detection is cached in
    /// `DevAgentBinaryResolver`, so repeated calls are cheap. `nonisolated`
    /// (the module defaults to MainActor isolation) so the BLOCKING resolve it
    /// triggers can run off the main thread — see `DevAgentDetection`.
    nonisolated static func all() -> [DevAgentEntry] {
        [makeClaudeCode()]
    }

    /// Registry lookup by wire id (with detection applied). BLOCKING on a cold
    /// cache — call off-main (`DevAgentDetection`), not on the overlay path.
    nonisolated static func entry(id: String) -> DevAgentEntry? {
        all().first { $0.id == id }
    }

    // MARK: - Claude Code

    nonisolated private static func makeClaudeCode() -> DevAgentEntry {
        let path = DevAgentBinaryResolver.resolve("claude")
        return DevAgentEntry(
            id: claudeCodeID,
            displayName: "Claude Code",
            executableName: "claude",
            promptDelivery: .stdin,
            outputFormat: .streamJSON,
            // -p (headless), stream-json + --verbose so we get per-event lines
            // to drive the pill substatus.
            baseArgs: ["-p", "--output-format", "stream-json", "--verbose"],
            // Edits-only: auto-accept file edits, but explicitly deny the shell
            // so the agent can't run commands unattended (design §11). The git
            // checkpoint is the containment for the edits it IS allowed to make.
            editsOnlyArgs: ["--permission-mode", "acceptEdits", "--disallowedTools", "Bash"],
            // Allow-commands opt-in: full unattended access (adds deps, runs
            // builds, can self-verify). Heavier trust; off by default.
            allowCommandsArgs: ["--permission-mode", "bypassPermissions"],
            installed: path != nil,
            absolutePath: path
        )
    }
}
