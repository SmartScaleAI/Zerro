//
//  DevAgentDetection.swift
//  Zerro
//
//  Async front for `DevAgentRegistry` detection. The registry's `all()` runs a
//  BLOCKING shell probe (interactive login shell → slow), so it must never run
//  on the hotkey→overlay path. This actor-isolated cache warms detection ONCE
//  on a background task and hands the result back on the main actor — callers
//  read the cached entries instead of resolving inline.
//
//  Usage contract:
//    • Only ever warmed when Dev Mode is (or becomes) active — a normal-mode
//      user (devModeEnabled == false who never toggles it on) never triggers
//      the shell probe, so the overlay path stays allocation-cheap for them.
//    • `warm(completion:)` is idempotent: the first call kicks the probe, later
//      calls (and calls after it finishes) get the cached result; a completion
//      passed before the probe finishes is invoked when it does, on the main
//      actor.
//

import Foundation

@MainActor
@Observable
final class DevAgentDetection {

    /// Shared so an app-launch warm and the overlay controller see the same
    /// cached result.
    static let shared = DevAgentDetection()

    enum Status: Equatable {
        case notStarted
        case detecting
        case done
    }

    private(set) var status: Status = .notStarted

    /// Detected agents (with `installed`/`absolutePath` populated). Empty until
    /// the first warm completes.
    private(set) var entries: [DevAgentEntry] = []

    /// Cursor's model list, fetched client-side from `cursor-agent models` during
    /// the same background warm (Cursor has no server manifest — Phase 2). Empty
    /// when cursor-agent isn't installed or the probe found nothing; the Model
    /// section then has no Cursor models to show. Read by
    /// `AgentModelManifestStore.models(forAgent:)` for the `.cursorCLI` source.
    private(set) var cursorModels: [AgentModel] = []

    /// Codex's model list, sourced client-side from its OWN per-account list —
    /// `~/.codex/models_cache.json` — during the same background warm (Phase 2).
    /// Codex is NOT served by the OpenAI manifest: a ChatGPT-account Codex uses
    /// its own slugs (e.g. `gpt-5.5`) and rejects the API codex ids. Empty when
    /// codex isn't installed / the cache is unreadable; read by
    /// `AgentModelManifestStore.models(forAgent:)` for the `.codexCLI` source.
    private(set) var codexModels: [AgentModel] = []

    /// Completions waiting on an in-flight probe.
    private var pending: [([DevAgentEntry]) -> Void] = []

    /// Cached lookup by id. nil until detection finishes.
    func entry(id: String) -> DevAgentEntry? {
        entries.first { $0.id == id }
    }

    /// Kick off detection if it hasn't run, then deliver the resolved entries
    /// to `completion` on the main actor — immediately if already done, or when
    /// the in-flight probe finishes. Safe to call repeatedly.
    func warm(completion: (([DevAgentEntry]) -> Void)? = nil) {
        switch status {
        case .done:
            completion?(entries)

        case .detecting:
            if let completion { pending.append(completion) }

        case .notStarted:
            status = .detecting
            if let completion { pending.append(completion) }
            // Run the blocking probes off the main actor. `DevAgentRegistry.all`
            // is `nonisolated`; entries are `Sendable`. Cursor's model list comes
            // from its own CLI (no server manifest) in the SAME background hop.
            Task.detached(priority: .utility) { [weak self] in
                let resolved = DevAgentRegistry.all()
                let cursor = DevAgentDetection.probeCursorModels()
                let codex = DevAgentDetection.probeCodexModels()
                await MainActor.run {
                    self?.finish(with: resolved, cursorModels: cursor, codexModels: codex)
                }
            }
        }
    }

    private func finish(with resolved: [DevAgentEntry], cursorModels: [AgentModel], codexModels: [AgentModel]) {
        entries = resolved
        self.cursorModels = cursorModels
        self.codexModels = codexModels
        status = .done
        let callbacks = pending
        pending.removeAll()
        for cb in callbacks { cb(resolved) }
    }

    // MARK: - Cursor models (client-side CLI)

