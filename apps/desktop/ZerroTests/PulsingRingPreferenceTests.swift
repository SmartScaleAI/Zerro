//
//  PulsingRingPreferenceTests.swift
//  ZerroTests
//
//  The Developer settings page's "Pulsing Ring Effect" toggle, backed by
//  `PreferencesStore.pulsingRingEnabled`. Pins:
//   • Defaults ON on a fresh install (no key written) — NOT the
//     false-for-missing trap a bare `bool(forKey:)` would fall into.
//   • Persists across stores over the same UserDefaults.
//   • Is in `Keys.resettable`, and "Reset to Defaults" restores it to ON
//     (true), never false.
//

import XCTest
@testable import Zerro

@MainActor
final class PulsingRingPreferenceTests: XCTestCase {

    func testDefaultsOnForFreshInstall() {
        // No key written → fresh install. Must read ON, not the
        // UserDefaults false-for-missing default.
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertTrue(prefs.pulsingRingEnabled, "the ring toggle defaults ON on a fresh install")
    }

    func testPersistsAcrossStores() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)

        prefs.pulsingRingEnabled = false
        // A new store over the same defaults sees the persisted OFF value.
        XCTAssertFalse(PreferencesStore(defaults: defaults).pulsingRingEnabled, "OFF persists")

        prefs.pulsingRingEnabled = true
        XCTAssertTrue(PreferencesStore(defaults: defaults).pulsingRingEnabled, "ON persists")
    }

    func testResettableAndResetRestoresOn() {
        XCTAssertTrue(
            PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.pulsingRingEnabled),
            "the key is wiped by Reset to Defaults"
        )

        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.pulsingRingEnabled = false
        prefs.resetToDefaults()
        XCTAssertTrue(prefs.pulsingRingEnabled, "reset restores the ring toggle to ON, not OFF")
    }
}
