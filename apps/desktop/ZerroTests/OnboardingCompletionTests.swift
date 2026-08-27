//
//  OnboardingCompletionTests.swift
//  ZerroTests
//

import XCTest
@testable import Zerro

@MainActor
final class OnboardingCompletionTests: XCTestCase {
    func testReadyCopyNamesTheLocalTrialLength() {
        XCTAssertEqual(
            OnboardingReadyCopy.trialMessage,
            "Your \(TrialManager.trialLengthDays)-day free trial is ready."
        )
        XCTAssertEqual(OnboardingReadyCopy.trialMessage, "Your 14-day free trial is ready.")
    }

    func testCompletionPersistsAndDismissesBeforeOpeningOverlay() async {
        let defaults = UserDefaults.ephemeralPreview()
        let state = OnboardingState(defaults: defaults)
        state.move(to: .complete)

        let overlayOpened = expectation(description: "Overlay opened")
        var events: [String] = []

        OnboardingCompletionHandoff.perform(
            complete: {
                state.completeOnboarding()
                events.append("completed")
            },
            dismiss: {
                events.append("dismissed")
            },
            openOverlay: {
                events.append("overlay")
                overlayOpened.fulfill()
            }
        )

        XCTAssertTrue(state.hasCompletedOnboarding)
        XCTAssertTrue(defaults.bool(forKey: OnboardingPersistenceKeys.legacyCompleted))
        XCTAssertEqual(state.currentScreen, .setup)
        XCTAssertEqual(events, ["completed", "dismissed"])

        await fulfillment(of: [overlayOpened], timeout: 1)
        XCTAssertEqual(events, ["completed", "dismissed", "overlay"])
    }

    func testOverlayOpenerUsesTheRegisteredCanonicalRoute() {
        let previous = AppDelegate.requestOpenAreaSelector
        defer { AppDelegate.requestOpenAreaSelector = previous }

        var didOpen = false
        AppDelegate.requestOpenAreaSelector = { didOpen = true }

        AppDelegate.openAreaSelector()

        XCTAssertTrue(didOpen)
    }
}
