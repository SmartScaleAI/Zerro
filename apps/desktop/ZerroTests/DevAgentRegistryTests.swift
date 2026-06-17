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

    func testPhase1ShipsExactlyClaudeCode() {
        let all = DevAgentRegistry.all()
        XCTAssertEqual(all.count, 1, "Phase 1 ships exactly one agent")
        XCTAssertEqual(all.first?.id, DevAgentRegistry.claudeCodeID)
        XCTAssertEqual(DevAgentRegistry.recommendedID, DevAgentRegistry.claudeCodeID)
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
