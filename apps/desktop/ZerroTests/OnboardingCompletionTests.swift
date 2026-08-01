//
//  OnboardingCompletionTests.swift
//  ZerroTests
//

import XCTest
@testable import Zerro

@MainActor
final class OnboardingCompletionTests: XCTestCase {
    func testReadyCopyKeepsManagedAndBYOKTrialsDistinct() {
        XCTAssertEqual(
            OnboardingReadyCopy.trialMessage(
                for: .free,
                managedCreditsLimit: 30,
                managedCreditsRemaining: 30
            ),
            "Your 30 free credits are ready."
        )
        XCTAssertEqual(
            OnboardingReadyCopy.trialMessage(
                for: .byok,
                managedCreditsLimit: 30,
                managedCreditsRemaining: 30
            ),
            "Your 10-generation trial is ready."
        )
    }

    func testManagedReadyCopyDoesNotPromiseAnUnavailableTrial() {
        XCTAssertNil(
            OnboardingReadyCopy.trialMessage(
                for: .free,
                managedCreditsLimit: nil,
                managedCreditsRemaining: nil
            )
        )
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
