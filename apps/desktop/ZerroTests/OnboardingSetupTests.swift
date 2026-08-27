//
//  OnboardingSetupTests.swift
//  ZerroTests
//
//  Guards for the Setup screen's policy and its transitions into the
//  provider-key, transcription, and permissions steps.
//

import XCTest
@testable import Zerro

@MainActor
final class OnboardingSetupTests: XCTestCase {
    func testBYOKSetupAcceptsAnyOneProviderOrAllThree() {
        XCTAssertFalse(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["", "", ""],
            isWorking: false
        ))
        XCTAssertFalse(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["openai", "", ""],
            isWorking: true
        ))
        XCTAssertTrue(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["", "anthropic", ""],
            isWorking: false
        ))
        XCTAssertTrue(OnboardingSetupPolicy.canContinueBYOK(
            keys: ["openai", "anthropic", "gemini"],
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

    func testSetupToKeysTransitionKeepsLegacyRestartStateSynchronized() {
        let defaults = UserDefaults.ephemeralPreview()
        let state = OnboardingState(defaults: defaults)

        state.beginBYOKKeys()

        XCTAssertEqual(state.onboardingPath, .byok)
        XCTAssertEqual(state.currentScreen, .keys)
        XCTAssertEqual(state.currentStep, .email)
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.path), "byok")
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.screen), "keys")

        state.moveBack()
        XCTAssertEqual(state.currentScreen, .setup)
    }

    func testFinishingSetupLandsOnPermissions() {
        let state = OnboardingState(defaults: .ephemeralPreview())
        state.beginBYOKKeys()

        state.finishSetup()

        XCTAssertEqual(state.onboardingPath, .byok)
        XCTAssertEqual(state.currentScreen, .permissions)
        XCTAssertEqual(state.currentStep, .permissions)
    }
}
