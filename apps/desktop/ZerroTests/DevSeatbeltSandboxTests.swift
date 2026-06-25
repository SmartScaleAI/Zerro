//
//  DevSeatbeltSandboxTests.swift
//  ZerroTests
//
//  Dev Mode — §5c filesystem-confinement wrapper. Unit-level coverage of the
//  Seatbelt profile generation (paths canonicalized + escaped, the deny-writes
//  inversion, the tight allow list), the `sandbox-exec` argv wrapping shape, the
//  availability probe, and the hidden safety valve. The end-to-end behavior
//  through the runner (fenced spawns get sandboxed, `.unrestricted` doesn't) lives
//  in `DevAgentRunnerTests`.
//

import XCTest
@testable import Zerro

final class DevSeatbeltSandboxTests: XCTestCase {

    // MARK: - Profile shape

    func testProfileHasPermissiveBaseAndDenyWritesInversion() {
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: "/private/var/folders/x/T")
        // The inversion: permissive base, then writes denied, then re-opened per path.
        XCTAssertTrue(prof.contains("(version 1)"))
        XCTAssertTrue(prof.contains("(allow default)"))
        XCTAssertTrue(prof.contains("(deny file-write*)"))
        // Order matters in Seatbelt (last match wins): the deny must precede the
        // re-allows so the targeted allows win for their subpaths.
        let denyIdx = prof.range(of: "(deny file-write*)")!.lowerBound
        let firstAllowWriteIdx = prof.range(of: "(allow file-write*")!.lowerBound
        XCTAssertTrue(denyIdx < firstAllowWriteIdx, "deny file-write* must come before the allow-write rules")
    }

    func testProfileAllowsRepoTempDevAndAgentStateDirs() {
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: "/private/var/folders/x/T")
        // The repo itself.
        XCTAssertTrue(prof.contains(#"(subpath "/private/tmp/proj")"#))
        // $TMPDIR + the standard temp roots.
        XCTAssertTrue(prof.contains(#"(subpath "/private/var/folders/x/T")"#))
        XCTAssertTrue(prof.contains(#"(subpath "/private/tmp")"#))
        XCTAssertTrue(prof.contains(#"(subpath "/private/var/folders")"#))
        XCTAssertTrue(prof.contains(#"(subpath "/tmp")"#))
        // /dev — without it /dev/null + PTY writes fail and the agents can't start.
        XCTAssertTrue(prof.contains(#"(subpath "/dev")"#), "/dev write access is required")
        // The agents' + toolchain's own state/cache dirs.
        for sub in ["/Users/dev/.claude", "/Users/dev/.codex", "/Users/dev/.cursor",
                    "/Users/dev/.npm", "/Users/dev/.cache", "/Users/dev/Library/Caches"] {
            XCTAssertTrue(prof.contains("(subpath \"\(sub)\")"), "expected allow for \(sub)")
        }
    }

    func testProfileDoesNotAllowHomeRootOrArbitraryPaths() {
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: nil)
        // The whole point: the home ROOT is never write-allowed (only specific
        // subdirs), and an unrelated path like /etc never appears.
        XCTAssertFalse(prof.contains(#"(subpath "/Users/dev")"#), "home root must NOT be write-allowed")
        XCTAssertFalse(prof.contains(#"(subpath "/etc")"#))
        XCTAssertFalse(prof.contains(#"(allow file-write*)"#), "must never blanket-allow writes")
    }

    func testProfileOmitsEmptyTmpdirRatherThanEmittingEmptySubpath() {
        // A nil/empty TMPDIR must NOT produce `(subpath "")` — `sandbox-exec`
        // rejects an empty subpath pattern ("empty subpath pattern" → exit 65).
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: nil)
        XCTAssertFalse(prof.contains(#"(subpath "")"#), "must not emit an empty subpath")
        XCTAssertFalse(prof.contains("(allow file-write* )"), "must not emit an empty allow rule")

        let profEmpty = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: "")
        XCTAssertFalse(profEmpty.contains(#"(subpath "")"#))
    }

    func testProfileEscapesQuotesAndBackslashesInPaths() {
        // A project path containing a double-quote and a backslash must be escaped
        // so the Seatbelt string literal stays well-formed.
        let weird = URL(fileURLWithPath: #"/private/tmp/a"b\c"#)
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: weird, home: "/Users/dev", temporaryDirectory: nil)
        // `"` → `\"` and `\` → `\\` inside the literal.
        XCTAssertTrue(prof.contains(#"(subpath "/private/tmp/a\"b\\c")"#),
                      "quotes and backslashes in the path must be escaped; got:\n\(prof)")
    }

    func testProfileCanonicalizesSymlinkedTmpPath() {
        // /tmp is a symlink to /private/tmp on macOS — the project path is
        // realpath'd so the subpath rule matches the OS's canonical view.
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/tmp"),
            home: "/Users/dev", temporaryDirectory: nil)
        XCTAssertTrue(prof.contains(#"(subpath "/private/tmp")"#),
                      "project path should be canonicalized via realpath (/tmp → /private/tmp)")
    }

    // MARK: - Wrap (argv shape)

    func testWrapProducesSandboxExecArgvWithProfileThenAgentThenArgs() {
        let agent = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let agentArgs = ["-p", "--output-format", "stream-json", "--verbose",
                         "--permission-mode", "bypassPermissions"]
        let wrapped = DevSeatbeltSandbox.wrap(
            executableURL: agent, arguments: agentArgs,
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: nil)

        // The binary spawned is sandbox-exec, NOT the agent.
        XCTAssertEqual(wrapped.executableURL.path, "/usr/bin/sandbox-exec")
        // argv: -p <profile> <agent-abs-path> <agent args…>
        XCTAssertEqual(wrapped.arguments[0], "-p")
        XCTAssertEqual(wrapped.arguments[1],
                       DevSeatbeltSandbox.profile(
                        projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
                        home: "/Users/dev", temporaryDirectory: nil),
                       "the profile rides as the -p argument")
        XCTAssertEqual(wrapped.arguments[2], "/opt/homebrew/bin/claude",
                       "the agent's ABSOLUTE path follows the profile")
        XCTAssertEqual(Array(wrapped.arguments[3...]), agentArgs,
                       "the agent's original argv is preserved verbatim, in order, after its path")
    }

    func testWrapPreservesArgumentDeliveryPromptAsLastArg() {
        // For `.argument` agents (Codex/Cursor) the prompt is the LAST agent arg —
        // it must remain the last element through the wrapping (still the agent's
        // positional arg, NOT sandbox-exec's).
        let agent = URL(fileURLWithPath: "/usr/local/bin/cursor-agent")
        let args = ["-p", "--output-format", "stream-json", "--trust", "--force", "make it teal"]
        let wrapped = DevSeatbeltSandbox.wrap(
            executableURL: agent, arguments: args,
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            home: "/Users/dev", temporaryDirectory: nil)
        XCTAssertEqual(wrapped.arguments.last, "make it teal")
        XCTAssertEqual(wrapped.arguments[2], "/usr/local/bin/cursor-agent")
    }

    // MARK: - Availability (fail-closed input)

    func testIsAvailableTrueForRealSandboxExec() {
        // On macOS the system sandbox-exec is present + executable. (If this ever
        // fails, the runner correctly FAILS CLOSED rather than spawning unsandboxed.)
        XCTAssertTrue(DevSeatbeltSandbox.isAvailable())
        XCTAssertEqual(DevSeatbeltSandbox.sandboxExecPath, "/usr/bin/sandbox-exec")
    }

    // MARK: - Safety valve

    func testWrapperDisabledDefaultsToFalse() {
        let defaults = ephemeralDefaults()
        XCTAssertFalse(DevSeatbeltSandbox.isWrapperDisabled(defaults: defaults),
                       "absent key ⇒ wrapper ON (disabled == false)")
    }

    func testWrapperDisabledReadsTheValve() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: DevSeatbeltSandbox.wrapperDisabledDefaultsKey)
        XCTAssertTrue(DevSeatbeltSandbox.isWrapperDisabled(defaults: defaults))
        XCTAssertEqual(DevSeatbeltSandbox.wrapperDisabledDefaultsKey, "vf.dev.seatbeltWrapperDisabled")
    }

    // MARK: - Helpers

    private func ephemeralDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "DevSeatbeltSandboxTests-\(UUID().uuidString)")!
        return d
    }
}
