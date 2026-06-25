//
//  DevNetworkProxy.swift
//  Zerro
//
//  Dev Mode — §8 network egress allowlisting (permission-tiers spec §8, the
//  Phase 2 §5c fast-follow). For the FENCED tiers, all of the agent's network
//  egress is forced through THIS local filtering proxy (by the Seatbelt egress
//  rule in `DevSeatbeltSandbox` + the proxy env vars in the §5b scrub), and the
//  proxy enforces a HOST allowlist: the active agent's API backend + the package
//  registries an `npm install` needs, and nothing else.
//
//  ── Why a proxy (not Seatbelt network rules) ────────────────────────────────
//  macOS Seatbelt can only allow/deny network by IP/port, not by hostname, and
//  the API + registry hosts are CDN-backed with rotating IPs. So per-HOST
//  allowlisting must live in a userspace proxy; Seatbelt is used only to force
//  ALL egress through it (deny every IP except this proxy's loopback port).
//
//  ── No TLS interception ─────────────────────────────────────────────────────
//  HTTPS is handled at the CONNECT layer: the target `host:port` is in plaintext
//  in the proxy's CONNECT request line, so we allow/deny by host and then BLIND-
//  tunnel the bytes for allowed hosts (no cert injection, no MITM, we never see
//  the plaintext). Plain HTTP is matched on the request's host and forwarded.
//
//  The proxy itself runs in the Zerro process — OUTSIDE the agent's Seatbelt
//  sandbox — so it can reach the real hosts; the sandboxed agent can reach only
//  this proxy. Bound to 127.0.0.1 on an ephemeral port, started for the duration
//  of one fenced run and torn down after (`start()` / `stop()`).
//
//  Network is intentionally OPEN in the unwrapped/`.unrestricted` path and when
//  the Phase 3 valve disables the filter — this type is only instantiated for a
//  network-filtered fenced run.
//

import Foundation
import Network
import os

// MARK: - Allowlist

/// The host allowlist enforced by `DevNetworkProxy`. Each entry is a registrable
/// domain that matches the host itself AND any subdomain (so `cursor.sh` covers
/// the sharded `api2` / `agentn.global.api5` / `repo42.cursor.sh` backends an
/// agent rotates through). Suffix-matching is REQUIRED — the agent + CDN hosts
/// are sharded/rotating, so exact pins would break.
///
/// Derived by OBSERVING real traffic (a logging proxy in front of each live
/// agent + a real `npm install`), not by guessing — see the per-entry notes.
/// This is the one place to update on agent/registry drift.
struct DevNetworkAllowlist: Sendable, Equatable {

    /// Domain suffixes (lowercased, no leading dot).
    let domains: [String]

    /// A host is allowed iff it equals an allowed domain or is a subdomain of one.
    func allows(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !h.isEmpty else { return false }
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The production allowlist for a fenced Dev-Mode run. Two categories:
    ///
    ///  ── Agent API backends (live-captured CONNECT hosts) ──
    ///   • anthropic.com — Claude Code's API (`api.anthropic.com`). Claude also
    ///     pings a Datadog telemetry host (`http-intake.logs.us5.datadoghq.com`);
    ///     verified that DENYING it does NOT break a run (telemetry fails silent),
    ///     so it is deliberately NOT allowlisted — keeps egress tight.
    ///   • openai.com — Codex's OpenAI endpoints (`api.openai.com`, `auth.openai.com`).
    ///   • chatgpt.com — Codex on a ChatGPT account talks to the ChatGPT backend
    ///     (`chatgpt.com`), the captured CONNECT host for that auth mode.
    ///   • cursor.sh — Cursor's backend, sharded across rotating subdomains
    ///     (captured: `api2`, `agentn.global.api5`, `repo42`.cursor.sh).
    ///   • cursor.com — Cursor's newer domain (defensive; some endpoints migrated).
    ///
    ///  ── Package registries / install hosts ──
    ///   • npmjs.org — npm metadata + tarballs + most prebuilt binaries all come
    ///     from `registry.npmjs.org` (verified: `npm i express esbuild` — 69 pkgs
    ///     incl. esbuild's platform binary — touched ONLY this host). The suffix
    ///     also covers any `*.npmjs.org` CDN edge.
    ///   • yarnpkg.com — the yarn registry, for projects on yarn.
    ///   • github.com — github-hosted deps + release redirects (and a host Codex
    ///     itself contacts); `npm i user/repo` resolves here.
    ///   • githubusercontent.com — github release binary assets + raw files
    ///     (`objects.`/`raw.githubusercontent.com`) that some prebuilt-binary
    ///     postinstalls fetch (e.g. sharp, better-sqlite3).
    ///   • nodejs.org — node-gyp downloads node headers here to build native deps.
    static let production = DevNetworkAllowlist(domains: [
        // agent APIs
        "anthropic.com", "openai.com", "chatgpt.com", "cursor.sh", "cursor.com",
        // package registries / install hosts
        "npmjs.org", "yarnpkg.com", "github.com", "githubusercontent.com", "nodejs.org",
    ])
}

// MARK: - Proxy

/// A minimal loopback forward-proxy that enforces `DevNetworkAllowlist`. Driven
/// off-main (its own dispatch queues); explicitly `@unchecked Sendable` with its
/// shared state guarded by `lock`. Handles HTTP `CONNECT` (HTTPS blind tunnel)
/// and absolute-form plain HTTP.
final class DevNetworkProxy: @unchecked Sendable {

