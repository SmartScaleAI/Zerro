//
//  BYOKRouting.swift
//  Zerro
//
//  Phase 6 (multi-model 6C/6D, F5) — the BYOK multi-provider seam:
//
//  • `ProviderKeys` — per-provider Keychain key resolution (the user may
//    store any subset of the three keys). The OpenAI key ALSO powers CLOUD
//    transcription — optional since on-device whisper.cpp landed: a user with
//    a Claude/Gemini key + the on-device model runs the whole pipeline with no
//    OpenAI key ($0 local STT).
//  • `BYOKRouting.effectiveEntry` — which registry model a BYOK generation
//    actually uses: the user's selection when its provider has a key,
//    otherwise the cheapest enabled model whose provider does (the persisted
//    selection can point at a keyless provider — e.g. the recommended Gemini
//    default on a fresh OpenAI-only setup — and a generation should degrade
//    to a usable model, not fail). `nil` = no chat key at all.
//  • `BYOKRouting.service` — the `PromptGenerationService` conformer for an
//    entry's provider.
//  • `BYOKCostEstimator` — the BYOK cost-display mirror of the eval
//    harness's CHAT_PRICING (Scripts/eval-models.mjs, F8 — KEEP IN SYNC).
//

import Foundation

// MARK: - ProviderKeys

enum ProviderKeys {

    /// The Keychain slot holding `provider`'s API key.
    static func slot(for provider: ModelProvider) -> KeychainSlot {
        switch provider {
        case .openai: return KeychainStore.openAIAPIKey
        case .gemini: return KeychainStore.geminiAPIKey
        case .anthropic: return KeychainStore.anthropicAPIKey
        }
    }

    /// The stored key for `provider`, trimmed, or `nil` when absent/empty.
    static func resolveKey(for provider: ModelProvider) -> String? {
        guard case .found(let key) = slot(for: provider).readResult() else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Providers with a usable key on file — drives the key-gated picker
    /// (6C.3) and the routing fallback. Read fresh at each use (a Settings
    /// change applies to the next generation, like every other key read).
    static func availableProviders() -> Set<ModelProvider> {
        Set(ModelProvider.allCases.filter { resolveKey(for: $0) != nil })
    }
}

// MARK: - BYOKRouting

enum BYOKRouting {

    /// The registry entry a BYOK generation should use, given the persisted
    /// selection and which providers have keys. Pure — availability is a
    /// parameter so tests drive every branch without a Keychain.
    static func effectiveEntry(
        selectedModelID: String,
        availableProviders: Set<ModelProvider>
    ) -> ModelEntry? {
        if let selected = ModelRegistry.entry(id: selectedModelID),
           selected.enabled, availableProviders.contains(selected.provider) {
            return selected
        }
        // Selection unusable (keyless provider / unknown id) → cheapest
        // enabled model the user CAN run. Registry order is cheapest-first.
        return ModelRegistry.enabled.first { availableProviders.contains($0.provider) }
    }

    /// The conformer for an entry's provider, configured for that exact
    /// model id. The key is resolved inside each service at request time.
    static func service(for entry: ModelEntry) -> any PromptGenerationService {
        switch entry.provider {
        case .openai: return OpenAIPromptGenerationService(model: entry.id)
        case .gemini: return GeminiPromptGenerationService(model: entry.id)
        case .anthropic: return AnthropicPromptGenerationService(model: entry.id)
        }
    }
}

// MARK: - BYOKCostEstimator

/// BYOK cost-DISPLAY estimation (the console cost log) for the registry
/// models across all three providers.
///
/// ⚠️ PRICING MIRROR — KEEP IN SYNC with
///   apps/desktop/Scripts/eval-models.mjs (CHAT_PRICING; the server-side
///   cost.ts both were mirrored from has been removed from the repository).
/// Rates are June-2026 list prices; Gemini 3.1 Pro is TIERED (both rates rise
/// above 200k input tokens); Gemini output rates already include thinking
/// tokens (folded into outputTokens by the adapter).
enum BYOKCostEstimator {

    struct ChatPrice {
        let inPerM: Double
        let outPerM: Double
        var tierThreshold: Int?
        var inPerMAbove: Double?
        var outPerMAbove: Double?
    }

    /// Keyed by registry model id (+ the legacy gpt-4o for old log lines).
    static let pricing: [String: ChatPrice] = [
        "gpt-4o": ChatPrice(inPerM: 2.5, outPerM: 10.0), // legacy BYOK default
        "gpt-5.4-mini": ChatPrice(inPerM: 0.75, outPerM: 4.5),
        "gpt-5.5": ChatPrice(inPerM: 5.0, outPerM: 30.0),
        "gemini-3.5-flash": ChatPrice(inPerM: 1.5, outPerM: 9.0),
        "gemini-3.1-pro-preview": ChatPrice(
            inPerM: 2.0, outPerM: 12.0,
            tierThreshold: 200_000, inPerMAbove: 4.0, outPerMAbove: 18.0
        ),
        "claude-sonnet-4-6": ChatPrice(inPerM: 3.0, outPerM: 15.0),
        "claude-opus-4-7": ChatPrice(inPerM: 5.0, outPerM: 25.0),
    ]

    /// Estimated USD chat cost for `usage` on the REQUESTED model id (the
    /// price table keys on what we asked for — a provider may report a dated
    /// alias the table doesn't carry, same rule as the server). `nil` for an
    /// unpriced id (logged as unpriced, never guessed).
    static func chatCostUSD(modelID: String, usage: TokenUsage) -> Double? {
        guard let price = pricing[modelID] else { return nil }
        let tiered = price.tierThreshold.map { usage.inputTokens > $0 } ?? false
        let inRate = tiered ? (price.inPerMAbove ?? price.inPerM) : price.inPerM
        let outRate = tiered ? (price.outPerMAbove ?? price.outPerM) : price.outPerM
        return Double(usage.inputTokens) / 1_000_000 * inRate
            + Double(usage.outputTokens) / 1_000_000 * outRate
    }
}
