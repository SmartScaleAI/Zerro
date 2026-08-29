//
//  ModelRegistryTests.swift
//  ZerroTests
//
//  Phase 6 (multi-model) — the app's model registry (ModelRegistry.swift).
//  These tests pin the CONTRACT: the exact wire ids + provider + ordering +
//  the recommended default, as literal expectations that are intentionally
//  NOT derived from the registry. The registry shows no per-model cost
//  (metered-credits Phase 4), so there's nothing to assert about prices here.
//  If a registry change lands without these expectations following, the
//  literal id/order expectations fail — the drift alarm working.
//

import XCTest
@testable import Zerro

@MainActor
final class ModelRegistryTests: XCTestCase {

    // MARK: - Registry contract (literal — intentionally NOT derived)

    func testRegistryPinsExpectedIdsProvidersAndOrdering() {
        // (id, provider, enabled) and ORDER exactly as ModelRegistry.all declares
        // them. No price expectations — the app shows no per-model cost
        // (metered-credits Phase 4). GPT-5.4 mini is kill-switched
        // (enabled: false) but stays in `.all`.
        let expected: [(String, ModelProvider, Bool)] = [
            ("gpt-5.4-mini", .openai, false),
            ("gemini-3.5-flash", .gemini, true),
            ("gemini-3.1-pro-preview", .gemini, true),
            ("claude-sonnet-4-6", .anthropic, true),
            ("claude-opus-4-7", .anthropic, true),
            ("gpt-5.5", .openai, true),
        ]
        XCTAssertEqual(ModelRegistry.all.count, expected.count)
        for (entry, (id, provider, enabled)) in zip(ModelRegistry.all, expected) {
            XCTAssertEqual(entry.id, id)
            XCTAssertEqual(entry.provider, provider, entry.id)
            XCTAssertEqual(entry.enabled, enabled, entry.id)
        }
    }

    func testGPT54MiniDisabledButStillResolvable() {
        // The kill-switch contract: out of the picker (`enabled`), still in
        // `.all` and resolvable via `entry(id:)` so historic generations render
        // its name.
        XCTAssertFalse(
            ModelRegistry.enabled.contains { $0.id == "gpt-5.4-mini" },
            "disabled model must not appear in the picker"
        )
        XCTAssertTrue(ModelRegistry.all.contains { $0.id == "gpt-5.4-mini" })
        XCTAssertEqual(ModelRegistry.entry(id: "gpt-5.4-mini")?.displayName, "GPT-5.4 mini")
        XCTAssertEqual(ModelRegistry.entry(id: "gpt-5.4-mini")?.enabled, false)
    }

    func testExactlyOneRecommended_andItIsFlash() {
        let recommended = ModelRegistry.all.filter(\.recommended)
        XCTAssertEqual(recommended.map(\.id), ["gemini-3.5-flash"])
    }

    func testDefaultModelIsTheRecommendedOne() {
        // ModelRegistry.defaultModelID resolves to the recommended enabled entry,
        // so a fresh install and a fallback from an unknown persisted id land on
        // the same model.
        XCTAssertEqual(ModelRegistry.defaultModelID, "gemini-3.5-flash")
    }

    func testEntryLookup() {
        XCTAssertEqual(ModelRegistry.entry(id: "claude-opus-4-7")?.displayName, "Claude Opus 4.7")
        XCTAssertNil(ModelRegistry.entry(id: "gpt-4o"), "pre-multi-model id is NOT a registry model")
    }

    // MARK: - Selection persistence (PreferencesStore)

    private func freshDefaults() -> UserDefaults {
        let suite = "ModelRegistryTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testSelectedModelDefaultsToRecommended() {
        let prefs = PreferencesStore(defaults: freshDefaults())
        XCTAssertEqual(prefs.selectedModelID, ModelRegistry.defaultModelID)
    }

    func testSelectedModelPersistsAcrossInits() {
        let defaults = freshDefaults()
        let prefs = PreferencesStore(defaults: defaults)
        prefs.selectedModelID = "gpt-5.5"
        XCTAssertEqual(PreferencesStore(defaults: defaults).selectedModelID, "gpt-5.5")
    }

    func testUnknownPersistedModelFallsBackToDefault() {
        // A kill-switched / drifted persisted id must never be used for a
        // generation; it falls back to the default instead.
        let defaults = freshDefaults()
        defaults.set("gpt-4o", forKey: PreferencesStore.Keys.selectedModelID)
        XCTAssertEqual(PreferencesStore(defaults: defaults).selectedModelID, ModelRegistry.defaultModelID)
    }

    func testResetToDefaultsClearsSelection() {
        let defaults = freshDefaults()
        let prefs = PreferencesStore(defaults: defaults)
        prefs.selectedModelID = "gpt-5.5"
        prefs.resetToDefaults()
        XCTAssertEqual(PreferencesStore(defaults: defaults).selectedModelID, ModelRegistry.defaultModelID)
    }
}
