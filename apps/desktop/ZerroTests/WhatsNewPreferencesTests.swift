//
//  WhatsNewPreferencesTests.swift
//  ZerroTests
//
//  The two What's New preferences on `PreferencesStore`. Pins:
//   • `showWhatsNewOnUpdate` defaults ON on a fresh install (NOT the
//     false-for-missing trap a bare `bool(forKey:)` would fall into),
//     persists across stores, and is restored to ON by Reset to Defaults.
//   • `lastSeenWhatsNewVersion` defaults nil, round-trips (including back to
//     nil), and SURVIVES Reset to Defaults — wiping it would make the next
//     launch look like a fresh install and re-pop the changelog.
//

import XCTest
@testable import Zerro

@MainActor
final class WhatsNewPreferencesTests: XCTestCase {

    // MARK: - showWhatsNewOnUpdate

    func testAutoShowDefaultsOnForFreshInstall() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        XCTAssertTrue(prefs.showWhatsNewOnUpdate, "the checkbox defaults ON on a fresh install")
    }

    func testAutoShowPersistsAcrossStores() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)

        prefs.showWhatsNewOnUpdate = false
        XCTAssertFalse(PreferencesStore(defaults: defaults).showWhatsNewOnUpdate, "OFF persists")

        prefs.showWhatsNewOnUpdate = true
        XCTAssertTrue(PreferencesStore(defaults: defaults).showWhatsNewOnUpdate, "ON persists")
    }

    func testAutoShowIsResettableAndResetRestoresOn() {
        XCTAssertTrue(
            PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.showWhatsNewOnUpdate),
            "the checkbox key is wiped by Reset to Defaults"
        )

        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.showWhatsNewOnUpdate = false
        prefs.resetToDefaults()
        XCTAssertTrue(prefs.showWhatsNewOnUpdate, "reset restores the checkbox to ON")
    }

    // MARK: - lastSeenWhatsNewVersion

    func testLastSeenDefaultsNilAndRoundTrips() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertNil(prefs.lastSeenWhatsNewVersion, "never recorded on a fresh install")

        prefs.lastSeenWhatsNewVersion = "1.4.22"
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).lastSeenWhatsNewVersion, "1.4.22",
            "the marker persists across stores"
        )

        prefs.lastSeenWhatsNewVersion = nil
        XCTAssertNil(
            PreferencesStore(defaults: defaults).lastSeenWhatsNewVersion,
            "clearing removes the persisted key"
        )
    }

    func testLastSeenSurvivesResetToDefaults() {
        XCTAssertFalse(
            PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.lastSeenWhatsNewVersion),
            "the marker is deliberately NOT in the resettable set"
        )

        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        prefs.lastSeenWhatsNewVersion = "1.4.22"
        prefs.resetToDefaults()
        XCTAssertEqual(prefs.lastSeenWhatsNewVersion, "1.4.22", "reset must not re-arm the auto-pop")
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).lastSeenWhatsNewVersion, "1.4.22",
            "the persisted key survives too"
        )
    }
}
