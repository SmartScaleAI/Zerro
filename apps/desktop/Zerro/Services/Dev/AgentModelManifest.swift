//
//  AgentModelManifest.swift
//  Zerro
//
//  Dev Mode (Phase 2) — the app's half of the server-fetched coding-agent model
//  manifest. The `agent-models` Edge Function serves a current, self-updating
//  pinned list of models per provider (refreshed daily server-side); this store
//  fetches it at launch, caches it to disk, and resolves the models a given
//  agent can be launched with (`--model <id>`).
//
//  OFFLINE NEVER HARD-BREAKS the model picker — a three-step fallback chain:
//    live manifest  →  last cached (UserDefaults JSON)  →  a small BUNDLED
//    default list per provider (shipped in the binary).
//  `models(forProvider:)` is therefore ALWAYS non-empty, so the dev-settings
//  Model section and the `--model` resolution work on a plane / first launch.
//
//  Cursor is NOT here — its list has no server API we can call, so it's fetched
//  client-side from the `cursor-agent models` CLI (see `DevAgentDetection`).
//

import Foundation
import os

// MARK: - AgentModel

/// One selectable model for an agent's `--model` flag. `modelID` is the EXACT
/// string passed to the CLI (`--model <modelID>`); `displayName` is the menu
/// label. `Codable` so the manifest round-trips through the on-disk cache.
struct AgentModel: Identifiable, Equatable, Sendable, Codable {
    let modelID: String
    let displayName: String
    var id: String { modelID }
}

// MARK: - Agent → model source mapping

/// Where an agent's model list comes from. The server manifest backs Claude
/// Code (anthropic); Codex and Cursor source their lists CLIENT-SIDE from their
/// own per-account tools (a ChatGPT-account Codex / Cursor use their own slugs,
/// which the OpenAI API manifest doesn't match), so the OpenAI manifest is
/// retired. `.none` is an agent with no model picker (unknown / future).
enum AgentModelSource: Equatable, Sendable {
    /// A provider key in the `agent-models` manifest (currently "anthropic").
    case manifest(provider: String)
    /// Sourced from `~/.codex/models_cache.json` (see `DevAgentDetection`).
    case codexCLI
    /// Fetched from `cursor-agent models` client-side (see `DevAgentDetection`).
    case cursorCLI
    case none
}

enum AgentModelMapping {
    /// Map a registry agent id → its model source. The product decision:
    /// `claude-code → anthropic manifest`, `codex → its own per-account list`,
    /// `cursor → its CLI`. An unknown agent has no picker (its Model section
    /// stays empty).
    static func source(forAgent agentID: String) -> AgentModelSource {
        switch agentID {
        case DevAgentRegistry.claudeCodeID:  return .manifest(provider: "anthropic")
        case DevAgentRegistry.codexID:       return .codexCLI
        case DevAgentRegistry.cursorID:      return .cursorCLI
        default:                             return .none
        }
    }
}

// MARK: - Wire DTO (matches the `agent-models` function)

/// `{ providers: { anthropic: [{ model_id, display_name }], ... } }`. Only
/// `anthropic` is consumed now (OpenAI is retired — Codex sources its own list);
/// any other provider key in the body is simply ignored.
private struct AgentModelsManifestDTO: Decodable {
    struct Entry: Decodable {
        let modelID: String
        let displayName: String
        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case displayName = "display_name"
        }
    }
    struct Providers: Decodable {
        let anthropic: [Entry]?
    }
    let providers: Providers
}

// MARK: - AgentModelManifestStore

@MainActor
@Observable
final class AgentModelManifestStore {

    /// Shared so an app-launch warm and the overlay controller read the same
    /// resolved manifest.
    static let shared = AgentModelManifestStore()

    /// Active models per provider key ("anthropic" / "openai"), ordered
    /// newest-first (rank 0 = the default pick). Seeded from cache-or-bundled at
    /// init so it's never empty; replaced wholesale by a successful `warm()`.
    private(set) var providers: [String: [AgentModel]]

    // MARK: Dependencies

    private let transport: ManagedTransport
    private let defaults: UserDefaults
    /// UserDefaults key for the cached manifest JSON (non-secret).
    private static let cacheKey = "agent_models_manifest_v1"

