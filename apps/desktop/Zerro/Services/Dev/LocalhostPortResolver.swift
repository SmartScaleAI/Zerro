//
//  LocalhostPortResolver.swift
//  Zerro
//
//  Dev Mode (Phase 3) — LIVE `localhost:<port> → project folder` resolution.
//
//  THE PROBLEM THIS SOLVES: the learned `devProjectByPort` map (PreferencesStore)
//  is only ever taught by a MANUAL folder pick, so once a port points at the
//  wrong/stale folder it can never self-correct — the auto-match confidently
//  fills in last-week's project. There was no mechanism that asks "which project
//  is ACTUALLY serving this port right now?". This is it.
//
//  HOW: find the process LISTENING on the port and derive its project root from
//  that process's working directory:
//    1. `lsof -nP -iTCP:<port> -sTCP:LISTEN -t`  → the listener pid(s).
//    2. `lsof -a -p <pid> -d cwd -Fn`            → that pid's cwd.
//    3. Walk up from the cwd to the nearest project-root marker (`.git` first —
//       Dev Mode needs a git repo — then common manifests), rejecting a cwd that
//       is the home dir or `/` (a server launched from a shell sitting at $HOME
//       must NOT resolve the whole home folder as the "project").
//  The live answer is authoritative; the learned map is a fallback/cache the
//  caller refreshes whenever live resolution disagrees.
//
//  BEST-EFFORT + OFF-MAIN + BOUNDED, exactly like `BrowserURLReader`: this runs
//  on the hotkey→overlay path, so the async entry point is watchdog-bounded and
//  EVERY failure mode (no `lsof`, no listener, a home/root cwd, a spawn error, a
//  timeout) resolves to nil → the caller falls back to the cache, then to the
//  last-used folder. It can never block or slow recording, and a miss never
//  clears an already-set folder.
//
//  The pure cores — pid parsing, cwd-field parsing, the project-root walk — take
//  their I/O injected (fixture strings / a `fileExists` stub) so they're unit-
//  tested without ever touching a real socket or shelling out (see
//  `LocalhostAutoMatchTests`). Marked `nonisolated` (the module defaults to
//  MainActor isolation) so the blocking `lsof` work runs off the main actor.
//

import Foundation
import os

enum LocalhostPortResolver {

    // MARK: - Project-root markers

    /// The strongest "repo root" signal. Checked across the WHOLE ancestor chain
    /// before any secondary marker, because Dev Mode's checkpoint/revert needs the
    /// git work-tree root — a dev server started in `repo/packages/web` must
    /// resolve to `repo`, not the sub-package.
    static let primaryMarker = ".git"

    /// Fallback markers when no `.git` exists anywhere up the chain (a non-git
    /// project). The NEAREST ancestor carrying one of these is used.
    static let secondaryMarkers = [
        "package.json", "pnpm-workspace.yaml", "Cargo.toml", "go.mod",
        "pyproject.toml", "Package.swift",
    ]

    // MARK: - Async entry point (off-main, bounded)

