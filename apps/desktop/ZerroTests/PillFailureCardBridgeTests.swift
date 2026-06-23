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
        XCTAssertEqual(headline, RecordingFailureReason.networkOffline.headline,
                       "the expanded card now shows the reason's specific headline")
        XCTAssertEqual(detail, "A server with the specified hostname could not be found.")
    }

    func testRetryableFailureFallsBackToReasonDetailWhenDetailNil() {
        let appState = AppState()
        appState.processedRecording = makeProcessedRecording()
        appState.lastFailureDetail = nil
        appState.state = .failed(reason: .providerUnavailable)

        guard case .failureExpanded(_, let detail) = appState.pillState else {
            return XCTFail("retryable failure should map to .failureExpanded")
        }
        XCTAssertEqual(detail, RecordingFailureReason.providerUnavailable.detail,
                       "nil raw detail must fall back to the reason's elaborate detail so the body is never empty")
    }

    func testNonRetryableFailureKeepsCompactErrorPill() {
        let appState = AppState()
        // Missing API key is non-retryable; even with a processed recording the
        // bridge must keep the small amber capsule.
        appState.processedRecording = makeProcessedRecording()
        appState.lastFailureDetail = "should be ignored"
        appState.state = .failed(reason: .apiKeyMissing)

        XCTAssertFalse(appState.canRetryFailure)

        guard case .error(let headline, let detail, let retryable) = appState.pillState else {
            return XCTFail("non-retryable failure should map to .error, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(headline, RecordingFailureReason.apiKeyMissing.headline)
        XCTAssertEqual(detail, RecordingFailureReason.apiKeyMissing.detail)
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
        guard case .error(_, _, let retryable) = appState.pillState else {
            return XCTFail("a retryable reason with no processed recording should map to .error")
        }
        XCTAssertFalse(retryable)
    }

    // MARK: - Out-of-credits: record-START block vs post-capture

    /// Record-START out-of-credits (preflight gate, nothing captured): the
    /// `presentPreflightBlock` path carries the start-specific
    /// `.outOfCreditsAtStart` reason and routes to the dedicated
    /// `.outOfCreditsStart` pill — NOT the Cancel/Retry `.error` card (the bug
    /// reproduced before this fix) nor the post-capture Discard/Upgrade resume
    /// card. Non-retryable, not a paid block, start-oriented copy, no Retry.
    func testOutOfCreditsAtStartMapsToStartPillNoRetry() {
        let appState = AppState()
        appState.processedRecording = nil // nothing captured at record-start
        appState.presentPreflightBlock(.outOfCredits)

        // The preflight block carries the start reason, not post-capture `.outOfCredits`.
        guard case .failed(let reason) = appState.state else {
            return XCTFail("expected .failed, got \(appState.state)")
        }
        XCTAssertEqual(reason, .outOfCreditsAtStart)
        XCTAssertFalse(reason.isRetryable)
        // Not a paid block → no held recording / resume affordance.
        XCTAssertNil(PaidBlockReason(reason))
        XCTAssertFalse(appState.canRetryFailure)
        XCTAssertFalse(appState.canResumePaidGeneration)

        // The pill is the start-block card, never `.error` (Cancel/Retry) or
        // `.paidBlockResume` (Discard/Upgrade).
        guard case .outOfCreditsStart(let headline, let detail) = appState.pillState else {
            return XCTFail("record-start out-of-credits should map to .outOfCreditsStart, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(headline, "Out of credits")
        XCTAssertEqual(detail, RecordingFailureReason.outOfCreditsAtStart.detail)
        // Start-appropriate copy: none of the finish/resume phrasing.
        XCTAssertFalse(detail.contains("finish this recording"), "start copy: \(detail)")
        XCTAssertFalse(detail.contains("this recording stay available"), "start copy: \(detail)")
        XCTAssertTrue(detail.contains("start a new recording"), "start copy: \(detail)")
    }

    /// The start block sets the `.outOfCredits` paywall trigger so the pill's
    /// "Add Credits" primary opens the top-up paywall with the right copy and
    /// `paywall_shown.trigger`.
    func testOutOfCreditsAtStartSetsTopUpPaywallTrigger() {
        let appState = AppState()
        let entitlements = EntitlementStore.preview(.managed(creditsRemaining: 0, resetDate: Date()))
        appState.entitlements = entitlements

        appState.presentPreflightBlock(.outOfCredits)

        XCTAssertEqual(entitlements.paywallTrigger, .outOfCredits,
                       "the start block must route the paywall to the top-up copy")
        // Keep a strong ref alive past the assertion (AppState holds it weakly).
        withExtendedLifetime(entitlements) {}
    }

    /// POST-CAPTURE out-of-credits (the 402 after a recording was captured, held
    /// on disk): unchanged. Keeps the `.outOfCredits` resume reason and the
    /// `.paidBlockResume` Discard/Upgrade card with the finish/resume copy.
    func testPostCaptureOutOfCreditsKeepsResumePill() {
        let appState = AppState()
        appState.processedRecording = makeProcessedRecording() // captured, held on disk
        appState.state = .failed(reason: .outOfCredits)

        XCTAssertTrue(appState.canResumePaidGeneration)
        guard case .paidBlockResume(let headline, let detail, let entitled) = appState.pillState else {
            return XCTFail("post-capture out-of-credits should map to .paidBlockResume, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(headline, RecordingFailureReason.outOfCredits.headline)
        XCTAssertEqual(detail, RecordingFailureReason.outOfCredits.detail)
        // The post-capture copy is finish/resume-oriented — kept intact.
        XCTAssertTrue(detail.contains("this recording stay available"), "resume copy: \(detail)")
        XCTAssertFalse(entitled, "no entitlement wired → label is Upgrade, not Generate")
    }

    func testPaidBlockWithHeldRecordingMapsToResumePill() {
        let appState = AppState()
        // A paid block (trial credits exhausted) with a held recording → the
        // dedicated resume pill, not the compact .error capsule. With no
        // entitlements wired, `canGenerate` is false → the primary button reads
        // "Upgrade" (entitled == false).
        appState.processedRecording = makeProcessedRecording()
        appState.state = .failed(reason: .trialCreditsExhausted)

        XCTAssertTrue(appState.canResumePaidGeneration)
        guard case .paidBlockResume(let headline, let detail, let entitled) = appState.pillState else {
            return XCTFail("a paid block with a held recording should map to .paidBlockResume, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(headline, RecordingFailureReason.trialCreditsExhausted.headline)
        XCTAssertEqual(detail, RecordingFailureReason.trialCreditsExhausted.detail)
        XCTAssertFalse(entitled, "no entitlement wired → label is Upgrade, not Generate")
    }
}
