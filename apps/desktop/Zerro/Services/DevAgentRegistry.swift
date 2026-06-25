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
//  Three CLIs now ship — Claude Code (Phase 1), Codex, and Cursor (Phase 3,
//  design §2) — each pinned against its live `--help`. The custom-command
//  escape hatch + the port→folder zero-setup are the remaining Phase 3 items.
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

/// The single "how much do I trust the agent" dial for a Dev Mode dispatch
/// (permission-tiers spec §2–§3). Collapses two older axes into one control:
/// the Zerro-side **review gate** (was `DevPermissionMode.askPermission` vs
/// `.autoApprove`) and the **containment fences** of §5 (no MCP + scrubbed env).
/// Persisted by `PreferencesStore.devPermissionTier`; `allCases` order is the
/// dev-settings picker's row order. The `DevAgentPermission` posture is derived
/// from this — every tier runs commands enabled.
enum DevPermissionTier: String, CaseIterable, Sendable {
    /// Review gate ON (Zerro pauses to show the plan + approve before dispatch),
    /// fenced (no MCP + env allowlist).
    case askPermission
    /// Review gate OFF (runs live), fenced.
    case autoApprove
    /// Review gate OFF, UNfenced — MCP stays enabled and the full environment is
    /// forwarded. Gated behind a record-time warning (a later phase).
    case unrestricted

    /// The §5 fences (no-MCP flags + the env allowlist) apply to every tier
    /// EXCEPT `.unrestricted`, which removes them.
    var isFenced: Bool { self != .unrestricted }

    /// Only `.askPermission` runs the Zerro-side review gate (pause to show the
    /// plan + approve before the agent is dispatched). Read at the dispatch gate.
    var reviewsBeforeDispatch: Bool { self == .askPermission }

    /// The derived shell posture: every tier runs commands enabled (the headline
    /// "npm install" path keeps working); containment comes from the fences.
    var agentPermission: DevAgentPermission { .allowCommands }
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
    /// Flags appended for the FENCED tiers (`.askPermission` / `.autoApprove`)
    /// that disable MCP servers (spec §5a) — e.g. Claude's `--strict-mcp-config`,
    /// Codex's `--ignore-user-config`. Empty when the no-MCP fence needs no
    /// positive flag (Cursor: the fence is the ABSENCE of `--approve-mcps` plus a
    /// config without `mcp.json`). NOT appended for `.unrestricted` (MCP stays on).
    let mcpDisableArgs: [String]

    /// Whether the executable resolved on PATH this launch.
    let installed: Bool
    /// Absolute path to the executable (GUI PATH is stripped, so the runner
    /// spawns this directly), or nil when not installed.
    let absolutePath: URL?

    /// The flag name used to select a model (Phase 2), or nil when the agent
    /// has no model picker. Claude Code / Codex / Cursor all use `--model`; the
    /// runner appends `[modelFlagName, modelID]` ONLY when a model is selected
    /// AND this is non-nil (no flag ⇒ the agent's own default).
    let modelFlagName: String?

    /// Explicit memberwise init with `modelFlagName` / `mcpDisableArgs` defaulted
    /// so the pre-existing construction sites (tests) compile unchanged.
    init(
        id: String,
        displayName: String,
        executableName: String,
        promptDelivery: DevAgentPromptDelivery,
        outputFormat: DevAgentOutputFormat,
        baseArgs: [String],
        editsOnlyArgs: [String],
        allowCommandsArgs: [String],
        installed: Bool,
        absolutePath: URL?,
        modelFlagName: String? = nil,
        mcpDisableArgs: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.promptDelivery = promptDelivery
        self.outputFormat = outputFormat
        self.baseArgs = baseArgs
        self.editsOnlyArgs = editsOnlyArgs
        self.allowCommandsArgs = allowCommandsArgs
        self.mcpDisableArgs = mcpDisableArgs
        self.installed = installed
        self.absolutePath = absolutePath
        self.modelFlagName = modelFlagName
    }

