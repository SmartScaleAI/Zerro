//
//  DevAgentBinaryResolver.swift
//  Zerro
//
//  Resolves a Dev Mode agent CLI to its ABSOLUTE binary path. This is
//  load-bearing for spawning (design §11, "CLI spawn plumbing"): GUI-launched
//  macOS apps inherit a stripped PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so
//  `claude` / `node` / `cursor-agent` won't be found by bare name.
//
//  Strategy (two layers, first hit wins):
//    1. Ask the user's shell — `/bin/zsh -ilc 'command -v <name>'`. INTERACTIVE
//       (`-i`) as well as login (`-l`) so it sources `.zshrc`, where version
//       managers (nvm, asdf) and npm-global prefixes actually put things on
//       PATH — a non-interactive login shell misses those.
//    2. Fallback — probe well-known install dirs directly (Homebrew, npm
//       global, ~/.local/bin), for the case where the shell probe returns
//       nothing (unusual shells, locked-down profiles).
//
//  Detection is SLOW (an interactive shell sources the user's whole profile),
//  so callers must run `resolve` OFF the main thread (see `DevAgentDetection`,
//  which warms it on a background task). Results are cached for the launch.
//
//  Non-sandboxed (`ENABLE_APP_SANDBOX = NO`), so spawning the shell and reading
//  the user's tooling is permitted (design §11, Distribution). Marked
//  `nonisolated` (the module defaults to MainActor isolation) precisely so the
//  blocking probe can run off the main actor.
//

import Foundation
import os

enum DevAgentBinaryResolver {

    /// Cache keyed by executable name. `URL?` (not `URL`) is cached so a known
    /// "not installed" result is also memoized — we don't re-probe a missing
    /// tool. Guarded by a lock so the resolver stays callable from any
    /// isolation (it's invoked from a background task).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL?] = [:]
    /// The login-shell PATH captured during a lookup, reused for the agent
    /// spawn environment so a version-manager `node` dir (nvm/asdf) is present
    /// (a Node CLI can be detected-installed yet fail to spawn without it).
    nonisolated(unsafe) private static var loginPATH: String?

    /// Absolute path to `name`, or nil if it isn't installed / resolvable.
    /// Result is cached for the process lifetime. BLOCKING — call off-main.
    nonisolated static func resolve(_ name: String) -> URL? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = runShellLookup(name) ?? probeKnownLocations(name)

        lock.lock()
        cache[name] = resolved
        lock.unlock()
        return resolved
    }

    /// The login-shell PATH captured by the last successful lookup, or nil if
    /// no lookup has run yet. Reused by the agent runner's spawn environment.
    /// Never blocks — it returns only what a prior `resolve` already captured
    /// (warm detection off-main populates it before any dispatch).
    nonisolated static func cachedLoginShellPATH() -> String? {
        lock.lock(); defer { lock.unlock() }
        return loginPATH
    }

    /// Test/diagnostics seam: forget cached results so a re-detect runs.
    nonisolated static func resetCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        loginPATH = nil
    }

    // MARK: - Layer 1: shell probe

    /// `/bin/zsh -ilc …` — an interactive login shell that sources the user's
    /// full profile, so `name` resolves against their real PATH (nvm, asdf,
    /// Homebrew, npm-global). A single probe captures BOTH the resolved binary
    /// path AND `$PATH` (cached for the spawn environment) — `command -v` prints
    /// the path (empty when not found), and a sentinel separates it from PATH.
    nonisolated private static func runShellLookup(_ name: String) -> URL? {
        let sentinel = "__ZERRO_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `name` is an internal literal ("claude"), never user input — no shell
        // injection surface. `|| true` keeps the shell exiting 0 so the trailing
        // PATH printf always runs even when the binary isn't found.
        process.arguments = ["-ilc", "command -v '\(name)' || true; printf '%s' '\(sentinel)'; printf '%s' \"$PATH\""]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // swallow profile / "not found" chatter

        do {
            try process.run()
        } catch {
            Log.dev.error("DevAgent binary lookup failed to spawn for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: sentinel)

        // Capture $PATH (the section after the sentinel) for the spawn env.
        if parts.count > 1 {
            let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                lock.lock(); loginPATH = path; lock.unlock()
            }
        }

        // The lookup section (before the sentinel) may carry profile noise; take
        // the first line that's an absolute path to a real executable.
        let lookupSection = parts.first ?? ""
        for line in lookupSection.split(whereSeparator: \.isNewline) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if let url = validateExecutable(candidate) { return url }
        }
        return nil
    }

    // MARK: - Layer 2: known-location fallback

    /// Probe well-known install directories directly when the shell probe comes
    /// up empty. Covers Homebrew (Apple Silicon + Intel), npm global prefixes,
    /// and the XDG-style `~/.local/bin`.
    nonisolated private static func probeKnownLocations(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [
            "/opt/homebrew/bin",            // Homebrew, Apple Silicon
            "/usr/local/bin",               // Homebrew, Intel / common installs
            "\(home)/.local/bin",           // pipx / XDG user installs
            "\(home)/.npm-global/bin",      // npm global prefix override
            "\(home)/.npm-packages/bin",    // another common npm prefix
        ]
        for dir in dirs {
            if let url = validateExecutable("\(dir)/\(name)") { return url }
        }
        return nil
    }

    // MARK: - Validation

    /// A candidate is usable only if it's an absolute path to an existing,
    /// executable regular file — `command -v` can also echo a shell builtin /
    /// alias / function name (not a path), which we reject here.
    nonisolated private static func validateExecutable(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}
