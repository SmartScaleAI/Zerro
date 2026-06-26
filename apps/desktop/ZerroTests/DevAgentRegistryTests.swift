//
//  DevAgentRegistryTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 2) — the agent registry's CLI contract. The
//  `installed`/`absolutePath` fields depend on the host's PATH and aren't
//  asserted here; these pin the DECLARATIVE data the runner (Milestone 4)
//  spawns from, so a flag drift is caught by a test rather than at dispatch.
//

import XCTest
@testable import Zerro

final class DevAgentRegistryTests: XCTestCase {

    func testRegistryShipsClaudeCodeCodexCursor() {
        let all = DevAgentRegistry.all()
        XCTAssertEqual(all.map(\.id),
                       [DevAgentRegistry.claudeCodeID, DevAgentRegistry.codexID, DevAgentRegistry.cursorID])
        // Claude Code stays the recommended default (the pre-filled pick).
        XCTAssertEqual(DevAgentRegistry.recommendedID, DevAgentRegistry.claudeCodeID)
        // The Cursor wire id MUST be the literal "cursor" so the model-source
        // mapping routes it to the Cursor CLI (AgentModelMapping).
        XCTAssertEqual(DevAgentRegistry.cursorID, "cursor")
        XCTAssertNotNil(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
    }

    func testCredentialStorePerAgentDrivesTheSeatbeltCarveOut() throws {
        // The §5c wrapper compatibility pivot (the 401 fix). Claude Code reads its
        // token from the macOS Keychain → securityd denies a sandbox-exec'd
        // GUI-child → it must run UNWRAPPED. Codex (~/.codex/auth.json) and Cursor
        // (~/.cursor) read file tokens the sandbox permits → they KEEP the wrapper.
        let claude = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        let codex = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        let cursor = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
        XCTAssertEqual(claude.credentialStore, .keychain,
                       "Claude Code authenticates via the Keychain — not wrappable under sandbox-exec")
        XCTAssertEqual(codex.credentialStore, .file)
        XCTAssertEqual(cursor.credentialStore, .file)
    }

    func testConfinementPerAgentDrivesTheSpawnFence() throws {
        // The §5c confinement strategy, modeled EXPLICITLY (the spawn site branches on
        // this, not credentialStore). Claude Code → `.claudeNative` (its own built-in
        // sandbox + permission rules via a transient --settings file, so the main
        // process stays unsandboxed and Keychain auth survives). Codex / Cursor →
        // `.zerroSeatbelt` (Zerro's sandbox-exec wrapper + the §8 egress proxy).
        let claude = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        let codex = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        let cursor = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
        XCTAssertEqual(claude.confinement, .claudeNative,
                       "Claude Code uses its own native sandbox, NOT sandbox-exec")
        XCTAssertEqual(codex.confinement, .zerroSeatbelt)
        XCTAssertEqual(cursor.confinement, .zerroSeatbelt)
    }

    func testCodexFencedKeepsIgnoreUserConfig() throws {
        // §5a no-MCP for Codex stays `--ignore-user-config` on the fenced tiers,
        // dropped for Unrestricted. This pins ONLY the argv flag.
        //
        // (EMPIRICAL, NOT asserted here — verified manually against codex-cli 0.140.0,
        // June 2026: the flag ignores config.toml's MCP servers but does NOT drop auth
        // — `auth.json` still loads from CODEX_HOME, so a fenced run does NOT 401. The
        // task's hypothesis that it drops auth was disproven; the targeted alternative
        // `-c mcp_servers={}` was rejected after `codex mcp list` showed it left the
        // config.toml servers loaded. These are CLI behaviors a unit test can't reach.)
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        XCTAssertTrue(entry.arguments(tier: .askPermission).contains("--ignore-user-config"))
        XCTAssertTrue(entry.arguments(tier: .autoApprove).contains("--ignore-user-config"))
        XCTAssertFalse(entry.arguments(tier: .unrestricted).contains("--ignore-user-config"))
    }

    func testCodexCLIContract() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        XCTAssertEqual(entry.displayName, "Codex")
        XCTAssertEqual(entry.executableName, "codex")
        // Prompt rides in argv (positional), output parsed as plain text.
        XCTAssertEqual(entry.promptDelivery, .argument)
        XCTAssertEqual(entry.outputFormat, .text)
        XCTAssertEqual(entry.modelFlagName, "--model")
        XCTAssertEqual(entry.installed, entry.absolutePath != nil)
    }

