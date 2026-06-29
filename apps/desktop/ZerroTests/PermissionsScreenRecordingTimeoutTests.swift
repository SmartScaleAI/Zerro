//
//  PermissionsScreenRecordingTimeoutTests.swift
//  ZerroTests
//
//  Guards the screen-recording "2s safety net" gating in `PermissionsManager`.
//
//  The bug: `requestScreenRecording()` fires `CGRequestScreenCaptureAccess()`
//  (non-blocking, no callback) and arms a 2s fallback that force-finalizes the
//  request so the silent-no-op case (macOS only shows the TCC popup on the
//  FIRST call per bundle) can still reach the denied/deep-link UI. But a real
//  user takes longer than 2s to answer the Apple dialog, so the old timer
//  flipped the onboarding step to "Screen Recording was denied" while the
//  genuine popup was still on screen and unanswered.
//
//  The fix keys off app activation: a real TCC popup belongs to another process
//  and steals key focus, so the app receives `didResignActive`; a silent no-op
//  shows no popup and never resigns. The safety net now force-finalizes ONLY
//  when no popup appeared. `shouldForceFinalizeScreenRecordingOnTimeout` is the
//  single source of truth the production timer and these tests both consult.
//
//  These tests drive the decision via DEBUG-only seams instead of
//  `requestScreenRecording()`, which would fire a real popup and read live OS
//  grant state. `Analytics.capture` is a no-op until `start()` runs (never in
//  tests) and each manager gets an ephemeral `UserDefaults`, so nothing here
//  touches the backend or the user's prefs.
//

import XCTest
@testable import Zerro

@MainActor
final class PermissionsScreenRecordingTimeoutTests: XCTestCase {

    private func makeManager() -> PermissionsManager {
        PermissionsManager(defaults: .ephemeralPreview())
    }

    /// The reported bug: a real popup appeared (app resigned active) and the
    /// user hasn't answered yet. The safety net must NOT fire, and the request
    /// must stay in flight so the step keeps rendering its request view
    /// (`computeScreenRecordingStatus` reports `.notDetermined` while awaiting)
    /// rather than the premature denied view.
    func testPopupAppearedSuppressesSafetyNetForceFinalize() {
        let manager = makeManager()
        manager.beginScreenRecordingRequestForTesting()
        manager.simulateScreenRecordingPopupAppearedForTesting()

        XCTAssertFalse(
            manager.shouldForceFinalizeScreenRecordingOnTimeoutForTesting,
            "A real, unanswered TCC popup is on screen — the 2s timer must not force a denied state"
        )
        XCTAssertTrue(
            manager.isAwaitingScreenRecordingResponseForTesting,
            "The request must remain in flight; the didBecomeActive observer resolves it when the user answers"
        )

        // End-to-end guarantee: the user-visible status must not be the buggy
        // premature `.denied`. (It stays `.notDetermined` while awaiting, or is
        // `.granted` if this host already has the permission — never `.denied`.)
        manager.refreshStatuses()
        XCTAssertNotEqual(
            manager.screenRecordingStatus, .denied,
            "Status must not flip to denied while a real popup is unanswered"
        )
    }

    /// The genuine silent-no-op case the safety net exists for: CGRequest showed
    /// no popup, so the app never resigned active. The timer SHOULD force-finalize
    /// so the step resolves to `.denied` and the Open System Settings deep-link
    /// UI becomes available.
    func testNoPopupAllowsSafetyNetForceFinalize() {
        let manager = makeManager()
        manager.beginScreenRecordingRequestForTesting()
        // No resign — CGRequest was a silent no-op.

        XCTAssertTrue(
            manager.shouldForceFinalizeScreenRecordingOnTimeoutForTesting,
            "No popup appeared, so the safety net must force-finalize to reach the denied/deep-link UI"
        )
    }

    /// With no request in flight the safety net is inert — the predicate must be
    /// false regardless of prior popup signals.
    func testNoRequestInFlightNeverForceFinalizes() {
        let manager = makeManager()
        XCTAssertFalse(manager.shouldForceFinalizeScreenRecordingOnTimeoutForTesting)
    }

    /// A `didResignActive` that arrives BEFORE a request begins (or after one
    /// finalized) must not poison the flag for the next request — guarded by the
    /// `isAwaitingScreenRecordingResponse` check inside the resign handler.
    func testResignBeforeRequestDoesNotPoisonNextRequest() {
        let manager = makeManager()
        manager.simulateScreenRecordingPopupAppearedForTesting() // not in flight → ignored
        manager.beginScreenRecordingRequestForTesting()

        XCTAssertTrue(
            manager.shouldForceFinalizeScreenRecordingOnTimeoutForTesting,
            "A stray earlier resign must not carry into a fresh request and suppress the safety net"
        )
    }
}
