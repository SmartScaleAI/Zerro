//
//  DevCursorActivationTests.swift
//  ZerroTests
//
//  Dev Mode — the green recording-cursor glow's activation contract.
//  `DevCursorWindowController` draws a soft green glow under the (untouched)
//  system cursor while, and ONLY while, a Dev Mode RECORDING is in progress. Two
//  load-bearing guarantees are pinned here:
//
//    1. `AppState.devCursorActive` is true exactly when a recording is active AND
//       it's a Dev Mode session — false for idle, a normal (non-Dev) recording,
//       and after the recording stops.
//    2. The controller's show/hide gate (`shouldShow`) additionally respects the
//       `devCursorEnabled` opt-in — on only when BOTH the state flag and the pref
//       are on.
//

import XCTest
@testable import Zerro

@MainActor
final class DevCursorActivationTests: XCTestCase {

    // MARK: - devCursorActive truth table

    func testCursorActiveOnlyDuringAnActiveDevRecording() {
        let app = AppState()
        app.recordingIsDevMode = true
        // The active-recording window (the same states `isRecordingActive` covers).
        for s in [RecordingState.recording, .wrappingUp, .autoStopped] {
            app.state = s
            XCTAssertTrue(app.devCursorActive, "\(s) + Dev Mode must show the cursor")
        }
    }

    func testCursorInactiveWhenIdle() {
        let app = AppState()
        app.recordingIsDevMode = true
        app.state = .idle
        XCTAssertFalse(app.devCursorActive, "idle must not show the cursor")
    }

    func testCursorInactiveForNonDevRecording() {
        let app = AppState()
        app.recordingIsDevMode = false // a normal clipboard recording
        app.state = .recording
        XCTAssertFalse(app.devCursorActive, "a non-Dev recording must not show the cursor")
    }

    func testCursorInactiveAfterRecordingStops() {
        let app = AppState()
        app.recordingIsDevMode = true
        app.state = .recording
        XCTAssertTrue(app.devCursorActive)
        // Stopping a Dev recording drops `state` out of the active-recording window
        // (→ processing / dev phases); the cursor must go away even though
        // `recordingIsDevMode` may still read true until teardown.
        app.state = .processing
        XCTAssertFalse(app.devCursorActive, "a stopped recording must not show the cursor")
    }

    // MARK: - shouldShow gating (state flag AND the opt-in)

    func testShouldShowRequiresBothStateAndPref() {
        XCTAssertTrue(DevCursorWindowController.shouldShow(devCursorActive: true, devCursorEnabled: true))
        XCTAssertFalse(DevCursorWindowController.shouldShow(devCursorActive: true, devCursorEnabled: false))
        XCTAssertFalse(DevCursorWindowController.shouldShow(devCursorActive: false, devCursorEnabled: true))
        XCTAssertFalse(DevCursorWindowController.shouldShow(devCursorActive: false, devCursorEnabled: false))
    }

    func testShouldShowReflectsLiveStateAndPref() {
        let app = AppState()
        app.recordingIsDevMode = true
        app.state = .recording
        let prefs = PreferencesStore(defaults: Self.ephemeralDefaults())

        prefs.devCursorEnabled = true
        XCTAssertTrue(
            DevCursorWindowController.shouldShow(
                devCursorActive: app.devCursorActive,
                devCursorEnabled: prefs.devCursorEnabled
            ),
            "active Dev recording + opt-in on → show"
        )

        // Flipping the opt-in off mid-recording must gate the cursor off.
        prefs.devCursorEnabled = false
        XCTAssertFalse(
            DevCursorWindowController.shouldShow(
                devCursorActive: app.devCursorActive,
                devCursorEnabled: prefs.devCursorEnabled
            ),
            "opt-in off must hide the cursor even mid-recording"
        )
    }

    func testDevCursorEnabledDefaultsOn() {
        let prefs = PreferencesStore(defaults: Self.ephemeralDefaults())
        XCTAssertTrue(prefs.devCursorEnabled, "the recording-cursor glow ships ON by default")
    }

    // MARK: - Helpers

    /// A throwaway, isolated UserDefaults so a test never reads or writes the real
    /// app domain (mirrors the suite's other PreferencesStore tests).
    private static func ephemeralDefaults() -> UserDefaults {
        let suite = "DevCursorActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
