//
//  OnboardingSetupTests.swift
//  ZerroTests
//
//  Phase 2 guards for the collapsed Setup screen and its compatibility
//  transitions into the existing transcription/permissions implementation.
//

import XCTest
@testable import Zerro

@MainActor
final class OnboardingSetupTests: XCTestCase {
    func testManagedSetupRequiresAValidLookingEmailAndTermsAgreement() {
        XCTAssertFalse(OnboardingSetupPolicy.canStartFree(
            email: "user@example.com",
            agreed: false,
            isWorking: false
        ))
        XCTAssertFalse(OnboardingSetupPolicy.canStartFree(
            email: "not-an-email",
            agreed: true,
            isWorking: false
        ))
        XCTAssertTrue(OnboardingSetupPolicy.canStartFree(
            email: " user@example.com ",
            agreed: true,
            isWorking: false
        ))
        XCTAssertFalse(OnboardingSetupPolicy.canStartFree(
            email: "user@example.com",
            agreed: true,
            isWorking: true
        ))
    }

    func testBYOKSetupAcceptsAnyOneProviderOrAllThree() {
        XCTAssertFalse(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["", "", ""],
            agreed: true,
            isWorking: false
        ))
        XCTAssertFalse(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["openai", "", ""],
            agreed: false,
            isWorking: false
        ))
        XCTAssertTrue(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["", "anthropic", ""],
            agreed: true,
            isWorking: false
        ))
        XCTAssertTrue(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["openai", "anthropic", "gemini"],
            agreed: true,
            isWorking: false
        ))
    }

    func testBYOKSetupWaitsForLocalWhisperBeforeFinishing() {
        XCTAssertEqual(
            OnboardingSetupPolicy.localModelPreparationAction(for: .notDownloaded),
            .download
        )
        XCTAssertEqual(
            OnboardingSetupPolicy.localModelPreparationAction(
                for: .downloading(progress: 0.5, downloadedBytes: 100, totalBytes: 200)
            ),
            .wait
        )
        XCTAssertEqual(
            OnboardingSetupPolicy.localModelPreparationAction(for: .failed(reason: "Network error")),
            .download
        )
        XCTAssertEqual(
            OnboardingSetupPolicy.localModelPreparationAction(for: .ready(version: "test-model")),
            .finish
        )
    }

    func testSharedEmailThenBYOKKeysTransitionKeepsLegacyRestartStateSynchronized() {
        let defaults = UserDefaults.ephemeralPreview()
        let state = OnboardingState(defaults: defaults)

        state.showPathSelection()
        XCTAssertEqual(state.currentScreen, .mode)
        state.beginBYOKKeys()

        XCTAssertEqual(state.onboardingPath, .byok)
        XCTAssertEqual(state.currentScreen, .keys)
        XCTAssertEqual(state.currentStep, .email)
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.path), "byok")
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.screen), "keys")

        state.returnToPathSelection()
        XCTAssertEqual(state.currentScreen, .mode)
        XCTAssertEqual(state.currentStep, .email)
    }

    func testFinishingEitherSetupPathLandsOnPermissions() {
        for path in OnboardingPath.allCases {
            let state = OnboardingState(defaults: .ephemeralPreview())
            state.selectPath(path)

            state.finishSetup()

            XCTAssertEqual(state.onboardingPath, path)
            XCTAssertEqual(state.currentScreen, .permissions)
            XCTAssertEqual(state.currentStep, .permissions)
        }
    }
}