    // MARK: Bundled fallback

    /// A small, current default list per manifest provider, shipped in the binary
    /// so the picker works offline on first launch (before any fetch/cache).
    /// Verified against the live provider 2026-06-18; refreshed naturally the
    /// moment a live fetch or cache lands, so these only need to be "recent
    /// enough". Anthropic only — OpenAI is retired (Codex sources its own list).
    static let bundled: [String: [AgentModel]] = [
        "anthropic": [
            AgentModel(modelID: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
            AgentModel(modelID: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        ],
    ]

    // MARK: Init

    init(transport: ManagedTransport = URLSessionManagedTransport(), defaults: UserDefaults = .standard) {
        self.transport = transport
        self.defaults = defaults
        // Seed from the on-disk cache so the picker is populated at launch before
        // the async fetch lands; fall back to the bundled defaults when there's
        // no cache yet (first run / cleared defaults). Never empty.
        self.providers = Self.loadCache(from: defaults) ?? Self.bundled
    }

    // MARK: Resolution

    /// The models for a provider key, ALWAYS non-empty: live/cached if present,
    /// else the bundled defaults. The list is ordered newest-first (rank 0 first).
    func models(forProvider provider: String) -> [AgentModel] {
        if let live = providers[provider], !live.isEmpty { return live }
        return Self.bundled[provider] ?? []
    }

    /// The models a given AGENT can be launched with, resolving its source. A
    /// manifest agent (Claude Code) reads this store; Codex and Cursor read their
    /// own per-account lists from `DevAgentDetection`; `.none` → empty.
    func models(forAgent agentID: String) -> [AgentModel] {
        switch AgentModelMapping.source(forAgent: agentID) {
        case .manifest(let provider): return models(forProvider: provider)
        case .codexCLI:               return DevAgentDetection.shared.codexModels
        case .cursorCLI:              return DevAgentDetection.shared.cursorModels
        case .none:                   return []
        }
    }

    // MARK: Warm (live fetch → cache; fail-open)

    /// Fetch the live manifest and adopt it (in-memory + disk cache). On ANY
    /// failure (offline, non-200, malformed) it KEEPS the current resolved list
    /// (cache or bundled) — the picker never empties. Safe to call repeatedly;
    /// cheap (a small GET with a 1h server cache header).
    func warm() async {
        var request = URLRequest(url: ManagedBackend.agentModelsURL)
        request.httpMethod = "GET"
        do {
            let (data, status) = try await transport.send(request)
            guard status == 200 else {
                Log.dev.info("agent-models manifest fetch non-200 (\(status, privacy: .public)) — keeping cached/bundled")
                return
            }
            let dto = try JSONDecoder().decode(AgentModelsManifestDTO.self, from: data)
            let resolved = Self.resolve(dto)
            // Only adopt a fetch that actually carried models — a transient empty
            // body must not blank a working list (fail-open, same spirit as the
            // server's never-wipe rule).
            guard !resolved.isEmpty else {
                Log.dev.info("agent-models manifest fetch empty — keeping cached/bundled")
                return
            }
            providers = resolved
            saveCache(resolved)
            Log.dev.notice("agent-models manifest updated (\(resolved.keys.sorted().joined(separator: ","), privacy: .public))")
        } catch {
            // Offline / DNS / decode error — fail open, keep what we have.
            Log.dev.info("agent-models manifest fetch failed — keeping cached/bundled")
        }
    }

    // MARK: Mapping + cache

    private static func resolve(_ dto: AgentModelsManifestDTO) -> [String: [AgentModel]] {
        var out: [String: [AgentModel]] = [:]
        if let a = dto.providers.anthropic, !a.isEmpty {
            out["anthropic"] = a.map { AgentModel(modelID: $0.modelID, displayName: $0.displayName) }
        }
        return out
    }

    private func saveCache(_ providers: [String: [AgentModel]]) {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private static func loadCache(from defaults: UserDefaults) -> [String: [AgentModel]]? {
        guard let data = defaults.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: [AgentModel]].self, from: data),
              !decoded.isEmpty else { return nil }
        return decoded
    }
}
