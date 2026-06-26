//
//  DevClaudeNativeSandbox.swift
//  Zerro
//
//  Dev Mode — §5c filesystem/network confinement for CLAUDE CODE, via Claude
//  Code's OWN built-in sandbox instead of Zerro's `sandbox-exec` wrapper
//  (`DevSeatbeltSandbox`). This is the `.claudeNative` confinement mode; Codex and
//  Cursor keep `.zerroSeatbelt` (see `DevAgentConfinement`).
//
//  ── Why native, not sandbox-exec ────────────────────────────────────────────
//  Claude Code authenticates via the macOS Keychain (the `Claude Code-credentials`
//  login item). When Zerro (a GUI app) wraps the whole `claude` process in
//  `sandbox-exec`, securityd denies the sandboxed child access to that item → the
//  agent gets no token → its own request 401s, and earlier a credential "lift"
//  attempt surfaced a scary cross-app Keychain password prompt. Claude Code's
//  BUILT-IN sandbox instead confines ONLY the Bash tool + its child processes; the
//  main `claude` process stays UNSANDBOXED, so it reads the Keychain and
//  authenticates with no prompt. The trade: the built-in sandbox does NOT cover
//  the Edit/Write file tools (they run in the main process) — so those are fenced
//  with Claude Code PERMISSION RULES instead (see `settingsJSON`).
//
//  ── What this builds ────────────────────────────────────────────────────────
//  A TRANSIENT `--settings` JSON file (written per run, deleted in a `defer` by
//  the runner) that, for a FENCED Claude run:
//    • enables the native sandbox, fail-closed (`failIfUnavailable`), with NO
//      escape-via-unsandboxed-retry (`allowUnsandboxedCommands:false`);
//    • allowlists network egress to `DevNetworkAllowlist.production` (the same
//      single source of truth the §8 proxy uses) and permits localhost binding so
//      a sandboxed dev server can still listen;
//    • allowlists filesystem WRITES to the repo + the toolchain cache/temp dirs
//      `npm install` needs (mirrors the Seatbelt profile's allow list);
//    • runs the agent in `dontAsk` permission mode with `allow` scoped so in-repo
//      Edit/Write AUTO-APPLY while out-of-repo ones AUTO-DENY (no prompt, no hang);
//    • adds a small defense-in-depth `deny`/`denyRead` over known-sensitive paths
//      (~/.ssh, cloud creds) so neither the Read tool nor a Bash subprocess can
//      read them (reads are otherwise left open, matching the Seatbelt posture).
//  Plus the argv flags that make `--settings` authoritative: `--permission-mode
//  dontAsk` (replacing the registry's `bypassPermissions`, which disables the rules
//  we now rely on) and `--setting-sources ""` (load ZERO user/project/local
//  settings, so a hostile in-repo `.claude/settings.json` can't UNION a broad
//  `allow:["Write"]` back in and re-open out-of-repo writes).
//
//  Everything here was live-verified against Claude Code 2.1.179 (June 2026): the
//  agent authenticates with no Keychain prompt; a shell write outside cwd is OS-
//  blocked; an Edit/Write outside the repo auto-denies; `npm install` + a build +
//  a dev server all work; edits land in the real repo so the live preview sees
//  them. If any of this can't be set up, the runner DEGRADES to today's unwrapped
//  Claude (never a 401, crash, or hang) — see `DevAgentRunner.run`.
//
//  ── Known limitations vs Zerro's Seatbelt wrapper (live-verified) ────────────
//  Unlike the Seatbelt path (a fully Zerro-owned profile, immune to repo content),
//  Claude Code's native sandbox + permission engine ALWAYS read the TARGET repo's
//  own `.claude/settings.json` `sandbox.*` and `deny` rules from cwd — and
//  `--setting-sources ""` does NOT suppress those two (it only excludes project/
//  user/local `allow` rules; verified Q1). Consequences:
//   • `allow` widening is closed: a hostile repo `allow:["Write"]` does NOT re-open
//     out-of-repo Edit/Write (excluded by `--setting-sources ""`).
//   • Residual A (functional): a repo whose own `.claude` carries a PATHOLOGICAL
//     broad write-deny (e.g. `deny:["Edit(//**)"]`) translates to a sandbox deny
//     that blocks even in-repo Bash writes. No real repo does this (it would break
//     the owner's normal Claude usage); realistic `.claude` (allow rules, hooks,
//     narrow denies) is unaffected — verified.
//   • Residual B (security): a hostile repo `.claude` can WIDEN the OS sandbox
//     (its `sandbox.filesystem.allowWrite` unions into ours). This is strictly NO
//     WORSE than today's main behavior (Claude runs fully UNWRAPPED), and the Dev
//     Mode target is a user-chosen repo, not arbitrary code; §5b env-scrub + §5a
//     no-MCP + the git checkpoint remain as additional containment.
//  Both residuals are inherent to Claude reading repo-local settings and cannot be
//  overridden by a transient `--settings` file alone.
//

