//
//  DevAgentArgvConstructionTests.swift
//  ZerroTests
//
//  G-09 — pure argv-construction pins for the three registry agents, using
//  the REAL declarative registry data (DevAgentRegistry) through the pure
//  `DevAgentEntry.arguments(tier:/permission:)` seam — no process is spawned.
//  The runner-level assembly (the G-05 `--` end-of-options separator before
//  the positional prompt, stdin delivery, env scrubbing, process-group kill)
//  is already covered end-to-end by DevAgentRunnerTests; these tests pin the
//  SECURITY-RELEVANT FLAG SETS themselves, so a registry edit that silently
//  drops a fence flag (e.g. --strict-mcp-config or --ignore-user-config)
//  fails here with a readable argv diff instead of only surfacing in a live
//  dispatch.
//

import XCTest
@testable import Zerro

final class DevAgentArgvConstructionTests: XCTestCase {

    private func entry(_ id: String) throws -> DevAgentEntry {
        try XCTUnwrap(DevAgentRegistry.entry(id: id), "registry entry \(id) missing")
    }

    // MARK: - Claude Code

    func testClaudeFencedTierArgv() throws {
        let argv = try entry(DevAgentRegistry.claudeCodeID)
            .arguments(tier: .askPermission, model: "claude-opus-4-8")
        XCTAssertEqual(argv, [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions",
            "--mcp-config", "{\"mcpServers\":{}}", "--strict-mcp-config",
            "--model", "claude-opus-4-8",
        ], "the fenced Claude argv must carry the §5a empty-config + strict no-MCP pair, model last")
    }

    func testClaudeUnrestrictedDropsOnlyTheNoMCPFence() throws {
        let argv = try entry(DevAgentRegistry.claudeCodeID).arguments(tier: .unrestricted)
        XCTAssertEqual(argv, [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions",
        ], "unrestricted keeps commands enabled but leaves MCP on (no fence flags)")
    }

    func testClaudeEditsOnlyDeniesTheShell() throws {
        let argv = try entry(DevAgentRegistry.claudeCodeID).arguments(permission: .editsOnly)
        XCTAssertEqual(argv, [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "acceptEdits", "--disallowedTools", "Bash",
        ], "edits-only must pair acceptEdits with the explicit Bash deny")
    }

    // MARK: - Codex

    func testCodexFencedTierArgv() throws {
        let argv = try entry(DevAgentRegistry.codexID)
            .arguments(tier: .autoApprove, model: "gpt-5.5-codex")
        XCTAssertEqual(argv, [
            "exec", "--json", "--skip-git-repo-check", "--color", "never",
            "--sandbox", "danger-full-access",
            "--ignore-user-config",
            "--model", "gpt-5.5-codex",
        ], "the fenced Codex argv must carry --ignore-user-config (the §5a no-MCP fence)")
    }

    func testCodexUnrestrictedKeepsUserConfig() throws {
        let argv = try entry(DevAgentRegistry.codexID).arguments(tier: .unrestricted)
        XCTAssertFalse(argv.contains("--ignore-user-config"),
                       "unrestricted must NOT ignore the user config (MCP stays on): \(argv)")
        XCTAssertEqual(Array(argv.suffix(2)), ["--sandbox", "danger-full-access"])
    }

    func testCodexEditsOnlyUsesWorkspaceWrite() throws {
        let argv = try entry(DevAgentRegistry.codexID).arguments(permission: .editsOnly)
        XCTAssertEqual(Array(argv.suffix(2)), ["--sandbox", "workspace-write"],
                       "edits-only must pin the workspace-write sandbox, not danger-full-access")
    }

    // MARK: - Cursor

    func testCursorArgvNeverApprovesMCPs() throws {
        let cursor = try entry(DevAgentRegistry.cursorID)
        for tier in DevPermissionTier.allCases {
            let argv = cursor.arguments(tier: tier)
            XCTAssertEqual(argv, ["-p", "--output-format", "stream-json", "--trust", "--force"],
                           "cursor has no per-run MCP lever — fenced and unrestricted argv match (\(tier))")
            XCTAssertFalse(argv.contains("--approve-mcps"),
                           "the §5a fence for Cursor is the ABSENCE of --approve-mcps (\(tier))")
        }
    }

    // MARK: - Cross-agent contracts

    func testAskPermissionAndAutoApproveProduceIdenticalArgv() throws {
        // The two fenced tiers differ only by the Zerro-side review gate — the
        // documented contract is byte-identical agent argv.
        for id in [DevAgentRegistry.claudeCodeID, DevAgentRegistry.codexID, DevAgentRegistry.cursorID] {
            let e = try entry(id)
            XCTAssertEqual(
                e.arguments(tier: .askPermission, model: "m"),
                e.arguments(tier: .autoApprove, model: "m"),
                "\(id): the review gate must not change the spawned argv"
            )
        }
    }

    func testNoModelFlagWhenAbsentOrEmpty() throws {
        for id in [DevAgentRegistry.claudeCodeID, DevAgentRegistry.codexID, DevAgentRegistry.cursorID] {
            let e = try entry(id)
            XCTAssertFalse(e.arguments(tier: .askPermission, model: nil).contains("--model"),
                           "\(id): no selection ⇒ the agent's own default (no --model)")
            XCTAssertFalse(e.arguments(tier: .askPermission, model: "").contains("--model"),
                           "\(id): an empty selection must not emit a dangling --model")
        }
    }

    func testEveryTierRunsCommandsEnabled() {
        // The derived shell posture: containment comes from the fences, not
        // from disabling the headline "npm install" path.
        for tier in DevPermissionTier.allCases {
            XCTAssertEqual(tier.agentPermission, .allowCommands)
        }
        XCTAssertTrue(DevPermissionTier.askPermission.isFenced)
        XCTAssertTrue(DevPermissionTier.autoApprove.isFenced)
        XCTAssertFalse(DevPermissionTier.unrestricted.isFenced)
    }
}