    /// Full argv (excluding the prompt, which is delivered per `promptDelivery`)
    /// for a run at `permission`, with the optional `--model <id>` appended last.
    /// The model flag is added ONLY when `model` is non-nil AND the agent
    /// declares a `modelFlagName` — otherwise the agent runs on its own default.
    func arguments(permission: DevAgentPermission, model: String? = nil) -> [String] {
        var args: [String]
        switch permission {
        case .editsOnly:     args = baseArgs + editsOnlyArgs
        case .allowCommands: args = baseArgs + allowCommandsArgs
        }
        if let model, !model.isEmpty, let flag = modelFlagName {
            args += [flag, model]
        }
        return args
    }

    /// Full argv (excluding the prompt) for a run at `tier` (spec §6). Every tier
    /// runs with commands ENABLED (`allowCommandsArgs` — the headline "npm install"
    /// path); the FENCED tiers (`.askPermission` / `.autoApprove`) additionally
    /// append `mcpDisableArgs` (the §5a no-MCP flags), while `.unrestricted`
    /// leaves MCP enabled. `--model <id>` is appended last, on the same condition
    /// as `arguments(permission:model:)`. Ask Permission and Auto-Approve produce
    /// IDENTICAL argv — they differ only by the Zerro-side review gate.
    func arguments(tier: DevPermissionTier, model: String? = nil) -> [String] {
        var args = baseArgs + allowCommandsArgs
        if tier.isFenced {
            args += mcpDisableArgs
        }
        if let model, !model.isEmpty, let flag = modelFlagName {
            args += [flag, model]
        }
        return args
    }
}

// MARK: - DevAgentRegistry

enum DevAgentRegistry {

    /// Wire id of the original agent (Phase 1).
    static let claudeCodeID = "claude-code"
    /// Wire id of the Codex agent (Phase 2 — `codex exec`).
    static let codexID = "codex"
    /// Wire id of the Cursor agent (Phase 3 — `cursor-agent -p`). MUST be the
    /// literal "cursor" so `AgentModelMapping.source(forAgent:)` routes it to
    /// `.cursorCLI` (its model list comes from `cursor-agent models`, not a
    /// server manifest).
    static let cursorID = "cursor"

    /// The agent pre-selected when none is remembered (the recommended default).
    static let recommendedID = claudeCodeID

