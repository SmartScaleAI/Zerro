//
//  DevNetworkProxyTests.swift
//  ZerroTests
//
//  Dev Mode — §8 network egress allowlisting. Deterministic coverage of the host
//  allowlist (the security-critical matcher), the CONNECT/Host parsing that feeds
//  it, the real `DevNetworkProxy` deny/allow/teardown behavior (network-free —
//  loopback only), the Seatbelt egress profile lines, the proxy env injection, and
//  the safety valve. A guarded LIVE integration test (real agent through the real
//  proxy) runs only when `ZERRO_LIVE_NET_TESTS=1`.
//

import XCTest
import Network
@testable import Zerro

final class DevNetworkProxyTests: XCTestCase {

    // MARK: - Allowlist matching (security-critical)

    func testAllowlistMatchesAgentAndRegistryHostsIncludingSubdomains() {
        let a = DevNetworkAllowlist.production
        // Agent APIs (incl. Cursor's sharded subdomains + Codex/Claude exacts).
        XCTAssertTrue(a.allows(host: "api.anthropic.com"))
        XCTAssertTrue(a.allows(host: "api.openai.com"))
        XCTAssertTrue(a.allows(host: "chatgpt.com"))
        XCTAssertTrue(a.allows(host: "api2.cursor.sh"))
        XCTAssertTrue(a.allows(host: "agentn.global.api5.cursor.sh"))
        XCTAssertTrue(a.allows(host: "repo42.cursor.sh"))
        // Registries / install hosts.
        XCTAssertTrue(a.allows(host: "registry.npmjs.org"))
        XCTAssertTrue(a.allows(host: "codeload.github.com"))
        XCTAssertTrue(a.allows(host: "objects.githubusercontent.com"))
        XCTAssertTrue(a.allows(host: "nodejs.org"))
        // Apex domains match too.
        XCTAssertTrue(a.allows(host: "cursor.sh"))
        XCTAssertTrue(a.allows(host: "anthropic.com"))
    }

    func testAllowlistRejectsArbitraryAndLookalikeHosts() {
        let a = DevNetworkAllowlist.production
        XCTAssertFalse(a.allows(host: "example.com"))
        XCTAssertFalse(a.allows(host: "evil.com"))
        // The Datadog telemetry host is intentionally NOT allowlisted.
        XCTAssertFalse(a.allows(host: "http-intake.logs.us5.datadoghq.com"))
        // Lookalikes that must NOT match by suffix:
        XCTAssertFalse(a.allows(host: "notcursor.sh"), "must be a SUBDOMAIN, not a suffix-string match")
        XCTAssertFalse(a.allows(host: "cursor.sh.evil.com"), "domain must be the SUFFIX, not a prefix")
        XCTAssertFalse(a.allows(host: "anthropic.com.evil.com"))
        XCTAssertFalse(a.allows(host: "fakenpmjs.org"))
        XCTAssertFalse(a.allows(host: ""))
        XCTAssertFalse(a.allows(host: "."))
    }

    func testAllowlistIsCaseAndTrailingDotInsensitive() {
        let a = DevNetworkAllowlist.production
        XCTAssertTrue(a.allows(host: "API.Anthropic.COM"))
        XCTAssertTrue(a.allows(host: "registry.npmjs.org."), "FQDN trailing dot is tolerated")
        XCTAssertTrue(a.allows(host: "Repo42.Cursor.SH"))
    }

    // MARK: - CONNECT / Host parsing (anti-bypass)

    func testSplitHostPortParsesAuthorityForms() {
        // host:port
        var r = DevNetworkProxy.splitHostPortForTesting("api.anthropic.com:443", defaultPort: 443)
        XCTAssertEqual(r.host, "api.anthropic.com"); XCTAssertEqual(r.port, 443)
        // host with no port → default
        r = DevNetworkProxy.splitHostPortForTesting("registry.npmjs.org", defaultPort: 443)
        XCTAssertEqual(r.host, "registry.npmjs.org"); XCTAssertEqual(r.port, 443)
        // bracketed IPv6
        r = DevNetworkProxy.splitHostPortForTesting("[::1]:5432", defaultPort: 443)
        XCTAssertEqual(r.host, "::1"); XCTAssertEqual(r.port, 5432)
        // empty authority → nil host (caller denies)
        r = DevNetworkProxy.splitHostPortForTesting("", defaultPort: 443)
        XCTAssertNil(r.host)
    }

