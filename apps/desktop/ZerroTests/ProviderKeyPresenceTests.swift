//
//  ProviderKeyPresenceTests.swift
//  ZerroTests
//
//  UX-C — the observable key-presence signal that lets the Settings Transcription
//  engine picker re-render when an OpenAI key is added/removed. Driven end-to-end
//  through the same in-memory Keychain slot the Phase-5 first-key tests use, so no
//  real Keychain is touched. Also covers the pure `fallbackIfUnusable` rule that
//  resets a now-disabled selection.
//

import XCTest
@testable import Zerro

@MainActor
final class ProviderKeyPresenceTests: XCTestCase {

    /// Presence flips TRUE after a validated key WRITE and FALSE after a
    /// blank-field REMOVE — the reactivity the picker's "OpenAI cloud" gate needs —
    /// driven through `APIKeyFieldModel.onKeyStoreChanged` → `refresh()`.
    func testPresenceReflectsKeyAddThenRemove() async {
        let slot = InMemoryKeychainSlot()
        // The observable probes the injected slot for OpenAI (never the real Keychain).
        let presence = ProviderKeyPresence(probe: { provider in
            provider == .openai && (slot.read()?.isEmpty == false)
        })
        XCTAssertFalse(presence.openAIKeyPresent, "starts absent")

        let model = APIKeyFieldModel(provider: .openai, keychain: slot, firstKeyProbe: { true })
        model.validator = { _ in .valid }
        model.onKeyStoreChanged = { presence.refresh() }

        // ADD: a validated write fires onKeyStoreChanged → refresh → present.
        model.rawKey = "sk-fake"
        model.saveAndValidate()
        await waitUntilSettled(model)
        XCTAssertTrue(presence.openAIKeyPresent, "cloud option enables after a key is added")
        XCTAssertTrue(presence.hasKey(for: .openai))

        // REMOVE: blanking the field deletes the slot → onKeyStoreChanged → refresh.
        model.rawKey = ""
        model.saveAndValidate()
        XCTAssertFalse(presence.openAIKeyPresent, "cloud option disables after the key is removed")
    }

    /// `refresh()` re-reads every provider, not just the one that changed.
    func testRefreshTracksMultipleProviders() {
        var openAI = false
        var anthropic = true
        let presence = ProviderKeyPresence(probe: { provider in
            switch provider {
            case .openai: return openAI
            case .anthropic: return anthropic
            case .gemini: return false
            }
        })
        XCTAssertEqual(presence.present, [.anthropic])

        openAI = true; anthropic = false
        presence.refresh()
        XCTAssertEqual(presence.present, [.openai])
        XCTAssertTrue(presence.openAIKeyPresent)
    }

    /// The picker's selected-but-disabled reset rule: a still-usable engine keeps
    /// its selection (`nil`); a now-unusable one falls back to `.auto`.
    func testFallbackIfUnusable() {
        // .cloud stays when a key is present, resets when it's gone.
        XCTAssertNil(STTEnginePicker.fallbackIfUnusable(current: .cloud, modelInstalled: false, openAIKeyPresent: true))
        XCTAssertNil(
            STTEnginePicker.fallbackIfUnusable(
                current: .cloud,
                modelInstalled: false,
                openAIKeyPresent: false
            ),
            "cloud remains explicitly selected so the UI can require an OpenAI key"
        )
        // .local stays when installed, resets when removed.
        XCTAssertNil(STTEnginePicker.fallbackIfUnusable(current: .local, modelInstalled: true, openAIKeyPresent: false))
        XCTAssertNil(
            STTEnginePicker.fallbackIfUnusable(
                current: .local,
                modelInstalled: false,
                openAIKeyPresent: false
            ),
            "local remains explicitly selected so the UI can require the model download"
        )
        // .auto is always usable → never resets.
        XCTAssertNil(STTEnginePicker.fallbackIfUnusable(current: .auto, modelInstalled: false, openAIKeyPresent: false))
        XCTAssertNil(STTEnginePicker.fallbackIfUnusable(current: .auto, modelInstalled: true, openAIKeyPresent: true))
    }

    private func waitUntilSettled(_ model: APIKeyFieldModel, iterations: Int = 200) async {
        for _ in 0..<iterations {
            if model.state != .checking { return }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
    }
}
