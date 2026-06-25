//
//  DevSeatbeltSandbox.swift
//  Zerro
//
//  Dev Mode — §5c filesystem confinement (permission-tiers spec §5c / §8 / §10).
//  Phase 2: for the FENCED tiers (`.askPermission` / `.autoApprove`) the agent is
//  wrapped in a Zerro-owned macOS Seatbelt profile (`/usr/bin/sandbox-exec`) that
//  denies file-WRITES outside the project directory while leaving reads, network,
//  and process spawning OPEN. So an in-repo edit, `npm install` (writes
//  node_modules in-repo + fetches over the open network), and a build all keep
//  working, but a write to an absolute path OUTSIDE the repo is physically blocked
//  by the OS — the git checkpoint is then a true undo. Network allowlisting is a
//  later phase (spec §8) and intentionally NOT done here.
//
//  `.unrestricted` is NEVER wrapped — it spawns the agent directly (today's
//  behavior). Only `tier.isFenced` flows through here.
//
//  ── No Seatbelt nesting (spec §10) ──────────────────────────────────────────
//  macOS Seatbelt sandboxes CANNOT nest — an inner `sandbox_init` inside an
//  already-sandboxed process fails with "Operation not permitted". This wrapper
//  is therefore the ONLY active Seatbelt sandbox for the run, which REQUIRES each
//  agent's own native sandbox to be OFF. That invariant already holds in the
//  fenced tiers' CLI mapping (spec §6): Claude Code has no native sandbox active
//  (`bypassPermissions`), Codex runs `--sandbox danger-full-access`, Cursor runs
//  `--force`. Do not pair this wrapper with an agent's own Seatbelt sandbox.
//
//  ── Profile shape (permissive-base / deny-writes inversion) ─────────────────
//  Generated at runtime with the REAL paths interpolated (project dir + $TMPDIR
//  canonicalized via realpath; each path escaped for the Seatbelt string literal
//  so spaces/parens/quotes are safe). `(allow default)` keeps reads + network +
//  process-exec open; `(deny file-write*)` then removes ALL writes; targeted
//  `(allow file-write* (subpath …))` rules re-open exactly the repo, the temp
//  dirs, `/dev` (without which /dev/null and PTY writes fail and the agents can't
//  even start), and the agents' + toolchain's own config/cache dirs. node_modules
//  and .git live inside the project dir, so they're already covered. The allow
//  list is kept as tight as testing allows — verified live against Claude Code,
//  Codex, and Cursor (each starts cleanly, edits in-repo, installs, and is denied
//  an outside-repo write).
//

import Foundation
import Darwin

/// Builds the Zerro Seatbelt wrapping for a fenced-tier agent spawn. Pure /
/// data-only (apart from `realpath` canonicalization + a filesystem
/// availability probe); the runner owns the actual `Process`. `nonisolated`
/// throughout because the agent runner drives it from its private serial queue,
/// off the main actor (the module defaults to MainActor isolation).
enum DevSeatbeltSandbox {

    /// The system Seatbelt entry point. Absolute (GUI PATH is stripped) and
    /// fixed by the OS.
    nonisolated static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Hidden/dev safety valve (spec §5c optional): when this UserDefaults Bool is
    /// `true`, the wrapper is disabled and fenced tiers spawn the agent directly —
    /// an escape hatch so a bad profile can't brick Dev Mode during rollout.
    /// Default (key absent ⇒ `false`) = wrapper ON. No UI; resettable via the
    /// dev-settings reset path (see `PreferencesStore`).
    nonisolated static let wrapperDisabledDefaultsKey = "vf.dev.seatbeltWrapperDisabled"