    /// Probe `cursor-agent models` for Cursor's selectable model ids (Phase 2).
    /// Cursor has no server manifest, so its list is fetched from the CLI. Runs
    /// OFF the main actor (blocking `Process`), capped by a short watchdog, and
    /// degrades to `[]` on anything unexpected — a missing CLI, a non-zero exit,
    /// an unparseable format — so it can never break Dev Mode.
    ///
    /// OUTPUT FORMAT IS BEST-EFFORT / UNVERIFIED against a live cursor-agent
    /// (not installed on the build machine): we take each non-empty line's first
    /// whitespace token as the model id (`--model <id>`) and the cleaned line as
    /// the label, skipping obvious header/decoration lines. Tighten once verified
    /// against the installed CLI's real `cursor-agent models` output.
    nonisolated private static func probeCursorModels() -> [AgentModel] {
        guard let binary = DevAgentBinaryResolver.resolve("cursor-agent") else { return [] }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["models"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        if let path = DevAgentBinaryResolver.cachedLoginShellPATH(), !path.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            process.environment = env
        }

        do {
            try process.run()
        } catch {
            return []
        }
        // Watchdog: a `models` listing is fast; never let a hung CLI stall the
        // background warm. Kill after 5s and treat as no models.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parseCursorModels(text)
    }

    /// Parse `cursor-agent models` stdout into models. Defensive: one model per
    /// non-empty line, first token = id, line = label; de-duped, order preserved
    /// (the CLI is assumed to list newest/current first). Skips lines that look
    /// like headers/usage. Exposed `internal` for unit testing the parser.
    nonisolated static func parseCursorModels(_ text: String) -> [AgentModel] {
        var seen = Set<String>()
        var out: [AgentModel] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Strip a leading selection marker ("* ", "- ", "> ") the CLI may use
            // to flag the current model.
            let cleaned = line.replacingOccurrences(
                of: "^[*\\-•>]\\s+", with: "", options: .regularExpression
            )
            guard !cleaned.isEmpty else { continue }
            // Skip obvious non-model lines (headers / usage / blank decoration).
            let lower = cleaned.lowercased()
            if lower.hasPrefix("available") || lower.hasPrefix("usage")
                || lower.hasPrefix("models") || cleaned.hasPrefix("-") {
                continue
            }
            // First whitespace-delimited token is the model id.
            guard let idPart = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
                continue
            }
            let modelID = String(idPart)
            guard seen.insert(modelID).inserted else { continue }
            out.append(AgentModel(modelID: modelID, displayName: cleaned))
        }
        return out
    }

    // MARK: - Codex models (its own per-account cache)

    /// Read Codex's selectable models from its OWN cache `~/.codex/models_cache.json`
    /// (Phase 2). Codex has no `models` subcommand (verified against
    /// `codex --help`, codex-cli 0.140.0) and a ChatGPT-account Codex rejects the
    /// OpenAI API codex ids — so its account-accurate list lives in this cache,
    /// which the CLI itself refreshes. Pure file read (no spawn); degrades to `[]`
    /// on a missing/unreadable/garbage cache so it can never break Dev Mode. A
    /// bundled fallback is added by `AgentModelManifestStore` when this is empty.
    nonisolated private static func probeCodexModels() -> [AgentModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheURL = home.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return parseCodexModelsCache(data)
    }

    /// Parse Codex's `models_cache.json` into selectable models. Keeps only
    /// `visibility == "list"` entries (drops internal ones like `codex-auto-review`,
    /// which is `hide`), ordered by `priority` ascending (lower = higher priority
    /// = newer/better, so rank 0 is the default pick). Defensive: unknown shapes
    /// degrade to `[]`. Exposed `internal` for unit testing.
    nonisolated static func parseCodexModelsCache(_ data: Data) -> [AgentModel] {
        struct Cache: Decodable {
            struct Model: Decodable {
                let slug: String
                let displayName: String?
                let visibility: String?
                let priority: Int?
                enum CodingKeys: String, CodingKey {
                    case slug
                    case displayName = "display_name"
                    case visibility
                    case priority
                }
            }
            let models: [Model]
        }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return cache.models
            .filter { $0.visibility == "list" }
            .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
            .map { AgentModel(modelID: $0.slug, displayName: ($0.displayName?.isEmpty == false ? $0.displayName! : $0.slug)) }
    }
}