    func testCodexEditsOnlyUsesWorkspaceWriteSandbox() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        let args = entry.arguments(permission: .editsOnly, model: "gpt-5.5")
        XCTAssertEqual(Array(args.prefix(2)), ["exec", "--skip-git-repo-check"])
        assertFlag(args, "--sandbox", value: "workspace-write")
        assertFlag(args, "--model", value: "gpt-5.5")
        XCTAssertFalse(args.contains("--full-auto"), "must not use the deprecated --full-auto")
        XCTAssertFalse(args.contains("danger-full-access"), "edits-only must not grant full access")
    }

    func testCodexAllowCommandsUsesDangerFullAccessSandbox() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        let args = entry.arguments(permission: .allowCommands)
        assertFlag(args, "--sandbox", value: "danger-full-access")
        XCTAssertFalse(args.contains("workspace-write"))
    }

    // MARK: - Cursor

    func testCursorCLIContract() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
        XCTAssertEqual(entry.displayName, "Cursor")
        XCTAssertEqual(entry.executableName, "cursor-agent")
        // Prompt rides in argv (positional `[prompt...]`); output is clean
        // line-delimited stream-json (parsed for live substatus + result summary).
        XCTAssertEqual(entry.promptDelivery, .argument)
        XCTAssertEqual(entry.outputFormat, .streamJSON)
        XCTAssertEqual(entry.modelFlagName, "--model")
        XCTAssertEqual(entry.installed, entry.absolutePath != nil)
    }

    func testCursorEditsOnlyIsPlainPrintAndTrustNoForce() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
        let args = entry.arguments(permission: .editsOnly, model: "claude-opus-4-8-high")
        // Headless, streamed, workspace pre-trusted (so an unattended run can't
        // stall on a trust prompt).
        XCTAssertEqual(Array(args.prefix(4)), ["-p", "--output-format", "stream-json", "--trust"])
        assertFlag(args, "--model", value: "claude-opus-4-8-high")
        // Edits-only is the DEFAULT `-p` posture (shell rejected) — there is no
        // deny-shell flag, and crucially NOT --force/--yolo (that would allow shell).
        XCTAssertFalse(args.contains("--force"), "edits-only must not allow commands")
        XCTAssertFalse(args.contains("--yolo"), "edits-only must not allow commands")
        // We deliberately do NOT pass --sandbox in either posture (verified: enabled
        // auto-runs shell, disabled degrades the edit tool).
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testCursorAllowCommandsAddsForce() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
        let args = entry.arguments(permission: .allowCommands)
        // --force (== --yolo) is the allow-commands opt-in; runs shell unsandboxed.
        XCTAssertTrue(args.contains("--force"), "allow-commands must pass --force")
        XCTAssertEqual(Array(args.prefix(4)), ["-p", "--output-format", "stream-json", "--trust"])
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testClaudeCodeCLIContract() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        XCTAssertEqual(entry.displayName, "Claude Code")
        XCTAssertEqual(entry.executableName, "claude")
        XCTAssertEqual(entry.promptDelivery, .stdin)
        XCTAssertEqual(entry.outputFormat, .streamJSON)
        // installed/absolutePath are detection-driven and consistent with each
        // other regardless of host.
        XCTAssertEqual(entry.installed, entry.absolutePath != nil)
    }

    func testEditsOnlyArgsAcceptEditsAndDenyShell() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        let args = entry.arguments(permission: .editsOnly)
        // Headless, streamed.
        XCTAssertEqual(Array(args.prefix(4)), ["-p", "--output-format", "stream-json", "--verbose"])
        // Auto-accept edits…
        assertFlag(args, "--permission-mode", value: "acceptEdits")
        // …but the shell is explicitly denied (design §11 edits-only default).
        assertFlag(args, "--disallowedTools", value: "Bash")
        XCTAssertFalse(args.contains("bypassPermissions"), "edits-only must not bypass permissions")
    }

    func testAllowCommandsArgsBypassPermissions() throws {
        let entry = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        let args = entry.arguments(permission: .allowCommands)
        assertFlag(args, "--permission-mode", value: "bypassPermissions")
        XCTAssertFalse(args.contains("--disallowedTools"), "allow-commands must not gate tools")
    }

    func testDefaultPermissionIsEditsOnly() {
        XCTAssertEqual(DevAgentPermission.default, .editsOnly)
    }

    // MARK: - Permission tiers (spec §6)

    func testTierSemantics() {
        // Fences apply to the two non-unrestricted tiers; only Ask Permission reviews.
        XCTAssertTrue(DevPermissionTier.askPermission.isFenced)
        XCTAssertTrue(DevPermissionTier.autoApprove.isFenced)
        XCTAssertFalse(DevPermissionTier.unrestricted.isFenced)
        XCTAssertTrue(DevPermissionTier.askPermission.reviewsBeforeDispatch)
        XCTAssertFalse(DevPermissionTier.autoApprove.reviewsBeforeDispatch)
        XCTAssertFalse(DevPermissionTier.unrestricted.reviewsBeforeDispatch)
        // Every tier runs commands enabled (containment is the fences, not the shell).
        for tier in DevPermissionTier.allCases {
            XCTAssertEqual(tier.agentPermission, .allowCommands)
        }
        // allCases order is the picker's row order.
        XCTAssertEqual(DevPermissionTier.allCases, [.askPermission, .autoApprove, .unrestricted])
    }

    func testClaudeTierFlags() throws {
        let e = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        let ask = e.arguments(tier: .askPermission)
        let auto = e.arguments(tier: .autoApprove)
        let unrestricted = e.arguments(tier: .unrestricted)

        // Ask Permission and Auto-Approve are CLI-identical (they differ only by the
        // Zerro-side review gate).
        XCTAssertEqual(ask, auto, "fenced tiers must produce identical argv")

        // Commands enabled in every tier; never the old edits-only flags.
        for args in [ask, auto, unrestricted] {
            XCTAssertEqual(Array(args.prefix(4)), ["-p", "--output-format", "stream-json", "--verbose"])
            assertFlag(args, "--permission-mode", value: "bypassPermissions")
            XCTAssertFalse(args.contains("acceptEdits"), "tiers run commands enabled")
            XCTAssertFalse(args.contains("--disallowedTools"), "tiers do not deny the shell")
        }

        // No-MCP fence (§5a) made certain: fenced tiers pass an explicit EMPTY
        // --mcp-config alongside --strict-mcp-config so ZERO servers load from any
        // source (user ~/.claude.json, project .mcp.json, claude.ai connectors).
        // Unrestricted passes neither.
        XCTAssertTrue(ask.contains("--strict-mcp-config"), "fenced ⇒ strict MCP config")
        assertFlag(ask, "--mcp-config", value: "{\"mcpServers\":{}}")
        // --mcp-config must come BEFORE --strict-mcp-config (strict reads the config).
        XCTAssertLessThan(try XCTUnwrap(ask.firstIndex(of: "--mcp-config")),
                          try XCTUnwrap(ask.firstIndex(of: "--strict-mcp-config")))
        XCTAssertFalse(unrestricted.contains("--strict-mcp-config"), "unrestricted ⇒ MCP enabled")
        XCTAssertFalse(unrestricted.contains("--mcp-config"), "unrestricted passes no MCP config")
    }

    func testCodexTierFlags() throws {
        let e = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.codexID))
        let ask = e.arguments(tier: .askPermission)
        let auto = e.arguments(tier: .autoApprove)
        let unrestricted = e.arguments(tier: .unrestricted)

        XCTAssertEqual(ask, auto, "fenced tiers must produce identical argv")

        // Commands enabled (danger-full-access keeps network on for npm install);
        // never the edits-only workspace-write.
        for args in [ask, auto, unrestricted] {
            assertFlag(args, "--sandbox", value: "danger-full-access")
            XCTAssertFalse(args.contains("workspace-write"), "tiers run commands enabled")
        }

        // No-MCP fence (§5a): fenced tiers add --ignore-user-config; unrestricted does not.
        XCTAssertTrue(ask.contains("--ignore-user-config"), "fenced ⇒ user MCP config ignored")
        XCTAssertFalse(unrestricted.contains("--ignore-user-config"), "unrestricted ⇒ user config (MCP) honored")
    }

    func testCursorTierFlags() throws {
        let e = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.cursorID))
        let ask = e.arguments(tier: .askPermission)
        let auto = e.arguments(tier: .autoApprove)
        let unrestricted = e.arguments(tier: .unrestricted)

        // Cursor has no positive MCP-disable flag, so all three tiers are argv-
        // identical — the env-scrub fence (§5b) is what differs.
        XCTAssertEqual(ask, auto)
        XCTAssertEqual(ask, unrestricted)

        for args in [ask, auto, unrestricted] {
            XCTAssertEqual(Array(args.prefix(4)), ["-p", "--output-format", "stream-json", "--trust"])
            // --force runs the shell (commands enabled) in every tier.
            XCTAssertTrue(args.contains("--force"), "tiers run commands enabled")
            // The no-MCP fence for Cursor is the ABSENCE of --approve-mcps.
            XCTAssertFalse(args.contains("--approve-mcps"), "Cursor never auto-approves MCP")
            XCTAssertFalse(args.contains("--sandbox"))
        }
    }

    func testTierModelFlagThreadsLast() throws {
        // The --model flag rides last, exactly like arguments(permission:model:).
        let e = try XCTUnwrap(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID))
        let args = e.arguments(tier: .askPermission, model: "claude-opus-4-8")
        assertFlag(args, "--model", value: "claude-opus-4-8")
        XCTAssertEqual(args.suffix(2), ["--model", "claude-opus-4-8"])
        // Empty/nil model ⇒ no flag (the agent's own default).
        XCTAssertFalse(e.arguments(tier: .askPermission, model: "").contains("--model"))
        XCTAssertFalse(e.arguments(tier: .askPermission).contains("--model"))
    }

    // MARK: - Helpers

    /// Asserts `flag` is present and immediately followed by `value`.
    private func assertFlag(_ args: [String], _ flag: String, value: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let idx = args.firstIndex(of: flag) else {
            return XCTFail("missing flag \(flag) in \(args)", file: file, line: line)
        }
        XCTAssertLessThan(idx + 1, args.count, "\(flag) has no value", file: file, line: line)
        XCTAssertEqual(args[idx + 1], value, file: file, line: line)
    }
}