import Foundation
import Darwin

/// Builds the transient `--settings` confinement for a fenced-tier Claude Code
/// spawn (`.claudeNative`). Pure/data-only apart from `realpath` canonicalization
/// and the one temp-file write (`writeTransientSettings`); the runner owns the
/// `Process` and the temp file's `defer` cleanup. `nonisolated` throughout — the
/// agent runner drives it from its private serial queue, off the main actor.
enum DevClaudeNativeSandbox {

    // MARK: - Safety valve

    /// Hidden/dev safety valve (mirrors `DevSeatbeltSandbox.wrapperDisabledDefaultsKey`):
    /// when this UserDefaults Bool is `true`, the native sandbox is NOT configured
    /// and fenced Claude runs unwrapped (today's behavior) — an escape hatch so a
    /// bad settings build can't brick Dev Mode during rollout. Default (key absent
    /// ⇒ `false`) = native sandbox ON. No UI.
    nonisolated static let disabledDefaultsKey = "vf.dev.claudeNativeSandboxDisabled"

    /// Whether the native sandbox is disabled by the hidden valve. Injectable for
    /// tests; default `false` ⇒ native sandbox ON.
    nonisolated static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: disabledDefaultsKey)
    }

    // MARK: - Minimum version gate

    /// The minimum Claude Code version that supports everything the `.claudeNative`
    /// path passes: `--setting-sources`, `--settings`, `--permission-mode dontAsk`,
    /// and the `sandbox.*` settings keys. An OLDER claude rejects an unknown flag
    /// and exits non-zero — a hard "Couldn't apply changes" failure — so below this
    /// floor the runner degrades to UNWRAPPED (today's main behavior) instead.
    ///
    /// CONSERVATIVELY pinned to 2.1.179, the version this was end-to-end validated
    /// against (June 2026). `--setting-sources` + base `sandbox.enabled` predate it,
    /// but the exact introduction version isn't pinned in the changelog — a
    /// too-LOW floor risks a hard failure on a version that lacks a flag, whereas a
    /// too-HIGH floor only makes a few installs degrade to the (safe) unwrapped
    /// path. Lower this once the true introduction version is confirmed.
    nonisolated static let minimumSupportedVersion = (major: 2, minor: 1, patch: 179)

    /// `minimumSupportedVersion` as a display/telemetry string (e.g. "2.1.179").
    nonisolated static var minimumSupportedVersionString: String {
        "\(minimumSupportedVersion.major).\(minimumSupportedVersion.minor).\(minimumSupportedVersion.patch)"
    }

    /// Extract the first `<major>.<minor>.<patch>` triple from a `claude --version`
    /// string (e.g. "2.1.179 (Claude Code)" → (2,1,179)). nil if absent/unparseable.
    nonisolated static func parseVersion(_ raw: String?) -> (major: Int, minor: Int, patch: Int)? {
        guard let raw, let m = raw.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3) else { return nil }
        return (major, minor, patch)
    }

    /// Whether a detected `claude --version` string is new enough for the native
    /// sandbox path. An UNDETECTABLE version (nil / unparseable — probe failed,
    /// timed out, or output changed) returns `false` → the runner degrades to
    /// unwrapped, never a hard failure. Tuple comparison is element-wise major→patch.
    nonisolated static func supportsNativeSandbox(version raw: String?) -> Bool {
        guard let v = parseVersion(raw) else { return false }
        return v >= minimumSupportedVersion
    }

    // MARK: - Sensitive paths (defense-in-depth read deny)

    /// Known-sensitive credential dirs that NEITHER the Read tool NOR a sandboxed
    /// Bash subprocess may read. Reads are otherwise left OPEN (parity with the
    /// Seatbelt profile, which only denies writes) — we deny generally nothing and
    /// these specific secret stores everything. Home-relative (`~/…`); Claude
    /// expands `~` via the agent's (kept) HOME. `~/.npmrc` is deliberately NOT here
    /// — npm reads it during installs, and blocking it would break the headline
    /// dev-command path; the network allowlist + no-WebFetch already bound exfil.
    nonisolated static let sensitiveReadDenyPaths: [String] = [
        "~/.ssh", "~/.aws", "~/.gnupg",
        "~/.config/gh", "~/.config/gcloud", "~/.azure", "~/.kube",
    ]

    /// Filesystem WRITE allowlist beyond the repo (cwd is writable by default): the
    /// toolchain cache/temp dirs `npm install`, builds, and the agents legitimately
    /// write outside the project. Mirrors `DevSeatbeltSandbox`'s allow list.
    nonisolated static let toolchainWritePaths: [String] = [
        "~/.npm", "~/.cache", "~/Library/Caches",
        "/tmp", "/private/tmp", "/private/var/folders",
    ]

    // MARK: - Argv

    /// The argv transform for a `.claudeNative` fenced spawn. Given the registry's
    /// base argv (which carries `--permission-mode bypassPermissions` — the
    /// allow-commands posture used by `.unrestricted`), STRIP that permission-mode
    /// pair (bypass would disable the permission rules we now rely on) and append
    /// the native-confinement flags:
    ///   • `--permission-mode dontAsk` — in-repo allow-listed tools auto-apply,
    ///     everything else auto-DENIES (no prompt, no hang headless);
    ///   • `--setting-sources ""` — load ZERO user/project/local settings so a
    ///     hostile in-repo `.claude/settings.json` can't union a broad allow back
    ///     in (only our `--settings` file + admin-managed policy apply);
    ///   • `--settings <file>` — our transient sandbox + permission config.
    nonisolated static func arguments(base: [String], settingsFilePath: String) -> [String] {
        var stripped: [String] = []
        stripped.reserveCapacity(base.count)
        var i = base.startIndex
        while i < base.endIndex {
            if base[i] == "--permission-mode", base.index(after: i) < base.endIndex {
                // Drop the flag AND its value (the registry's bypassPermissions).
                i = base.index(i, offsetBy: 2)
                continue
            }
            stripped.append(base[i])
            i = base.index(after: i)
        }
        return stripped + [
            "--permission-mode", "dontAsk",
            "--setting-sources", "",
            "--settings", settingsFilePath,
        ]
    }

    // MARK: - Settings JSON

    /// Build the transient settings JSON enabling Claude Code's native sandbox +
    /// permission fence for a fenced run confined to `projectDirectory`. Pure —
    /// the runner writes it to a temp file. `home` / `allowlist` are injectable for
    /// tests. Throws only if JSON encoding fails (it doesn't, in practice).
    nonisolated static func settingsJSON(
        projectDirectory: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        allowlist: DevNetworkAllowlist = .production
    ) throws -> String {
        let project = canonicalize(projectDirectory.path)

        // Each registrable domain plus a leading-wildcard for its subdomains
        // (`registry.npmjs.org`, CDN edges, sharded agent backends, …).
        var domains: [String] = []
        for d in allowlist.domains { domains.append(d); domains.append("*." + d) }

        // WRITE allowlist: the repo itself (canonical, OS-absolute) + the toolchain
        // cache/temp dirs. cwd is writable by the native sandbox without listing,
        // but the repo is listed explicitly for robustness (parity with Seatbelt).
        let allowWrite = [project] + toolchainWritePaths

        let document = SettingsDocument(
            sandbox: SandboxConfig(
                network: NetworkConfig(allowedDomains: domains),
                filesystem: FilesystemConfig(
                    allowWrite: allowWrite,
                    denyRead: sensitiveReadDenyPaths)),
            permissions: PermissionsConfig(
                // In-repo Edit/Write auto-apply (scoped to the canonical repo path
                // with the `//` OS-absolute prefix Claude's path rules require — a
                // single `/` is project-relative and would never match). Bash is
                // allowed wholesale: the native sandbox is its containment. Read is
                // open (parity); the sensitive-path denies below override it.
                allow: [
                    "Bash", "Read",
                    "Edit(\(absoluteGlob(project)))",
                    "Write(\(absoluteGlob(project)))",
                ],
                // Deny wins over allow, and survives because we load no user/project
                // settings — so these block the Read tool from the same secret
                // stores `denyRead` blocks for Bash.
                deny: sensitiveReadDenyPaths.map { "Read(\($0)/**)" }))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    /// Build the settings JSON and write it to a unique temp file, returning its
    /// URL. The runner appends `--settings <url.path>` to the spawn argv and
    /// `defer`s `removeItem(at:)` so it's deleted on EVERY exit path (success,
    /// failure, cancel, quit). Throws on encode/write failure → the runner degrades
    /// to unwrapped Claude.
    nonisolated static func writeTransientSettings(
        projectDirectory: URL,
        directory: URL = FileManager.default.temporaryDirectory,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        allowlist: DevNetworkAllowlist = .production
    ) throws -> URL {
        let json = try settingsJSON(
            projectDirectory: projectDirectory, home: home, allowlist: allowlist)
        // NOT a `zerro-` prefix: a parallel test's WorkingDirectory.sweep() deletes
        // every `zerro-*` temp entry, which could remove this mid-run.
        let url = directory.appendingPathComponent(
            "dev-claude-settings-\(UUID().uuidString).json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    /// A `//`-prefixed OS-absolute recursive glob for a Claude Code path rule.
    /// `path` is already OS-absolute (leading `/`); prefixing one more `/` yields
    /// the `//absolute` form Claude requires (a single `/` is project-relative).
    nonisolated static func absoluteGlob(_ path: String) -> String {
        "/" + path + "/**"
    }

    /// Resolve a path to its canonical, symlink-free form (realpath) so the rules
    /// match the OS's view — e.g. /tmp → /private/tmp. Falls back to a symlink-
    /// resolved standardization if realpath fails (e.g. the path doesn't exist yet).
    nonisolated static func canonicalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Codable shapes (the exact Claude Code settings schema)
    //
    // `nonisolated` because the module defaults to MainActor isolation but
    // `settingsJSON` (nonisolated) encodes these off the main actor — without it the
    // synthesized `Encodable` conformance is main-actor-isolated (a Swift 6 error).

    nonisolated private struct SettingsDocument: Encodable {
        let sandbox: SandboxConfig
        let permissions: PermissionsConfig
    }

    nonisolated private struct SandboxConfig: Encodable {
        let enabled = true
        let failIfUnavailable = true
        let allowUnsandboxedCommands = false
        let network: NetworkConfig
        let filesystem: FilesystemConfig
    }

    nonisolated private struct NetworkConfig: Encodable {
        let allowLocalBinding = true
        let allowedDomains: [String]
    }

    nonisolated private struct FilesystemConfig: Encodable {
        let allowWrite: [String]
        let denyRead: [String]
    }

    nonisolated private struct PermissionsConfig: Encodable {
        let defaultMode = "dontAsk"
        let allow: [String]
        let deny: [String]
    }
}
