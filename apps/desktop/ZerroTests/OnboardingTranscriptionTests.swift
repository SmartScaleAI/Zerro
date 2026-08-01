//
//  OnboardingTranscriptionTests.swift
//  ZerroTests
//
//  Phase 3 guards for the explicit BYOK transcription choice.
//

import XCTest
@testable import Zerro

final class OnboardingTranscriptionTests: XCTestCase {
    func testLocalTranscriptionIsAlwaysSelectable() {
        XCTAssertTrue(BYOKTranscriptionPolicy.isSelectable(.local, openAIKeyPresent: false))
        XCTAssertTrue(BYOKTranscriptionPolicy.isSelectable(.local, openAIKeyPresent: true))
    }

    func testCloudTranscriptionRequiresOpenAIKey() {
        XCTAssertFalse(BYOKTranscriptionPolicy.isSelectable(.cloud, openAIKeyPresent: false))
        XCTAssertTrue(BYOKTranscriptionPolicy.isSelectable(.cloud, openAIKeyPresent: true))
    }

    func testContinueRequiresAnAvailableExplicitChoice() {
        XCTAssertFalse(BYOKTranscriptionPolicy.canContinue(
            selection: nil,
            openAIKeyPresent: true
        ))
        XCTAssertFalse(BYOKTranscriptionPolicy.canContinue(
            selection: .cloud,
            openAIKeyPresent: false
        ))
        XCTAssertTrue(BYOKTranscriptionPolicy.canContinue(
            selection: .local,
            openAIKeyPresent: false
        ))
    }

    func testUnavailableCloudPreferenceDoesNotSilentlyFallBackToLocal() {
        XCTAssertNil(BYOKTranscriptionPolicy.restoredSelection(
            preference: .cloud,
            openAIKeyPresent: false
        ))
        XCTAssertEqual(
            BYOKTranscriptionPolicy.restoredSelection(
                preference: .cloud,
                openAIKeyPresent: true
            ),
            .cloud
        )
    }

    func testAutoPreferenceStillRequiresAnExplicitOnboardingChoice() {
        XCTAssertNil(BYOKTranscriptionPolicy.restoredSelection(
            preference: .auto,
            openAIKeyPresent: true
        ))
    }
}