    /// The project folder of the process serving `port`, or nil. Runs the blocking
    /// `lsof` work OFF-MAIN and races it against a `timeout` watchdog so a hung
    /// `lsof` can never stall the overlay (mirrors `BrowserURLReader`). Fail-open:
    /// any error / no listener / a home-or-root cwd → nil.
    nonisolated static func resolveProjectFolder(forPort port: Int, timeout: TimeInterval = 1.0) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: URL?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            // The blocking lsof probe runs on a background thread…
            DispatchQueue.global(qos: .userInitiated).async {
                finish(resolveProjectFolderBlocking(forPort: port))
            }
            // …raced against a watchdog on a separate thread, so a stuck `lsof`
            // can't stall the caller. The abandoned probe completes harmlessly
            // later (its result dropped by the once-only `finish`).
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }

    /// BLOCKING (call off-main): listener pid → its cwd → project root. nil on any
    /// missing step.
    nonisolated static func resolveProjectFolderBlocking(forPort port: Int) -> URL? {
        guard let pid = listenerPID(forPort: port) else { return nil }
        guard let cwd = cwd(forPID: pid) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = projectRoot(forCWDPath: cwd, homePath: home)
        if root == nil {
            Log.dev.notice("Localhost port \(port, privacy: .public): listener cwd had no project root (home/root cwd or no marker)")
        }
        return root
    }

    // MARK: - Pure parsing (unit-tested with fixtures)

    /// First valid pid from `lsof … -t` output (newline-separated pids; multiple
    /// when one process listens on both IPv4 and IPv6, or several processes share
    /// the port). We take the first — any listener's cwd resolves the same project.
    static func firstPID(fromListenerOutput output: String) -> Int32? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let pid = Int32(trimmed), pid > 0 { return pid }
        }
        return nil
    }

    /// The cwd path from `lsof -d cwd -Fn` field output. In `-F` mode lsof emits
    /// one field per line prefixed by a type char (`p<pid>`, `fcwd`, `n<path>`);
    /// the cwd is the `n` (name) field. Returns the first absolute `n` path.
    static func cwdPath(fromFieldOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    /// Walk up from `rawCWD` to the project root: the NEAREST ancestor containing
    /// `.git` (preferred — the git work-tree root), else the nearest ancestor
    /// containing a secondary marker. Returns nil when the cwd is the home dir or
    /// `/`, or when no marker is found up the chain — those are treated as a MISS
    /// so a server launched from a bare shell never resolves `$HOME` as a project.
    ///
    /// Pure: `fileExists` is injected so the walk is unit-tested over fixture path
    /// sets without touching the filesystem.
    static func projectRoot(
        forCWDPath rawCWD: String,
        homePath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let cwd = normalize(rawCWD)
        let home = normalize(homePath)
        guard cwd.hasPrefix("/") else { return nil }

        var dir = cwd
        var nearestSecondary: String?
        // Stop BEFORE home / `/`: a cwd at (or above) home is never a project.
        while dir != "/" && dir != home && !dir.isEmpty {
            if fileExists(dir + "/" + primaryMarker) {
                return URL(fileURLWithPath: dir, isDirectory: true)
            }
            if nearestSecondary == nil,
               secondaryMarkers.contains(where: { fileExists(dir + "/" + $0) }) {
                nearestSecondary = dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }   // reached the root; guard against a no-op loop
            dir = parent
        }
        // No `.git` anywhere up the chain → fall back to the nearest manifest dir.
        if let nearestSecondary { return URL(fileURLWithPath: nearestSecondary, isDirectory: true) }
        return nil
    }

    /// Whether an auto-matched project folder is still safe to ADOPT (G-06): the
    /// path exists, is a directory, and carries the primary marker (`.git` — a
    /// dir normally, a FILE for worktrees/submodules, so the marker check is a
    /// plain existence test). Guards the adoption site against a learned
    /// `devProjectByPort` entry pointing at a deleted/moved folder — a stale
    /// path must fall back to manual selection, never be silently adopted.
    ///
    /// Pure: `directoryExists`/`fileExists` are injected so it's unit-tested
    /// over fixture path sets without touching the filesystem.
    static func isValidProjectFolder(
        _ folder: URL,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let path = normalize(folder.path)
        guard path.hasPrefix("/") else { return false }
        return directoryExists(path) && fileExists(path + "/" + primaryMarker)
    }

    /// Strip trailing slashes (except the root `/`) so path comparisons against
    /// `home` and the parent-walk terminator are exact.
    static func normalize(_ path: String) -> String {
        guard path != "/" else { return path }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - lsof plumbing (blocking)

    /// Standard macOS `lsof` location. Absolute (GUI apps inherit a stripped PATH).
    private static let lsofURL = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// The pid listening on `port`, or nil. `-nP` skips DNS/port-name lookups
    /// (faster, no network), `-sTCP:LISTEN` restricts to listeners, `-t` prints
    /// terse pid-only output.
    nonisolated private static func listenerPID(forPort port: Int) -> Int32? {
        guard let out = runLSOF(["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) else { return nil }
        return firstPID(fromListenerOutput: out)
    }

    /// The current working directory of `pid`, or nil. `-d cwd` selects only the
    /// cwd file descriptor; `-Fn` prints it in parseable field format.
    nonisolated private static func cwd(forPID pid: Int32) -> String? {
        guard let out = runLSOF(["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        return cwdPath(fromFieldOutput: out)
    }

    /// Run `lsof` with `arguments`, returning stdout or nil on any failure. stderr
    /// is drained and discarded. Reads stdout BEFORE `waitUntilExit` so a large
    /// output can't fill the pipe buffer and deadlock the child.
    nonisolated private static func runLSOF(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: lsofURL.path) else { return nil }
        let process = Process()
        process.executableURL = lsofURL
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            Log.dev.error("lsof spawn failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof exits 1 when it finds nothing (e.g. no listener on the port) — that
        // is a legitimate "no match", surfaced as empty/nil downstream, not an
        // error. Return whatever it printed.
        return String(data: outData, encoding: .utf8)
    }
}
