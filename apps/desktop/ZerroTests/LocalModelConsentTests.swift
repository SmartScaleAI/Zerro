//
//  LocalModelConsentTests.swift
//  ZerroTests
//
//  Phase 5 (Local Whisper) — the user-facing gating logic, all driven without the
//  network or the user's real Keychain:
//   • `LocalModelConsent.shouldPrompt` — the first-key consent decision.
//   • `STTEnginePicker.isSelectable` — the engine-picker disabled-state rule.
//   • `APIKeyFieldModel.onKeyVerified` — the first-key signal threaded out of a
//     `.valid` save (in-memory Keychain + injected first-key probe).
//

import XCTest
@testable import Zerro

@MainActor
final class LocalModelConsentTests: XCTestCase {

    // MARK: - Consent prompt gating

    func testShouldPromptOnlyWhenFirstKeyFreshAndModelNotReady() {
        XCTAssertTrue(LocalModelConsent.shouldPrompt(
            isFirstKey: true, alreadyShown: false, modelReady: false))

        XCTAssertFalse(LocalModelConsent.shouldPrompt(
            isFirstKey: false, alreadyShown: false, modelReady: false),
            "not the first key → no prompt")
        XCTAssertFalse(LocalModelConsent.shouldPrompt(
            isFirstKey: true, alreadyShown: true, modelReady: false),
            "already shown → never re-prompt")
        XCTAssertFalse(LocalModelConsent.shouldPrompt(
            isFirstKey: true, alreadyShown: false, modelReady: true),
            "model already installed → no prompt")
    }

    // MARK: - Engine picker selectability

    func testEnginePickerSelectability() {
        // Auto is always selectable (it degrades to whatever is available).
        XCTAssertTrue(STTEnginePicker.isSelectable(.auto, modelInstalled: false, openAIKeyPresent: false))
        XCTAssertTrue(STTEnginePicker.isSelectable(.auto, modelInstalled: true, openAIKeyPresent: true))
        // On-device needs the model installed.
        XCTAssertTrue(STTEnginePicker.isSelectable(.local, modelInstalled: true, openAIKeyPresent: false))
        XCTAssertFalse(STTEnginePicker.isSelectable(.local, modelInstalled: false, openAIKeyPresent: true))
        // OpenAI cloud needs an OpenAI key.
        XCTAssertTrue(STTEnginePicker.isSelectable(.cloud, modelInstalled: false, openAIKeyPresent: true))
        XCTAssertFalse(STTEnginePicker.isSelectable(.cloud, modelInstalled: true, openAIKeyPresent: false))
    }

    // MARK: - First-key detection (APIKeyFieldModel.onKeyVerified)

    func testFirstKeySaveReportsWasFirstKeyTrue() async {
        let model = APIKeyFieldModel(
            provider: .anthropic,
            keychain: InMemoryKeychainSlot(),   // never touches the real Keychain
            firstKeyProbe: { true }             // simulate: no provider keys yet
        )
        model.validator = { _ in .valid }
        var captured: Bool?
        model.onKeyVerified = { captured = $0 }

        model.rawKey = "sk-ant-fake"
        model.saveAndValidate()
        await waitUntilSettled(model)

        XCTAssertEqual(model.state, .verified)
        XCTAssertEqual(captured, true, "first key across all providers → wasFirstKey true")
    }

    func testSecondKeySaveReportsWasFirstKeyFalse() async {
        let model = APIKeyFieldModel(
            provider: .openai,
            keychain: InMemoryKeychainSlot(),
            firstKeyProbe: { false }            // simulate: a key already exists
        )
        model.validator = { _ in .valid }
        var captured: Bool?
        model.onKeyVerified = { captured = $0 }

        model.rawKey = "sk-fake"
        model.saveAndValidate()
        await waitUntilSettled(model)

        XCTAssertEqual(captured, false, "a later key → wasFirstKey false")
    }

    private func waitUntilSettled(_ model: APIKeyFieldModel, iterations: Int = 200) async {
        for _ in 0..<iterations {
            if model.state != .checking { return }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
    }
}
