//
//  ModelRegistry.swift
//  Zerro
//
//  The app-side model registry — the RUNTIME source of truth for which
//  models the picker offers and which provider API each one calls. Every
//  generation runs against the user's own provider key, so the ids here are
//  the exact model ids the provider APIs accept.
//
//  KEEP IN SYNC with apps/desktop/Scripts/eval-models.mjs (the eval
//  harness), which carries the same list so evals exercise the shipped
//  models. The app shows no per-model cost: the user pays their provider
//  directly for usage.
//
//  `enabled` is the app's own kill switch: the picker only renders enabled
//  entries, while a disabled id stays resolvable for historic results.
//

import Foundation

// MARK: - ModelProvider

/// Which API vendor serves a model. It selects the user's per-provider key
/// and gates selectability (a model is unavailable without its key).
enum ModelProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case openai
    case gemini
    case anthropic

    /// User-facing vendor name (BYOK key fields, picker hints).
    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .anthropic: return "Anthropic"
        }
    }
}

// MARK: - ModelEntry

/// One selectable model: id / provider / displayName / recommended / enabled.
/// The app shows no per-model cost — the user pays their provider directly.
struct ModelEntry: Equatable, Identifiable, Sendable {
    /// The exact provider API model id the generation path calls.
    let id: String
    let provider: ModelProvider
    /// User-facing name in the picker.
    let displayName: String
    /// The picker's "Recommended for Zerro" badge (exactly one model).
    let recommended: Bool
    /// Mirrors the server kill switch — disabled entries never render.
    let enabled: Bool

    init(
        id: String,
        provider: ModelProvider,
        displayName: String,
        recommended: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.recommended = recommended
        self.enabled = enabled
    }
}

// MARK: - ModelRegistry

/// Namespace for the registry table + lookups. Pure value data — no I/O, no
/// persistence (the user's selection lives in `PreferencesStore`).
enum ModelRegistry {

    /// Registry order is the historical cheapest-first ordering (plan 6A). The
    /// app shows no per-model cost, so this is just the stable render order;
    /// ModelRegistryTests pins the ids and order literally.
    static let all: [ModelEntry] = [
        // Kill-switched (enabled: false) — a product decision. Out of the
        // picker (`enabled`), still in `.all` so historic results resolve its
        // name via `entry(id:)`.
        ModelEntry(id: "gpt-5.4-mini", provider: .openai, displayName: "GPT-5.4 mini", enabled: false),
        ModelEntry(id: "gemini-3.5-flash", provider: .gemini, displayName: "Gemini 3.5 Flash", recommended: true),
        ModelEntry(id: "gemini-3.1-pro-preview", provider: .gemini, displayName: "Gemini 3.1 Pro"),
        ModelEntry(id: "claude-sonnet-4-6", provider: .anthropic, displayName: "Claude Sonnet 4.6"),
        ModelEntry(id: "claude-opus-4-7", provider: .anthropic, displayName: "Claude Opus 4.7"),
        ModelEntry(id: "gpt-5.5", provider: .openai, displayName: "GPT-5.5"),
    ]

    /// What the picker renders (the enabled subset).
    static let enabled: [ModelEntry] = all.filter(\.enabled)

    /// Registry lookup by wire id (enabled or not — disabled entries stay
    /// resolvable for displaying historic results).
    static func entry(id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }

    /// The default selection: the recommended enabled entry, falling back to
    /// the cheapest enabled one if the recommendation is ever kill-switched, so
    /// a fresh install and a fallback from an unknown persisted selection get
    /// the same model.
    static let defaultModelID: String =
        (all.first { $0.recommended && $0.enabled } ?? enabled[0]).id

}

// MARK: - Selection policy

/// Shared rules for the menu-bar picker and recording start. Keeping the
/// BYOK provider gating here prevents the configuration surface
/// from drifting from the model that generation actually receives.
enum ModelSelectionPolicy {
    static func effectiveModelID(
        persistedModelID: String,
        entitlement: EntitlementState?,
        availableProviders: Set<ModelProvider>
    ) -> String {
        guard entitlement?.usesOwnProviderKeys == true else {
            return persistedModelID
        }
        return BYOKRouting.effectiveEntry(
            selectedModelID: persistedModelID,
            availableProviders: availableProviders
        )?.id ?? persistedModelID
    }

    static func isBYOKGated(
        _ model: ModelEntry,
        entitlement: EntitlementState?,
        availableProviders: Set<ModelProvider>
    ) -> Bool {
        guard entitlement?.usesOwnProviderKeys == true else { return false }
        return !availableProviders.contains(model.provider)
    }
}

// MARK: - Copy derivation

extension ModelRegistry {

    /// User-facing count of selectable models, spelled out for prose copy
    /// ("all five models"). Derived from `enabled` so marketing copy can never
    /// drift from the registry again — a kill switch flipped in `all` rewrites
    /// the paywall and Billing strings with it. Falls back to a numeral past ten.
    ///
    /// Safe to interpolate into `static let` copy constants: `enabled` is a pure
    /// value table (no I/O, no actor hop) and Swift's lazy static init orders the
    /// dependency for us.
    static var selectableCountWord: String {
        let n = enabled.count
        let words = ["zero", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine", "ten"]
        return n < words.count ? words[n] : String(n)
    }
}
