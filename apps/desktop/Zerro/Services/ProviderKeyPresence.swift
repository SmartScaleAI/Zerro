//
//  ProviderKeyPresence.swift
//  Zerro
//
//  An OBSERVABLE snapshot of which providers have an API key on file, so Settings
//  surfaces re-render when a key is added or removed in the API Keys section.
//
//  `ProviderKeys.resolveKey` reads the Keychain directly, which is NOT an
//  observable source — a SwiftUI view that reads it once (e.g. the Transcription
//  engine picker's "OpenAI cloud needs a key" gate) never re-renders when a key is
//  saved in the API Keys section just above it. This tiny `@Observable`, created
//  once in `ZerroApp` and injected via `.environment` (mirroring the shared
//  `LocalModelManager`), is refreshed on every key write/delete so those views
//  observe presence instead of reading the Keychain once.
//
//  Settings-UI reactivity ONLY: runtime STT routing / `canGenerateLocally` read
//  the Keychain fresh per recording, so they're unaffected by this.
//

import Foundation

@MainActor
@Observable
final class ProviderKeyPresence {

    /// Providers with a usable key on file. Mutated only by `refresh()`; observed
    /// by the Settings sections so they re-render on a key add/remove.
    private(set) var present: Set<ModelProvider>

    /// How presence is probed per provider. Defaults to the real trimmed Keychain
    /// read (`ProviderKeys.resolveKey`); tests inject a closure over an in-memory
    /// backing so no real Keychain slot is touched.
    @ObservationIgnored private let probe: (ModelProvider) -> Bool

    init(probe: @escaping (ModelProvider) -> Bool = { ProviderKeys.resolveKey(for: $0) != nil }) {
        self.probe = probe
        self.present = Set(ModelProvider.allCases.filter(probe))
    }

    /// Re-read presence for every provider. Called after any key write/delete
    /// (`APIKeyFieldModel.onKeyStoreChanged`) so `present` — and the derived flags
    /// below — update in lockstep, driving a SwiftUI re-render.
    func refresh() {
        present = Set(ModelProvider.allCases.filter(probe))
    }

    func hasKey(for provider: ModelProvider) -> Bool { present.contains(provider) }

    /// Convenience for the Transcription engine picker's cloud gate.
    var openAIKeyPresent: Bool { present.contains(.openai) }
}