    /// All known agents with live detection applied. Detection is cached in
    /// `DevAgentBinaryResolver`, so repeated calls are cheap. `nonisolated`
    /// (the module defaults to MainActor isolation) so the BLOCKING resolve it
    /// triggers can run off the main thread — see `DevAgentDetection`.
    nonisolated static func all() -> [DevAgentEntry] {
        [makeClaudeCode(), makeCodex(), makeCursor()]
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
            // Every tier runs commands enabled — `bypassPermissions` won't hang
            // headless and lets the shell run; the Zerro fences (no-MCP + env
            // scrub + future wrapper) provide the containment (spec §6).
            allowCommandsArgs: ["--permission-mode", "bypassPermissions"],
            installed: path != nil,
            absolutePath: path,
            // Claude Code's `--model` accepts an alias or a full model id (e.g.
            // `claude-opus-4-8`), exactly the strings the anthropic manifest
            // serves. Verified against `claude --help` (June 2026).
            modelFlagName: "--model",
            // No-MCP fence (§5a) — made CERTAIN. `--strict-mcp-config` says "use
            // ONLY servers from --mcp-config", so we ALSO pass an explicit EMPTY
            // config: the fenced tiers then load zero servers from EVERY source —
            // user `~/.claude.json`, project `.mcp.json`, and the claude.ai
            // connectors (Supabase/Notion/Gmail/…). `--mcp-config` accepts an inline
            // JSON STRING (not just a file), verified against `claude --help`
            // (2.1.179), so nothing needs shipping. Live-verified: a fenced run's
            // init event reports `mcp_servers: []` with no `mcp__*` tools, whereas
            // the default run lists the user's connectors. Dropped for
            // `.unrestricted` (MCP stays enabled).
            mcpDisableArgs: ["--mcp-config", "{\"mcpServers\":{}}", "--strict-mcp-config"]
        )
    }

    // MARK: - Codex

    /// Codex CLI agent (`codex exec`). Verified against `codex exec --help`
    /// (codex-cli 0.140.0, 2026-06-18):
    ///   • `exec` is the non-interactive subcommand; the prompt is a POSITIONAL
    ///     argument (stdin is only appended when piped — so we pass it as an arg
    ///     and close stdin), hence `.argument` delivery.
    ///   • Sandbox: `-s/--sandbox` with `workspace-write` (files yes, the
    ///     edits-only posture) vs `danger-full-access` (allow-commands). NOT the
    ///     deprecated `--full-auto`. `exec` is already non-interactive
    ///     (approval never), so no approval flag is needed.
    ///   • `--skip-git-repo-check` is harmless inside a repo (the dispatch always
    ///     runs in one — the checkpoint requires git) and avoids a repo-detection
    ///     mismatch; `--color never` keeps the `.text` tail clean.
    ///   • Output is parsed as `.text` (spinner + tail) — Codex's `--json` event
    ///     schema differs from Claude's stream-json, so we don't pretend to parse
    ///     it; the result card falls back to the diff-generated change line.
    ///   • `-m/--model` selects the model; the ids come from Codex's OWN
    ///     per-account list (see `DevAgentDetection.codexModels`), NOT the OpenAI
    ///     API manifest (a ChatGPT-account Codex rejects the API codex ids).
    nonisolated private static func makeCodex() -> DevAgentEntry {
        let path = DevAgentBinaryResolver.resolve("codex")
        return DevAgentEntry(
            id: codexID,
            displayName: "Codex",
            executableName: "codex",
            promptDelivery: .argument,
            outputFormat: .text,
            baseArgs: ["exec", "--skip-git-repo-check", "--color", "never"],
            editsOnlyArgs: ["--sandbox", "workspace-write"],
            // Every tier runs commands enabled. `danger-full-access` (vs
            // `workspace-write`) keeps network on so `npm install` can fetch under
            // the Zerro fences/wrapper (spec §6 / §10 — workspace-write forces
            // network off on macOS).
            allowCommandsArgs: ["--sandbox", "danger-full-access"],
            installed: path != nil,
            absolutePath: path,
            modelFlagName: "--model",
            // No-MCP fence (§5a): `--ignore-user-config` ignores `~/.codex/config.toml`,
            // so no user MCP servers load. Dropped for `.unrestricted`.
            mcpDisableArgs: ["--ignore-user-config"]
        )
    }

    // MARK: - Cursor

    /// Cursor CLI agent (`cursor-agent -p`). Verified against the LIVE CLI —
    /// `cursor-agent --help` + six headless smoke dispatches in a throwaway repo
    /// (cursor-agent 2026.06.16-20-30-07-a07d3ac, 2026-06-18). The design doc's
    /// guessed `cursor-agent -p --force --output-format json` was stale; the real
    /// contract:
    ///   • There is NO `exec`-style subcommand — the headless form is the
    ///     TOP-LEVEL command with `-p`/`--print` (`agent` is just an alias).
    ///   • The prompt is a trailing POSITIONAL argument (`[prompt...]`), so we use
    ///     `.argument` delivery (the runner appends it last and closes stdin) —
    ///     same shape as Codex. Verified to run headlessly with stdin closed.
    ///   • `--output-format stream-json` emits a clean, line-delimited event
    ///     stream (`system`/`assistant`/`tool_call`/`thinking`/`result`) whose
    ///     `result` event carries the summary string — so we parse it as
    ///     `.streamJSON` for live substatus + the result card (see
    ///     `DevAgentProcessExecution.parseStreamJSONLine` / `parseResultSummary`,
    ///     extended to Cursor's `tool_call` shape). NOT `--output-format json`
    ///     (a single blob) or `text`.
    ///   • `--trust` trusts the workspace without prompting — REQUIRED for
    ///     unattended runs (a `--print`-only flag, by design), else the CLI can
    ///     stall on a trust prompt. We always dispatch INTO the user's chosen
    ///     project, so trusting it is intended.
    ///   • Permission posture (verified, and OPPOSITE of the design doc's sandbox
    ///     assumption): the plain `-p` default is edits-only — file edits apply
    ///     but shell commands are REJECTED ("all shell invocations returned
    ///     'Rejected'"). `--force` (alias `--yolo`, "Run Everything") is the
    ///     allow-commands opt-in — shell runs unsandboxed (so it can add deps /
    ///     run builds). Hence `editsOnlyArgs == []` (the default already denies
    ///     shell) and `allowCommandsArgs == ["--force"]`.
    ///       NUANCE: unlike Claude's `--disallowedTools Bash` / Codex's
    ///       `--sandbox workspace-write`, cursor-agent has NO explicit deny-shell
    ///       flag — the edits-only behavior is the default `-p` posture, which a
    ///       user who has globally enabled Cursor auto-run COULD weaken. We do not
    ///       use `--sandbox enabled` (it AUTO-RUNS sandboxed shell — not
    ///       edits-only) nor `--sandbox disabled` (it rejects shell but degrades
    ///       the primary edit tool into a Write fallback). Clean/reliable edits
    ///       matter more than closing a narrow, config-dependent shell hole — the
    ///       git checkpoint + revert is the real containment, and Dev Mode is
    ///       watched, not autonomous.
    ///   • `--model <id>` selects the model; the ids come from `cursor-agent
    ///     models` (per-account; see `DevAgentDetection.cursorModels`), e.g.
    ///     `auto` / `claude-opus-4-8-high` / `gpt-5.5-medium`, NOT a server
    ///     manifest.
    nonisolated private static func makeCursor() -> DevAgentEntry {
        let path = DevAgentBinaryResolver.resolve("cursor-agent")
        return DevAgentEntry(
            id: cursorID,
            displayName: "Cursor",
            executableName: "cursor-agent",
            promptDelivery: .argument,
            outputFormat: .streamJSON,
            // -p (headless/print) + clean line-delimited events + trust the
            // workspace so an unattended run never stalls on a trust prompt.
            baseArgs: ["-p", "--output-format", "stream-json", "--trust"],
            // Edits-only IS the default `-p` posture (shell rejected) — there's no
            // deny-shell flag to add, so this is empty. See the NUANCE above.
            editsOnlyArgs: [],
            // Every tier runs commands enabled: --force (== --yolo) runs the shell
            // unsandboxed (plain `-p` rejects shell, which would block npm install).
            // Containment comes from the Zerro fences (spec §6).
            allowCommandsArgs: ["--force"],
            installed: path != nil,
            absolutePath: path,
            modelFlagName: "--model",
            // No-MCP fence (§5a) — cursor-agent (2026.06.24) offers NO clean per-run
            // lever, so the fence is best-effort. What was verified against the live
            // CLI:
            //   • We never pass `--approve-mcps`. An unapproved server (project or
            //     `~/.cursor/mcp.json`) reports "not loaded (needs approval)" and is
            //     NOT loaded in headless `-p` — so withholding the flag genuinely
            //     blocks every UN-approved server (not a no-op).
            //   • There is NO `--mcp-config` / `--config-dir` flag, and an isolated
            //     `HOME` (the only way to escape `~/.cursor/mcp.json` + the approved
            //     list) BREAKS auth — the login token is keyed to the real HOME
            //     (verified: isolated HOME ⇒ "Not logged in"). `mcp disable` and a
            //     `permissions.deny:["Mcp(*:*)"]` rule only exist by MUTATING the
            //     user's global `~/.cursor/cli-config.json`, which we must not do.
            //   • RESIDUAL: a server the user PRE-approved would still auto-load.
            //     That residual is covered by the §5b env-scrub (the MCP subprocess
            //     inherits the scrubbed env — no creds) and, later, the §5c Seatbelt
            //     wrapper (blocks its spawns/egress). A future cursor-agent `--no-mcp`
            //     would let us close it directly.
            // Hence nothing to append: fenced vs `.unrestricted` argv match for
            // Cursor; only the env-scrub (§5b) differs.
            mcpDisableArgs: []
        )
    }
}
