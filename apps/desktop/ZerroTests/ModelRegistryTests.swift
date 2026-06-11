//
//  ModelRegistryTests.swift
//  ZerroTests
//
//  Phase 6 (multi-model) — the Swift model registry (the third mirror of
//  supabase/functions/generate/models.ts). These tests pin the CONTRACT the
//  server enforces: the exact wire ids + prices + ordering + the recommended
//  default. If a server registry change lands without this mirror following,
//  the literal expectations here fail — that's the sync alarm working.
//

import XCTest
@testable import Zerro

@MainActor
final class ModelRegistryTests: XCTestCase {

    // MARK: - Mirror contract (literal — intentionally NOT derived)

    func testRegistryMirrorsServerIdsAndPrices() {
        // (id, provider, creditPrice) exactly as in generate/models.ts.
        let expected: [(String, ModelProvider, Int)] = [
            ("gpt-5.4-mini", .openai, 2),
            ("gemini-3.5-flash", .gemini, 4),
            ("gemini-3.1-pro-preview", .gemini, 5),
            ("claude-sonnet-4-6", .anthropic, 7),
            ("claude-opus-4-7", .anthropic, 10),
            ("gpt-5.5", .openai, 11),
        ]
        XCTAssertEqual(ModelRegistry.all.count, expected.count)
        for (entry, (id, provider, price)) in zip(ModelRegistry.all, expected) {
            XCTAssertEqual(entry.id, id)
            XCTAssertEqual(entry.provider, provider)
            XCTAssertEqual(entry.creditPrice, price, entry.id)
        }
    }

    func testSortedCheapestFirst() {
        let prices = ModelRegistry.all.map(\.creditPrice)
        XCTAssertEqual(prices, prices.sorted(), "picker order is by cost ascending (plan 6A)")
    }

    func testExactlyOneRecommended_andItIsFlash() {
        let recommended = ModelRegistry.all.filter(\.recommended)
        XCTAssertEqual(recommended.map(\.id), ["gemini-3.5-flash"])
    }

    func testDefaultModelIsTheRecommendedOne() {
        // Matches the server's DEFAULT_MODEL_ID resolution, so an explicit
        // default-send and an absent field (un-updated app, D1) are identical.
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
        // A kill-switched / drifted id must never ride to the server (400).
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