    func testHttpHostPrefersAbsoluteFormThenHostHeader() {
        // Absolute-form request target.
        XCTAssertEqual(
            DevNetworkProxy.httpHostForTesting(
                requestTarget: "http://registry.npmjs.org/lodash", preamble: Data()),
            "registry.npmjs.org")
        // Origin-form → fall back to the Host header.
        let preamble = Data("GET /x HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n".utf8)
        XCTAssertEqual(
            DevNetworkProxy.httpHostForTesting(requestTarget: "/x", preamble: preamble),
            "api.anthropic.com")
    }

    // MARK: - Real proxy: deny / allow-relay / teardown (loopback only)

    func testProxyDeniesDisallowedConnectWith403() throws {
        let proxy = DevNetworkProxy(allowlist: DevNetworkAllowlist(domains: ["anthropic.com"]))
        let port = try proxy.start()
        defer { proxy.stop() }
        // example.com is NOT allowed → 403, and no upstream is contacted (no net).
        let response = try sendToProxy(port: port, request: "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"), "denied CONNECT must get 403, got: \(response.prefix(40))")
    }

    func testProxyDeniesNonHTTPPortEvenOnAllowedHost() throws {
        // Host allowed, but the port is NOT in the HTTP(S) set → 403. Stops a host
        // match from granting a raw tunnel to a co-resident service (SSH/DB/SMTP).
        // Denied at parse time, so github.com:22 is never actually dialed.
        let proxy = DevNetworkProxy(allowlist: DevNetworkAllowlist(domains: ["github.com"]))
        let port = try proxy.start()
        defer { proxy.stop() }
        for badPort in [22, 25, 5432, 6379, 8080] {
            let resp = try sendToProxy(port: port,
                request: "CONNECT github.com:\(badPort) HTTP/1.1\r\nHost: github.com:\(badPort)\r\n\r\n")
            XCTAssertTrue(resp.hasPrefix("HTTP/1.1 403"),
                          "allowed host on non-HTTP(S) port \(badPort) must be denied, got: \(resp.prefix(40))")
        }
    }

    func testProxyTunnelsAllowedHostAndRelaysBytes() throws {
        // Allow loopback so we can point the tunnel at a local echo server — proves
        // the CONNECT 200 + bidirectional relay without any external network.
        let echo = try LoopbackEchoServer()
        defer { echo.stop() }
        // Allow the echo server's ephemeral port too (the port gate would otherwise
        // deny a non-HTTP(S) port).
        let proxy = DevNetworkProxy(
            allowlist: DevNetworkAllowlist(domains: ["127.0.0.1"]),
            allowedPorts: [echo.port, 80, 443])
        let port = try proxy.start()
        defer { proxy.stop() }

        let sock = try openSocket(toPort: port)
        defer { close(sock) }
        // CONNECT to the echo server through the proxy.
        try writeAll(sock, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        let established = try readSome(sock)
        XCTAssertTrue(established.hasPrefix("HTTP/1.1 200"), "allowed CONNECT must get 200, got: \(established.prefix(40))")
        // Now the tunnel is raw: bytes we send are echoed back.
        try writeAll(sock, "ping-through-tunnel")
        let echoed = try readSome(sock)
        XCTAssertEqual(echoed, "ping-through-tunnel", "the tunnel must relay bytes verbatim")
    }

    func testProxyPortIsReleasedAfterStop() throws {
        let proxy = DevNetworkProxy(allowlist: .production)
        let port = try proxy.start()
        // Reachable while running.
        let s1 = try openSocket(toPort: port); close(s1)
        proxy.stop()
        // After stop the listener is gone — a connect should be refused. (Poll a few
        // times: the cancel is async.)
        var refused = false
        for _ in 0..<20 {
            if (try? openSocket(toPort: port)) == nil { refused = true; break }
            usleep(50_000)
        }
        XCTAssertTrue(refused, "no listener should remain on the proxy port after stop()")
    }

    func testStartIsIdempotentlyStoppable() throws {
        let proxy = DevNetworkProxy()
        _ = try proxy.start()
        proxy.stop()
        proxy.stop()  // must not crash
    }

    // MARK: - Seatbelt egress profile lines

    func testProfileAddsEgressLockdownWhenProxyPortGiven() {
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            proxyPort: 51234, home: "/Users/dev", temporaryDirectory: nil)
        XCTAssertTrue(prof.contains("(deny network-outbound (remote ip))"),
                      "must deny all IP egress")
        XCTAssertTrue(prof.contains(#"(allow network-outbound (remote ip "localhost:51234"))"#),
                      "must re-allow only the proxy's loopback port")
        // The deny must precede the allow (last-match-wins).
        let deny = prof.range(of: "(deny network-outbound")!.lowerBound
        let allow = prof.range(of: "(allow network-outbound")!.lowerBound
        XCTAssertTrue(deny < allow)
    }

    func testProfileHasNoEgressLinesWithoutProxyPort() {
        let prof = DevSeatbeltSandbox.profile(
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            proxyPort: nil, home: "/Users/dev", temporaryDirectory: nil)
        XCTAssertFalse(prof.contains("network-outbound"),
                       "no egress rules when the network filter is off (network stays open)")
    }

    func testWrapEgressProfileMatchesProfileWithSameProxyPort() {
        let agent = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let wrapped = DevSeatbeltSandbox.wrap(
            executableURL: agent, arguments: ["-p"],
            projectDirectory: URL(fileURLWithPath: "/private/tmp/proj"),
            proxyPort: 6000, home: "/Users/dev", temporaryDirectory: nil)
        XCTAssertEqual(wrapped.arguments[0], "-p")
        XCTAssertTrue(wrapped.arguments[1].contains(#"(allow network-outbound (remote ip "localhost:6000"))"#))
        XCTAssertEqual(wrapped.arguments[2], "/opt/homebrew/bin/claude")
    }

    // MARK: - Proxy env injection (§8) + valve

    private func fencedEnv(proxyURL: String?) -> [String: String] {
        ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            tier: .askPermission, proxyURL: proxyURL,
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/dev",
                              "DATABASE_URL": "postgres://u:p@host/db"])
    }

    func testFencedEnvInjectsAllProxyVarsWhenFiltered() {
        let env = fencedEnv(proxyURL: "http://127.0.0.1:51234")
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
                    "ALL_PROXY", "all_proxy", "npm_config_proxy", "npm_config_https_proxy"] {
            XCTAssertEqual(env[key], "http://127.0.0.1:51234", "\(key) must point at the filter proxy")
        }
        XCTAssertEqual(env["NO_PROXY"], "", "NO_PROXY must be empty so nothing bypasses the filter")
        XCTAssertEqual(env["no_proxy"], "")
        // The §5b scrub still strips secrets.
        XCTAssertNil(env["DATABASE_URL"])
    }

    func testFencedEnvHasNoProxyVarsWhenNotFiltered() {
        let env = fencedEnv(proxyURL: nil)
        for key in ["HTTPS_PROXY", "ALL_PROXY", "npm_config_proxy", "NO_PROXY"] {
            XCTAssertNil(env[key], "\(key) must be absent when the network filter is off")
        }
    }

    func testUnrestrictedNeverGetsProxyVarsEvenIfPassed() {
        // Unrestricted forwards the full env and is never network-filtered — a stray
        // proxyURL must not leak proxy vars into it.
        let env = ClaudeCodeAgentRunner.spawnEnvironmentForTesting(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            tier: .unrestricted, proxyURL: "http://127.0.0.1:9",
            baseEnvironment: ["PATH": "/usr/bin", "DATABASE_URL": "x"])
        XCTAssertNil(env["HTTPS_PROXY"])
        XCTAssertEqual(env["DATABASE_URL"], "x", "unrestricted forwards everything unchanged")
    }

    func testFilterValveDefaultsOnAndReadsKey() {
        let d = UserDefaults(suiteName: "DevNetworkProxyTests-\(UUID().uuidString)")!
        XCTAssertFalse(DevNetworkProxy.isFilterDisabled(defaults: d), "absent ⇒ filter ON")
        d.set(true, forKey: DevNetworkProxy.filterDisabledDefaultsKey)
        XCTAssertTrue(DevNetworkProxy.isFilterDisabled(defaults: d))
        XCTAssertEqual(DevNetworkProxy.filterDisabledDefaultsKey, "vf.dev.networkFilterDisabled")
    }

    // MARK: - LIVE integration (real agent through the real proxy + Seatbelt)
    //
    // Guarded: hits the real agent API + costs tokens, so it runs ONLY when
    // `ZERRO_LIVE_NET_TESTS=1`. Exercises the WHOLE production path — DevNetworkProxy
    // start, the egress Seatbelt profile, the proxy env injection, the spawn — by
    // driving the real `ClaudeCodeAgentRunner.run()` at a fenced tier (filter ON).

    func testLIVEAgentReachesAPIThroughProxyAndEditsInRepo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZERRO_LIVE_NET_TESTS"] == "1",
                          "live network test — set ZERRO_LIVE_NET_TESTS=1 to run")
        for agentID in [DevAgentRegistry.claudeCodeID, DevAgentRegistry.cursorID] {
            guard let entry = DevAgentRegistry.entry(id: agentID), entry.installed else { continue }
            let repo = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-net-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }

            let result = await ClaudeCodeAgentRunner().run(
                entry: entry, tier: .askPermission,
                prompt: "Create a file named live-net.txt containing the word hi. Do nothing else.",
                projectURL: repo, timeouts: .default, model: nil,
                onEvent: { _ in }, onStall: { _ in })

            let made = FileManager.default.fileExists(
                atPath: repo.appendingPathComponent("live-net.txt").path)
            XCTAssertTrue(made, "\(agentID): the agent must reach its API THROUGH the filter proxy and edit in-repo (result: \(result))")
        }
    }

    func testLIVENpmInstallThroughProxyAndBlockedHosts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZERRO_LIVE_NET_TESTS"] == "1",
                          "live network test — set ZERRO_LIVE_NET_TESTS=1 to run")
        try XCTSkipUnless(DevSeatbeltSandbox.isAvailable(), "needs sandbox-exec")

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-npm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try #"{"name":"x","private":true}"#.write(
            to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: repo) }

        let proxy = DevNetworkProxy(allowlist: .production)
        let port = try proxy.start()
        defer { proxy.stop() }
        let profile = DevSeatbeltSandbox.profile(projectDirectory: repo, proxyPort: port)
        let proxyURL = "http://127.0.0.1:\(port)"

        // (b) npm install through the proxy → node_modules appears in-repo.
        let npm = runSandboxed(profile: profile, proxyURL: proxyURL, cwd: repo,
            script: "npm install --no-audit --no-fund lodash >/dev/null 2>&1; echo $?")
        XCTAssertEqual(npm.trimmingCharacters(in: .whitespacesAndNewlines), "0", "npm install must succeed through the proxy")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            repo.appendingPathComponent("node_modules/lodash").path), "lodash must be installed in-repo")

        // (c) arbitrary external host blocked (proxy 403s the CONNECT).
        let ext = runSandboxed(profile: profile, proxyURL: proxyURL, cwd: repo,
            script: "curl -sS -m 8 https://example.com -o /dev/null -w '%{http_code}' 2>/dev/null; echo \" exit=$?\"")
        XCTAssertTrue(ext.contains("exit=") && !ext.contains("200"), "example.com must be blocked, got: \(ext)")

        // (d) a local non-proxy port blocked by the Seatbelt egress rule.
        let local = runSandboxed(profile: profile, proxyURL: proxyURL, cwd: repo,
            script: "curl -sS -m 5 http://127.0.0.1:5432/ -o /dev/null -w '%{http_code}' 2>/dev/null; echo \" exit=$?\"")
        XCTAssertTrue(local.contains("exit=") && !local.contains("200"), "127.0.0.1:5432 must be unreachable, got: \(local)")
    }

    /// Spawn `/usr/bin/sandbox-exec -p <profile> /bin/sh -c <script>` in `cwd` with
    /// the proxy env vars, returning stdout.
    private func runSandboxed(profile: String, proxyURL: String, cwd: URL, script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: DevSeatbeltSandbox.sandboxExecPath)
        p.arguments = ["-p", profile, "/bin/sh", "-c", script]
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        // The test host has a stripped PATH; prepend npm/node's real dir (login-shell
        // PATH, same probe the app uses) so `npm` resolves under the sandbox.
        if let npm = DevAgentBinaryResolver.resolve("npm") {
            env["PATH"] = npm.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "")
        } else if let login = DevAgentBinaryResolver.cachedLoginShellPATH() {
            env["PATH"] = login + ":" + (env["PATH"] ?? "")
        }
        for k in ["HTTPS_PROXY", "ALL_PROXY", "npm_config_proxy", "npm_config_https_proxy"] { env[k] = proxyURL }
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "spawn-failed: \(error)" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Raw-socket helpers (loopback)

    private func sendToProxy(port: UInt16, request: String) throws -> String {
        let sock = try openSocket(toPort: port)
        defer { close(sock) }
        try writeAll(sock, request)
        return try readSome(sock)
    }

    private func openSocket(toPort port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ECONNREFUSED) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    private func writeAll(_ fd: Int32, _ s: String) throws {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, bytes.count - off) }
            if n <= 0 { throw POSIXError(.EIO) }
            off += n
        }
    }

    private func readSome(_ fd: Int32) throws -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }
}

// MARK: - Minimal loopback echo server (for the relay test)

/// A tiny TCP echo server on 127.0.0.1:<ephemeral> using Network.framework —
/// echoes whatever it receives so the proxy-tunnel relay can be verified.
private final class LoopbackEchoServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.echo")

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: DispatchQueue(label: "test.echo.conn"))
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, err in
                    if let data, !data.isEmpty {
                        conn.send(content: data, completion: .contentProcessed { _ in if !done { pump() } })
                    } else if done || err != nil {
                        conn.cancel()
                    } else { pump() }
                }
            }
            pump()
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            listener.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        self.listener = listener
        self.port = p
    }

    func stop() { listener.cancel() }
}