    /// Whether the wrapper is currently disabled by the hidden safety valve.
    /// Reads `UserDefaults` (injectable for tests); default `false` ⇒ wrapper ON.
    nonisolated static func isWrapperDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: wrapperDisabledDefaultsKey)
    }

    /// Whether `/usr/bin/sandbox-exec` exists and is executable. The runner calls
    /// this BEFORE a fenced spawn and FAILS CLOSED if it's false — it must never
    /// silently fall back to an unsandboxed spawn (that would defeat the fence).
    nonisolated static func isAvailable(fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: sandboxExecPath)
    }

    /// The spawn the runner should actually execute for a fenced tier: run
    /// `/usr/bin/sandbox-exec` with the generated profile, then the agent's
    /// ABSOLUTE path and its existing args. The agent sees exactly its own argv
    /// (sandbox-exec exec's into it in the same PID, inheriting stdin/stdout/
    /// stderr + cwd), so stdin prompt delivery and stream-json parsing are
    /// unaffected.
    ///
    /// argv shape:
    ///   /usr/bin/sandbox-exec  -p <profile>  <agent-abs-path>  <agent args…>
    ///
    /// `proxyPort` (§8 Phase 3): when non-nil, the profile ALSO locks down network
    /// egress to that single loopback port (the Dev network filter proxy) — every
    /// other IP destination, including a user's local DB, is denied. nil keeps
    /// network open (Phase 2 behavior / network-filter valve off).
    nonisolated static func wrap(
        executableURL agent: URL,
        arguments: [String],
        projectDirectory: URL,
        proxyPort: UInt16? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        temporaryDirectory: String? = ProcessInfo.processInfo.environment["TMPDIR"]
    ) -> WrappedInvocation {
        let prof = profile(
            projectDirectory: projectDirectory, proxyPort: proxyPort, home: home,
            temporaryDirectory: temporaryDirectory)
        // `-p` takes the profile as an inline STRING argument (no temp file to
        // manage / clean up). Everything after the agent path is the agent's argv.
        let argv = ["-p", prof, agent.path] + arguments
        return WrappedInvocation(
            executableURL: URL(fileURLWithPath: sandboxExecPath), arguments: argv)
    }

    /// The result of `wrap`: the binary to spawn (`sandbox-exec`) and its full argv.
    struct WrappedInvocation: Equatable, Sendable {
        let executableURL: URL
        let arguments: [String]
    }

    // MARK: - Profile

    /// Generate the Seatbelt profile that confines file-writes to the project
    /// (plus temp + `/dev` + the agents'/toolchain's own state dirs) and — when
    /// `proxyPort` is given (§8 Phase 3) — locks network egress to that single
    /// loopback port. Paths are canonicalized (realpath) and escaped.
    /// `home`/`temporaryDirectory`/`proxyPort` are injectable for tests.
    nonisolated static func profile(
        projectDirectory: URL,
        proxyPort: UInt16? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        temporaryDirectory: String? = ProcessInfo.processInfo.environment["TMPDIR"]
    ) -> String {
        let project = canonicalize(projectDirectory.path)

        var lines: [String] = [
            "(version 1)",
            // Permissive base: reads, network, process-exec, mach lookups, … all
            // stay OPEN. We narrow ONLY file-writes below.
            "(allow default)",
            "(deny file-write*)",
            // The repo itself — the only place edits are meant to land (node_modules
            // and .git are inside it, so they're covered).
            allowWrite([project]),
        ]

        // $TMPDIR (canonicalized). Usually under /private/var/folders (also allowed
        // below) but kept explicit since TMPDIR can be relocated. Omitted if empty
        // — an empty `(subpath "")` is a hard `sandbox-exec` parse error.
        if let tmp = temporaryDirectory.map(canonicalize), !tmp.isEmpty {
            lines.append(allowWrite([tmp]))
        }

        // The standard temp roots + the canonical forms of /tmp and /var.
        lines.append(allowWrite(["/private/tmp", "/private/var/folders", "/tmp"]))

        // /dev is REQUIRED: without write access to /dev/null, /dev/tty, PTYs, …
        // node/npm and the agents fail immediately on startup. Device nodes aren't
        // a filesystem-escape surface, so this doesn't weaken "no writes outside
        // the repo".
        lines.append(allowWrite(["/dev"]))

        // The agents' + toolchain's own config/cache/state dirs — what they
        // legitimately write outside the repo (session logs, npm cache, …). Live-
        // verified as the tight minimum that lets all three start cleanly.
        if !home.isEmpty {
            lines.append(allowWrite([
                "\(home)/.claude", "\(home)/.codex", "\(home)/.cursor",
            ]))
            lines.append(allowWrite([
                "\(home)/.npm", "\(home)/.cache", "\(home)/Library/Caches",
            ]))
        }

        // §8 egress lockdown (network filter ON): deny ALL outbound IP traffic
        // EXCEPT to the loopback filter proxy's port. This is scoped to `(remote
        // ip)`, so unix-domain sockets stay open (the agent needs them to start —
        // mDNSResponder, logging, …); only IP egress is restricted. A user's LOCAL
        // service on another port (e.g. a DB on 127.0.0.1:5432) is therefore also
        // denied — the agent's only network path is THROUGH the proxy, which
        // host-allowlists. Seatbelt's `remote ip` host must be `*` or `localhost`,
        // so the rule is `localhost:<port>` (covers 127.0.0.1 / ::1 loopback). The
        // agent passes hostnames to the proxy, so it needs no DNS — UDP/53 stays
        // denied (no DNS-tunnel residual). The Zerro dev server runs OUTSIDE the
        // sandbox, so the agent never needs localhost access to it.
        if let proxyPort {
            lines.append("(deny network-outbound (remote ip))")
            lines.append("(allow network-outbound (remote ip \"localhost:\(proxyPort)\"))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// One `(allow file-write* (subpath "…") …)` rule over the given paths, each
    /// escaped. Empty paths are dropped; an all-empty input yields no rule.
    nonisolated private static func allowWrite(_ paths: [String]) -> String {
        let clauses = paths
            .filter { !$0.isEmpty }
            .map { "(subpath \"\(escape($0))\")" }
        guard !clauses.isEmpty else { return "" }
        return "(allow file-write* " + clauses.joined(separator: " ") + ")"
    }

    /// Escape a path for a Seatbelt TinyScheme string literal: backslash first,
    /// then double-quote. Spaces and parens are safe INSIDE the quotes (the
    /// profile rides as a single argv element via `-p`, so no shell is involved).
    nonisolated private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Resolve a path to its canonical, symlink-free form (realpath) so the
    /// `subpath` rules match the OS's view — e.g. /tmp → /private/tmp, $TMPDIR →
    /// /private/var/folders/…. Falls back to a symlink-resolved standardization if
    /// realpath fails (e.g. the path doesn't exist yet — shouldn't happen for the
    /// project dir or $TMPDIR).
    nonisolated private static func canonicalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