    /// Hidden/dev safety valve (spec §5 Phase 3): when this UserDefaults Bool is
    /// `true`, the network filter is disabled and a fenced run keeps OPEN egress
    /// (the Phase 2 filesystem fence still applies). Default (absent ⇒ `false`) =
    /// filter ON. Mirrors the Phase 2 `DevSeatbeltSandbox` valve. No UI.
    nonisolated static let filterDisabledDefaultsKey = "vf.dev.networkFilterDisabled"

    /// Whether the network filter is disabled by the hidden valve. Injectable for
    /// tests; default `false` ⇒ filter ON.
    nonisolated static func isFilterDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: filterDisabledDefaultsKey)
    }

    enum ProxyError: Error, CustomStringConvertible {
        case startTimedOut
        case noPort
        case listenerFailed(String)
        var description: String {
            switch self {
            case .startTimedOut:        return "the egress filter proxy did not come up in time"
            case .noPort:               return "the egress filter proxy bound no port"
            case .listenerFailed(let m): return "the egress filter proxy failed to start: \(m)"
            }
        }
    }

    private let allowlist: DevNetworkAllowlist
    /// Upstream ports the proxy will dial. A host match must NOT grant a raw TCP
    /// tunnel to an arbitrary co-resident service — without this, a sandboxed agent
    /// could `CONNECT github.com:22` (SSH) / `:25` (SMTP) / `:5432` (DB) to an
    /// allowlisted, CDN-fronted host and tunnel out. Restricted to HTTP(S).
    private let allowedPorts: Set<UInt16>
    private let log = Log.dev
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.zerro.dev.netproxy.listener")
    /// Concurrent so independent tunnels (e.g. parallel npm tarball fetches) don't
    /// serialize behind each other.
    private let ioQueue = DispatchQueue(label: "com.zerro.dev.netproxy.io", attributes: .concurrent)

    private var listener: NWListener?
    /// Live sessions, retained so they aren't deallocated mid-tunnel; each removes
    /// itself on close. Guarded by `lock`.
    private var sessions: Set<ProxySession> = []
    private var stopped = false
    /// Test-only: force `start()` to throw, to exercise the runner's fail-closed.
    private let simulateStartFailure: Bool

    init(allowlist: DevNetworkAllowlist = .production,
         allowedPorts: Set<UInt16> = [80, 443],
         simulateStartFailure: Bool = false) {
        self.allowlist = allowlist
        self.allowedPorts = allowedPorts
        self.simulateStartFailure = simulateStartFailure
    }

    /// Bind to 127.0.0.1 on an ephemeral port and begin accepting. Returns the
    /// bound port. THROWS on any failure — the caller FAILS CLOSED (never runs a
    /// fenced agent with open egress).
    func start() throws -> UInt16 {
        if simulateStartFailure { throw ProxyError.listenerFailed("simulated start failure (test)") }
        let params = NWParameters.tcp
        // Loopback-only bind: nothing off-box (and no other local user) can reach
        // the proxy. Ephemeral port (.any) chosen by the OS.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ProxyError.listenerFailed(String(describing: error))
        }
        lock.lock(); self.listener = listener; lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let failure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.withLock { $0 = ProxyError.listenerFailed(String(describing: error)) }
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: listenerQueue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            stop()
            throw ProxyError.startTimedOut
        }
        if let error = failure.withLock({ $0 }) {
            stop()
            throw error
        }
        guard let port = listener.port?.rawValue else {
            stop()
            throw ProxyError.noPort
        }
        log.notice("Dev network filter proxy listening on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    /// Cancel the listener and tear down every live tunnel. Idempotent — safe to
    /// call from `defer` and again on app quit. After this returns the listener no
    /// longer accepts and the loopback port is released.
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let listener = self.listener
        self.listener = nil
        let live = self.sessions
        self.sessions.removeAll()
        lock.unlock()

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        for session in live { session.close() }
    }

    // MARK: Accept

    private func accept(_ connection: NWConnection) {
        let session = ProxySession(
            client: connection, allowlist: allowlist, allowedPorts: allowedPorts,
            queue: ioQueue, log: log,
            onClose: { [weak self] session in self?.remove(session) })
        lock.lock()
        if stopped { lock.unlock(); session.close(); return }
        sessions.insert(session)
        lock.unlock()
        session.start()
    }

    private func remove(_ session: ProxySession) {
        lock.lock(); sessions.remove(session); lock.unlock()
    }

    // MARK: Testing seams (the request parsers live on the private session type)

    /// `host:port` split used on the CONNECT line — exposed so tests can prove a
    /// malformed/spoofed authority can't slip a denied host past the allowlist.
    nonisolated static func splitHostPortForTesting(_ s: String, defaultPort: UInt16) -> (host: String?, port: UInt16) {
        ProxySession.splitHostPort(s, defaultPort: defaultPort)
    }

    /// Host resolution for a plain-HTTP request (absolute-form URI or `Host:` header).
    nonisolated static func httpHostForTesting(requestTarget: String, preamble: Data) -> String? {
        ProxySession.httpHost(requestTarget: requestTarget, preamble: preamble)
    }
}

