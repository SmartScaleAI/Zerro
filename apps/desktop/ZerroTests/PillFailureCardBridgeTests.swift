//
//  PillFailureCardBridgeTests.swift
//  ZerroTests
//
//  Pins the `.failed` → pill mapping for the expanded failure card: a
//  RETRYABLE failure (with a processed recording still on disk, under the
//  retry cap) maps to `.failureExpanded` carrying the real error detail; a
//  non-retryable failure keeps the compact `.error` capsule unchanged.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class PillFailureCardBridgeTests: XCTestCase {

    /// A throwaway processed recording so `canRetryFailure`'s
    /// `processedRecording != nil` precondition is met. The URLs/CMTime are
    /// never read by the bridge — only the non-nil-ness matters.
    private func makeProcessedRecording() -> ProcessedRecording {
        ProcessedRecording(
            audioURL: URL(fileURLWithPath: "/tmp/zerro-test/audio.m4a"),
            frames: [],
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            workingDirectory: URL(fileURLWithPath: "/tmp/zerro-test"),
            clicks: [],
            hasSpeech: true
        )
    }

    func testRetryableFailureMapsToExpandedCardWithRealDetail() {
        let appState = AppState()
        appState.processedRecording = makeProcessedRecording()
        appState.lastFailureDetail = "A server with the specified hostname could not be found."
        appState.state = .failed(reason: .networkOffline)

        // Precondition: networkOffline is retryable + processed recording present
        // + under the cap.
        XCTAssertTrue(appState.canRetryFailure)

        guard case .failureExpanded(let headline, let detail) = appState.pillState else {
            return XCTFail("retryable failure should map to .failureExpanded, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(headline, "Generation failed")
        XCTAssertEqual(detail, "A server with the specified hostname could not be found.")
    }

    func testRetryableFailureFallsBackToUserMessageWhenDetailNil() {
        let appState = AppState()
        appState.processedRecording = makeProcessedRecording()
        appState.lastFailureDetail = nil
        appState.state = .failed(reason: .providerUnavailable)

        guard case .failureExpanded(_, let detail) = appState.pillState else {
            return XCTFail("retryable failure should map to .failureExpanded")
        }
        XCTAssertEqual(detail, RecordingFailureReason.providerUnavailable.userMessage,
                       "nil detail must fall back to the reason's userMessage so the body is never empty")
    }

    func testNonRetryableFailureKeepsCompactErrorPill() {
        let appState = AppState()
        // Missing API key is non-retryable; even with a processed recording the
        // bridge must keep the small amber capsule.
        appState.processedRecording = makeProcessedRecording()
        appState.lastFailureDetail = "should be ignored"
        appState.state = .failed(reason: .apiKeyMissing)

        XCTAssertFalse(appState.canRetryFailure)

        guard case .error(let message, let retryable) = appState.pillState else {
            return XCTFail("non-retryable failure should map to .error, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(message, RecordingFailureReason.apiKeyMissing.userMessage)
        XCTAssertFalse(retryable)
    }

    func testRetryableFailureWithoutProcessedRecordingKeepsCompactPill() {
        let appState = AppState()
        // No processed recording on disk → nothing to re-run, so even a
        // retryable reason must degrade to the compact pill.
        appState.processedRecording = nil
        appState.lastFailureDetail = "transient blip"
        appState.state = .failed(reason: .networkOffline)

        XCTAssertFalse(appState.canRetryFailure)
        guard case .error(_, let retryable) = appState.pillState else {
            return XCTFail("a retryable reason with no processed recording should map to .error")
        }
        XCTAssertFalse(retryable)
    }
}
