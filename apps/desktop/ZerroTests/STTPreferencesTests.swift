//
//  STTPreferencesTests.swift
//  ZerroTests
//
//  Phase 2 (Local Whisper) — the new `PreferencesStore` fields:
//   • `sttEngine` defaults to `.auto`, persists, and IS reset (a pure preference).
//   • `localModelVersion` / `localModelDownloadedAt` persist but are NOT reset —
//     they mirror an on-disk model file that a settings reset doesn't delete.
//

import XCTest
@testable import Zerro

@MainActor
final class STTPreferencesTests: XCTestCase {

    func testSttEngineDefaultsToAutoOnFreshInstall() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        XCTAssertEqual(prefs.sttEngine, .auto, "STT engine defaults to .auto")
    }

    func testSttEnginePersistsAcrossStores() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)

        prefs.sttEngine = .local
        XCTAssertEqual(PreferencesStore(defaults: defaults).sttEngine, .local, ".local persists")

        prefs.sttEngine = .cloud
        XCTAssertEqual(PreferencesStore(defaults: defaults).sttEngine, .cloud, ".cloud persists")
    }

    func testUnknownStoredSttEngineFallsBackToAuto() {
        let defaults = UserDefaults.ephemeralPreview()
        defaults.set("bogus", forKey: PreferencesStore.Keys.sttEngine)
        XCTAssertEqual(PreferencesStore(defaults: defaults).sttEngine, .auto, "an unknown raw value falls back to .auto")
    }

    func testSttEngineIsResettableToAuto() {
        XCTAssertTrue(
            PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.sttEngine),
            "sttEngine is wiped by Reset to Defaults"
        )
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.sttEngine = .cloud
        prefs.resetToDefaults()
        XCTAssertEqual(prefs.sttEngine, .auto, "reset restores .auto")
    }

    func testLocalModelFieldsDefaultEmptyAndPersist() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)

        XCTAssertEqual(prefs.localModelVersion, "", "no model installed by default")
        XCTAssertNil(prefs.localModelDownloadedAt)

        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        prefs.localModelVersion = "ggml-large-v3-turbo-q5_0"
        prefs.localModelDownloadedAt = stamp

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.localModelVersion, "ggml-large-v3-turbo-q5_0")
        XCTAssertEqual(reloaded.localModelDownloadedAt, stamp)
    }

    func testLocalModelFieldsSurviveSettingsReset() {
        // These mirror an on-disk file the reset doesn't delete, so they must NOT
        // be in the resettable set and must survive resetToDefaults().
        XCTAssertFalse(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.localModelVersion))
        XCTAssertFalse(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.localModelDownloadedAt))

        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.localModelVersion = "ggml-large-v3-turbo-q5_0"
        prefs.localModelDownloadedAt = Date(timeIntervalSince1970: 1_750_000_000)

        prefs.resetToDefaults()

        XCTAssertEqual(prefs.localModelVersion, "ggml-large-v3-turbo-q5_0", "model version survives a settings reset")
        XCTAssertNotNil(prefs.localModelDownloadedAt, "download timestamp survives a settings reset")
    }

    func testLocalModelPromptShownPersistsAndIsNotResettable() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertFalse(prefs.localModelPromptShown, "defaults false on a fresh install")

        prefs.localModelPromptShown = true
        XCTAssertTrue(PreferencesStore(defaults: defaults).localModelPromptShown, "persists")

        // Kept OUT of resettable so a settings reset doesn't re-nag.
        XCTAssertFalse(
            PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.localModelPromptShown),
            "localModelPromptShown is not wiped by Reset to Defaults"
        )
        prefs.resetToDefaults()
        XCTAssertTrue(prefs.localModelPromptShown, "survives a settings reset")
    }
}
