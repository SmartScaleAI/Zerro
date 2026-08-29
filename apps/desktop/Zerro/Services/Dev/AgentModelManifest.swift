//
//  AgentModelManifest.swift
//  Zerro
//
//  Dev Mode — the coding-agent model manifest, read from the BUNDLED
//  `AgentModels.json` resource. That checked-in JSON is the single
//  authoritative list for the manifest-backed agents (Claude Code /
//  anthropic); updating the available models is a one-file edit + release.
//  No network, no server, no persistent cache.
//
//  A missing, unreadable, empty, or malformed resource never crashes or
//  blocks the app: the store logs the failure and resolves an EMPTY list, and
//  the agent simply launches without a `--model` flag (its own default model
//  applies — see `DevAgentRegistry` argv assembly, which omits the flag for a
//  nil selection).
//
//  Codex and Cursor are NOT here — their lists have no manifest we could
//  ship, so they're read client-side from each agent's own per-account
//  tooling (`~/.codex/models_cache.json` / `cursor-agent models`; see
//  `DevAgentDetection`).
//

import Foundation
import os

// MARK: - AgentModel

/// One selectable model for an agent's `--model` flag. `modelID` is the EXACT
/// string passed to the CLI (`--model <modelID>`); `displayName` is the menu
/// label.
struct AgentModel: Identifiable, Equatable, Sendable, Codable {
    let modelID: String
    let displayName: String
    var id: String { modelID }
}

// MARK: - Agent → model source mapping

/// Where an agent's model list comes from. The bundled manifest backs Claude
/// Code (anthropic); Codex and Cursor source their lists CLIENT-SIDE from
/// their own per-account tools (a ChatGPT-account Codex / Cursor use their own
/// slugs). `.none` is an agent with no model picker (unknown / future).
enum AgentModelSource: Equatable, Sendable {
    /// A provider key in the bundled `AgentModels.json` (currently "anthropic").
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

// MARK: - Manifest DTO (the bundled AgentModels.json shape)

/// `{ providers: { anthropic: [{ model_id, display_name }], ... } }`. Only
/// `anthropic` is consumed now (Codex sources its own list); any other
/// provider key in the file is simply ignored.
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

    /// Shared so every reader resolves the same loaded manifest.
    static let shared = AgentModelManifestStore()

    /// Models per provider key ("anthropic"), ordered newest-first (rank 0 =
    /// the default pick). Loaded once from the bundled resource; empty for a
    /// provider only when the resource itself is missing or corrupted (the
    /// fail-safe documented in the file header).
    private(set) var providers: [String: [AgentModel]]

    /// The bundled resource's name inside the app bundle.
    static let resourceName = "AgentModels"

    // MARK: Init

    /// Loads the bundled manifest from `bundle` (the app bundle in
    /// production; tests inject their own). Failures resolve to an empty
    /// manifest — logged, never fatal.
    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: Self.resourceName, withExtension: "json") else {
            Log.dev.error("agent-models: bundled AgentModels.json missing — model pickers fall back to agent defaults")
            self.providers = [:]
            return
        }
        guard let data = try? Data(contentsOf: url),
              let resolved = Self.decode(data) else {
            Log.dev.error("agent-models: bundled AgentModels.json unreadable/malformed — model pickers fall back to agent defaults")
            self.providers = [:]
            return
        }
        self.providers = resolved
    }

    // MARK: Resolution

    /// The models for a provider key. Empty only when the bundled resource
    /// failed to load (see the file header's fail-safe).
    func models(forProvider provider: String) -> [AgentModel] {
        providers[provider] ?? []
    }

    /// The models a given AGENT can be launched with, resolving its source. A
    /// manifest agent (Claude Code) reads this store; Codex and Cursor read
    /// their own per-account lists from `DevAgentDetection`; `.none` → empty.
    func models(forAgent agentID: String) -> [AgentModel] {
        switch AgentModelMapping.source(forAgent: agentID) {
        case .manifest(let provider): return models(forProvider: provider)
        case .codexCLI:               return DevAgentDetection.shared.codexModels
        case .cursorCLI:              return DevAgentDetection.shared.cursorModels
        case .none:                   return []
        }
    }

    // MARK: Decoding

    /// Parse manifest JSON into the provider map, or nil when the data is
    /// malformed or carries no models (an empty file must not silently look
    /// loaded). Internal so tests can drive the malformed/empty paths with
    /// raw data.
    static func decode(_ data: Data) -> [String: [AgentModel]]? {
        guard let dto = try? JSONDecoder().decode(AgentModelsManifestDTO.self, from: data) else {
            return nil
        }
        var out: [String: [AgentModel]] = [:]
        if let a = dto.providers.anthropic, !a.isEmpty {
            out["anthropic"] = a.map { AgentModel(modelID: $0.modelID, displayName: $0.displayName) }
        }
        return out.isEmpty ? nil : out
    }
}