// MARK: - One client tunnel

/// Owns one accepted client connection and (once a request is parsed + allowed)
/// the matching upstream connection, blind-relaying bytes between them. Reference
/// identity is used for the proxy's session set; all I/O is on the shared queue.
private final class ProxySession: Hashable, @unchecked Sendable {

    private let client: NWConnection
    private let allowlist: DevNetworkAllowlist
    private let allowedPorts: Set<UInt16>
    private let queue: DispatchQueue
    private let log: Logger
    private let onClose: (ProxySession) -> Void

    private let lock = NSLock()
    private var upstream: NWConnection?
    private var closed = false

    /// Cap on the request preamble we'll buffer before declaring it malformed.
    private static let maxPreamble = 64 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    init(client: NWConnection, allowlist: DevNetworkAllowlist, allowedPorts: Set<UInt16>,
         queue: DispatchQueue, log: Logger, onClose: @escaping (ProxySession) -> Void) {
        self.client = client
        self.allowlist = allowlist
        self.allowedPorts = allowedPorts
        self.queue = queue
        self.log = log
        self.onClose = onClose
    }

    static func == (lhs: ProxySession, rhs: ProxySession) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        client.start(queue: queue)
        readPreamble(buffer: Data())
    }

    // MARK: Read + parse the proxy request

    private func readPreamble(buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error as NSError?, !Self.isBenignReceiveError(error) {
                self.close(); return
            }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Self.headerTerminator) {
                let preamble = buf.subdata(in: buf.startIndex..<range.upperBound)
                let leftover = buf.subdata(in: range.upperBound..<buf.endIndex)
                self.handleRequest(preamble: preamble, leftover: leftover)
            } else if buf.count > Self.maxPreamble {
                self.reject(status: "400 Bad Request"); return
            } else if isComplete {
                self.close()
            } else {
                self.readPreamble(buffer: buf)
            }
        }
    }

    private func handleRequest(preamble: Data, leftover: Data) {
        guard let text = String(data: preamble, encoding: .utf8),
              let firstLine = Self.splitLines(text).first.map(String.init) else {
            reject(status: "400 Bad Request"); return
        }
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { reject(status: "400 Bad Request"); return }
        let method = parts[0].uppercased()

        if method == "CONNECT" {
            // CONNECT host:port — the host is in plaintext; allow/deny by host AND
            // port (HTTP(S) only) then tunnel. The port gate stops a host match from
            // granting a raw tunnel to a co-resident non-HTTP service (SSH/DB/SMTP).
            let (host, port) = Self.splitHostPort(parts[1], defaultPort: 443)
            guard let host, allowlist.allows(host: host), allowedPorts.contains(port) else {
                log.notice("Dev network filter DENY CONNECT \(parts[1], privacy: .public)")
                reject(status: "403 Forbidden"); return
            }
            connectUpstream(host: host, port: port) { [weak self] in
                // Acknowledge the tunnel to the client, then relay (no header
                // forwarding — the CONNECT headers are ours, not the upstream's).
                self?.send(to: self?.client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) {
                    self?.beginRelay(initialToUpstream: leftover.isEmpty ? nil : leftover)
                }
            }
        } else {
            // Absolute-form HTTP (`GET http://host/… HTTP/1.1`) or origin-form with
            // a Host header. Resolve the host, allow/deny, then forward the request
            // bytes verbatim and relay.
            let host = Self.httpHost(requestTarget: parts[1], preamble: preamble)
            let port = Self.httpPort(requestTarget: parts[1])
            guard let host, allowlist.allows(host: host), allowedPorts.contains(port) else {
                log.notice("Dev network filter DENY HTTP \(parts.count > 1 ? parts[1] : "?", privacy: .public)")
                reject(status: "403 Forbidden"); return
            }
            connectUpstream(host: host, port: port) { [weak self] in
                var forward = preamble
                forward.append(leftover)
                self?.beginRelay(initialToUpstream: forward)
            }
        }
    }

    // MARK: Upstream + relay

    private func connectUpstream(host: String, port: UInt16, onReady: @escaping () -> Void) {
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { reject(status: "400 Bad Request"); return }
        let conn = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        lock.lock(); upstream = conn; lock.unlock()

        // Bound the connect attempt so a hung upstream can't pin a session forever.
        let deadline = DispatchWorkItem { [weak self] in
            if conn.state != .ready { self?.close() }
        }
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)

        var acked = false
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !acked else { return }
                acked = true
                deadline.cancel()
                onReady()
            case .failed, .cancelled:
                deadline.cancel()
                self.close()
            case .waiting:
                // No route / refused — fail fast rather than waiting out the deadline.
                // Only send a 502 BEFORE the tunnel is acked; once acked, a late
                // `.waiting` must NOT inject bytes into the established stream.
                deadline.cancel()
                if acked { self.close() } else { self.reject(status: "502 Bad Gateway") }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func beginRelay(initialToUpstream: Data?) {
        lock.lock(); let up = upstream; lock.unlock()
        guard let up else { close(); return }
        if let initial = initialToUpstream, !initial.isEmpty {
            send(to: up, initial) { [weak self] in self?.pump(from: up, to: self?.client) }
        } else {
            pump(from: up, to: client)
        }
        pump(from: client, to: up)
    }

    /// One-directional byte pump; on EOF/error in either direction the whole
    /// session is torn down (both halves). When the FINAL chunk arrives WITH
    /// `isComplete`, the close MUST wait until that chunk has flushed to `dst`
    /// (closing here would cancel the in-flight send and truncate the response).
    private func pump(from src: NWConnection?, to dst: NWConnection?) {
        guard let src, let dst else { close(); return }
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    // Close only AFTER the final bytes have flushed.
                    if sendError != nil || isComplete { self.close() }
                    else { self.pump(from: src, to: dst) }
                })
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.pump(from: src, to: dst)
            }
        }
    }

    // MARK: Helpers

    private func send(to conn: NWConnection?, _ data: Data, completion: @escaping () -> Void) {
        guard let conn else { close(); return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() } else { completion() }
        })
    }

    /// Deny a request: best-effort status line to the client, then tear down.
    private func reject(status: String) {
        let body = Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        client.send(content: body, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let up = upstream
        upstream = nil
        lock.unlock()
        client.cancel()
        up?.cancel()
        onClose(self)
    }

    /// `ECANCELED`/`ENOTCONN` after our own cancel are expected, not real errors.
    private static func isBenignReceiveError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ECANCELED) || error.code == Int(ENOTCONN)
        }
        return false
    }

    /// Split `host:port` (handles bracketed IPv6 `[::1]:443`), defaulting the port.
    static func splitHostPort(_ s: String, defaultPort: UInt16) -> (host: String?, port: UInt16) {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { return (host, p) }
            return (host, defaultPort)
        }
        guard let colon = s.lastIndex(of: ":") else { return (s.isEmpty ? nil : s, defaultPort) }
        let host = String(s[s.startIndex..<colon])
        let port = UInt16(s[s.index(after: colon)...]) ?? defaultPort
        return (host.isEmpty ? nil : host, port)
    }

    /// Host for a plain-HTTP request: prefer the absolute-form URI's host, else the
    /// `Host:` header (origin-form).
    static func httpHost(requestTarget: String, preamble: Data) -> String? {
        if let comps = URLComponents(string: requestTarget), let host = comps.host, !host.isEmpty {
            return host
        }
        guard let text = String(data: preamble, encoding: .utf8) else { return nil }
        for line in splitLines(text) {
            if line.lowercased().hasPrefix("host:") {
                let value = line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
                return splitHostPort(value, defaultPort: 80).host
            }
        }
        return nil
    }

    /// Split a header block into lines. `\r\n` is a SINGLE Swift `Character`
    /// (grapheme), so a `Character`-based split on `\r`/`\n` would NOT break CRLF
    /// lines — normalize to `\n` first (Foundation's replace is UTF-16-based, so it
    /// matches the CRLF code units regardless of grapheme clustering).
    static func splitLines(_ s: String) -> [Substring] {
        let normalized = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: true)
    }

    static func httpPort(requestTarget: String) -> UInt16 {
        if let comps = URLComponents(string: requestTarget), let port = comps.port,
           let p = UInt16(exactly: port) {
            return p
        }
        return 80
    }
}
