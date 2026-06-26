//
//  DevClaudeNativeSandboxTests.swift
//  ZerroTests
//
//  Dev Mode — the `.claudeNative` confinement builder (`DevClaudeNativeSandbox`):
//  the transient `--settings` JSON (native sandbox + write/network allowlist +
//  permission deny/allow rules) and the argv transform (strip bypassPermissions →
//  dontAsk + --setting-sources "" + --settings). Pure unit pass — no process, no
//  Keychain, no network. The OS-level enforcement is covered by live validation.
//

import XCTest
@testable import Zerro

final class DevClaudeNativeSandboxTests: XCTestCase {

    private var project: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A real on-disk dir so realpath canonicalization resolves (the rules must
        // match the OS's symlink-free view).
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-claudenative-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project) }
        try super.tearDownWithError()
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - Settings JSON

    func testSettingsEnablesSandboxFailClosedNoUnsandboxedRetry() throws {
        let json = try decode(try DevClaudeNativeSandbox.settingsJSON(projectDirectory: project))
        let sandbox = try XCTUnwrap(json["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true, "fail closed if the sandbox can't init")
        XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false,
                       "no escape-via-unsandboxed-retry")
    }

    func testSettingsNetworkMirrorsProductionAllowlistWithWildcards() throws {
        let json = try decode(try DevClaudeNativeSandbox.settingsJSON(projectDirectory: project))
        let net = try XCTUnwrap((json["sandbox"] as? [String: Any])?["network"] as? [String: Any])
        XCTAssertEqual(net["allowLocalBinding"] as? Bool, true, "a sandboxed dev server can still bind localhost")
        let domains = try XCTUnwrap(net["allowedDomains"] as? [String])
        // Each production registrable domain plus a subdomain wildcard — single source
        // of truth, so it tracks DevNetworkAllowlist.production drift automatically.
        for d in DevNetworkAllowlist.production.domains {
            XCTAssertTrue(domains.contains(d), "missing \(d)")
            XCTAssertTrue(domains.contains("*." + d), "missing wildcard *.\(d)")
        }
        XCTAssertEqual(domains.count, DevNetworkAllowlist.production.domains.count * 2)
    }

    func testSettingsWriteAllowlistCoversRepoAndToolchainDirs() throws {
        let json = try decode(try DevClaudeNativeSandbox.settingsJSON(projectDirectory: project))
        let fs = try XCTUnwrap((json["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
        let allowWrite = try XCTUnwrap(fs["allowWrite"] as? [String])
        // The canonical repo path (so npm install / edits land in-repo) …
        XCTAssertTrue(allowWrite.contains(DevClaudeNativeSandbox.canonicalize(project.path)),
                      "repo must be write-allowlisted (canonical form)")
        // … plus the toolchain cache/temp dirs npm/builds need outside cwd.
        for p in DevClaudeNativeSandbox.toolchainWritePaths {
            XCTAssertTrue(allowWrite.contains(p), "missing toolchain write path \(p)")
        }
    }

    func testSettingsDenyReadsSensitivePathsOnBothLayers() throws {
        let json = try decode(try DevClaudeNativeSandbox.settingsJSON(projectDirectory: project))
        // Bash layer: sandbox.filesystem.denyRead.
        let fs = try XCTUnwrap((json["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
        XCTAssertEqual(fs["denyRead"] as? [String], DevClaudeNativeSandbox.sensitiveReadDenyPaths)
        // Read-tool layer: permissions.deny = Read(<path>/**) for each sensitive path.
        let perms = try XCTUnwrap(json["permissions"] as? [String: Any])
        let deny = try XCTUnwrap(perms["deny"] as? [String])
        XCTAssertEqual(deny, DevClaudeNativeSandbox.sensitiveReadDenyPaths.map { "Read(\($0)/**)" })
        // npm needs ~/.npmrc, so it must NOT be in the Bash read-deny list.
        XCTAssertFalse((fs["denyRead"] as? [String] ?? []).contains("~/.npmrc"),
                       "~/.npmrc must stay readable so npm install works")
    }

    func testSettingsPermissionsScopeEditWriteToRepoWithAbsoluteGlob() throws {
        let json = try decode(try DevClaudeNativeSandbox.settingsJSON(projectDirectory: project))
        let perms = try XCTUnwrap(json["permissions"] as? [String: Any])
        XCTAssertEqual(perms["defaultMode"] as? String, "dontAsk")
        let allow = try XCTUnwrap(perms["allow"] as? [String])
        let canon = DevClaudeNativeSandbox.canonicalize(project.path)
        // The `//`-absolute form is REQUIRED — a single `/` is project-relative and
        // would never match (learned the hard way in Phase 1).
        let glob = DevClaudeNativeSandbox.absoluteGlob(canon)
        XCTAssertTrue(glob.hasPrefix("//"), "absolute glob must be //-prefixed")
        XCTAssertEqual(allow, ["Bash", "Read", "Edit(\(glob))", "Write(\(glob))"])
    }

    func testSettingsIsValidJSON() throws {
        // Round-trips through the OS JSON parser without throwing (Claude must parse it).
        let json = try DevClaudeNativeSandbox.settingsJSON(projectDirectory: project)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    // MARK: - Argv transform

    func testArgumentsStripBypassAndAppendNativeFlags() {
        // The registry's fenced base for Claude (bypassPermissions + the no-MCP fence).
        let base = ["-p", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "bypassPermissions",
                    "--mcp-config", "{\"mcpServers\":{}}", "--strict-mcp-config",
                    "--model", "claude-opus-4-8"]
        let out = DevClaudeNativeSandbox.arguments(base: base, settingsFilePath: "/tmp/s.json")

        // bypassPermissions (and its flag) stripped …
        XCTAssertFalse(out.contains("bypassPermissions"))
        // … exactly one --permission-mode, now dontAsk.
        XCTAssertEqual(out.filter { $0 == "--permission-mode" }.count, 1)
        let pm = try! XCTUnwrap(out.firstIndex(of: "--permission-mode"))
        XCTAssertEqual(out[pm + 1], "dontAsk")
        // --setting-sources "" loads no user/project/local settings.
        let ss = try! XCTUnwrap(out.firstIndex(of: "--setting-sources"))
        XCTAssertEqual(out[ss + 1], "")
        // --settings points at the transient file.
        let s = try! XCTUnwrap(out.firstIndex(of: "--settings"))
        XCTAssertEqual(out[s + 1], "/tmp/s.json")
        // The §5a no-MCP fence + base flags + model are PRESERVED (only the
        // permission-mode pair was touched). The native flags are appended LAST, so
        // --model is no longer last — but it's intact, and flag order is irrelevant.
        XCTAssertTrue(out.contains("--strict-mcp-config"))
        XCTAssertEqual(out.firstIndex(of: "--mcp-config").map { out[$0 + 1] }, "{\"mcpServers\":{}}")
        XCTAssertEqual(out.firstIndex(of: "--model").map { out[$0 + 1] }, "claude-opus-4-8")
        XCTAssertEqual(Array(out.suffix(2)), ["--settings", "/tmp/s.json"], "the native flags are appended last")
        XCTAssertEqual(Array(out.prefix(4)), ["-p", "--output-format", "stream-json", "--verbose"])
    }

    func testArgumentsHandlesBaseWithoutPermissionMode() {
        // No --permission-mode to strip → still appends the native flags cleanly.
        let out = DevClaudeNativeSandbox.arguments(base: ["-p", "--verbose"], settingsFilePath: "/x/y.json")
        XCTAssertEqual(out, ["-p", "--verbose",
                             "--permission-mode", "dontAsk",
                             "--setting-sources", "",
                             "--settings", "/x/y.json"])
    }

    func testArgumentsStripsTrailingPermissionModeWithoutValueSafely() {
        // A degenerate base where --permission-mode is the LAST token (no value): it
        // must not crash or strip past the end; it's kept (no following value to drop).
        let out = DevClaudeNativeSandbox.arguments(base: ["-p", "--permission-mode"],
                                                   settingsFilePath: "/x/y.json")
        XCTAssertEqual(Array(out.prefix(2)), ["-p", "--permission-mode"])
        XCTAssertTrue(out.contains("dontAsk"))
        XCTAssertEqual(out.last, "/x/y.json")
    }

    // MARK: - Valve

    func testValveDefaultsToEnabled() {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        XCTAssertFalse(DevClaudeNativeSandbox.isDisabled(defaults: d), "absent key ⇒ native sandbox ON")
        d.set(true, forKey: DevClaudeNativeSandbox.disabledDefaultsKey)
        XCTAssertTrue(DevClaudeNativeSandbox.isDisabled(defaults: d))
    }

    // MARK: - Minimum version gate

    private func assertVersion(_ raw: String, _ major: Int, _ minor: Int, _ patch: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let v = DevClaudeNativeSandbox.parseVersion(raw) else {
            return XCTFail("expected to parse \(raw)", file: file, line: line)
        }
        XCTAssertEqual([v.major, v.minor, v.patch], [major, minor, patch], file: file, line: line)
    }

    func testParseVersionExtractsSemverFromClaudeOutput() {
        assertVersion("2.1.179 (Claude Code)", 2, 1, 179)
        assertVersion("v3.0.10", 3, 0, 10)
        assertVersion("Claude Code 12.34.56 build x", 12, 34, 56)
        // Unparseable / partial / nil → nil.
        XCTAssertNil(DevClaudeNativeSandbox.parseVersion("2.1"))
        XCTAssertNil(DevClaudeNativeSandbox.parseVersion("not a version"))
        XCTAssertNil(DevClaudeNativeSandbox.parseVersion(""))
        XCTAssertNil(DevClaudeNativeSandbox.parseVersion(nil))
    }

    func testSupportsNativeSandboxComparesAgainstMinimum() {
        let min = DevClaudeNativeSandbox.minimumSupportedVersion
        // At and above the floor → supported.
        XCTAssertTrue(DevClaudeNativeSandbox.supportsNativeSandbox(version: DevClaudeNativeSandbox.minimumSupportedVersionString))
        XCTAssertTrue(DevClaudeNativeSandbox.supportsNativeSandbox(version: "\(min.major).\(min.minor).\(min.patch) (Claude Code)"))
        XCTAssertTrue(DevClaudeNativeSandbox.supportsNativeSandbox(version: "\(min.major).\(min.minor).\(min.patch + 1)"))
        XCTAssertTrue(DevClaudeNativeSandbox.supportsNativeSandbox(version: "\(min.major + 1).0.0"))
        XCTAssertTrue(DevClaudeNativeSandbox.supportsNativeSandbox(version: "999.0.0 (Claude Code)"))
        // Below the floor → not supported.
        XCTAssertFalse(DevClaudeNativeSandbox.supportsNativeSandbox(version: "\(min.major).\(min.minor).\(min.patch - 1)"))
        XCTAssertFalse(DevClaudeNativeSandbox.supportsNativeSandbox(version: "2.0.999"))
        XCTAssertFalse(DevClaudeNativeSandbox.supportsNativeSandbox(version: "1.9.9"))
        // Undetectable → not supported (degrade, never hard-fail).
        XCTAssertFalse(DevClaudeNativeSandbox.supportsNativeSandbox(version: nil))
        XCTAssertFalse(DevClaudeNativeSandbox.supportsNativeSandbox(version: "garbage"))
    }

    // MARK: - Transient file write/lifecycle

    func testWriteTransientSettingsCreatesParsableFileCallerDeletes() throws {
        let url = try DevClaudeNativeSandbox.writeTransientSettings(projectDirectory: project)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "json")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(content.utf8)),
                         "the written file must be valid JSON Claude can load")
    }
}
