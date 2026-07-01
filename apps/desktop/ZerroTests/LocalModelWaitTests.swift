//
//  LocalModelWaitTests.swift
//  ZerroTests
//
//  Phase 6 (Local Whisper) — the pure pieces of the recording-time wait-for-model
//  behavior: the `shouldWaitForLocalModel` engine × state truth table, the
//  `.localModelUnavailable` error-tracker gating, and the steady progress label.
//  All three are pure/static, so they run without a recording, a manager, or the
//  network. The pipeline-level wait (downloading → ready → transcribe locally;
//  downloading → failed → `.localModelUnavailable`) lives in
//  `AppStateTranscriptionRoutingTests`.
//

import XCTest
@testable import Zerro

@MainActor
final class LocalModelWaitTests: XCTestCase {

    // MARK: - shouldWaitForLocalModel truth table

    /// {auto, local, cloud} × {notDownloaded, downloading, ready, failed} — only
    /// `.downloading × {auto, local}` waits. `.cloud` always transcribes via OpenAI
    /// (never waits on the on-device model); any non-`.downloading` state has
    /// nothing in flight to wait on.
    func testShouldWaitTruthTable() {
        let downloading = LocalModelManager.State.downloading(progress: 0.5, downloadedBytes: 100, totalBytes: 200)
        let cases: [(name: String, state: LocalModelManager.State)] = [
            ("notDownloaded", .notDownloaded),
            ("downloading", downloading),
            ("ready", .ready(version: "test-v1")),
            ("failed", .failed(reason: "boom")),
        ]

        for engine in STTEngine.allCases {
            for c in cases {
                let expected = (c.name == "downloading") && (engine != .cloud)
                XCTAssertEqual(
                    AppState.shouldWaitForLocalModel(engine: engine, managerState: c.state),
                    expected,
                    "engine=\(engine.rawValue) state=\(c.name) should\(expected ? "" : " NOT") wait"
                )
            }
        }
    }

    /// Spelled-out spot checks of the four true/false corners, so a regression
    /// names the exact pairing that broke.
    func testShouldWaitCorners() {
        let downloading = LocalModelManager.State.downloading(progress: 0.1, downloadedBytes: 1, totalBytes: 10)
        // The two waits.
        XCTAssertTrue(AppState.shouldWaitForLocalModel(engine: .auto, managerState: downloading))
        XCTAssertTrue(AppState.shouldWaitForLocalModel(engine: .local, managerState: downloading))
        // Cloud never waits, even mid-download.
        XCTAssertFalse(AppState.shouldWaitForLocalModel(engine: .cloud, managerState: downloading))
        // No download in flight → never wait (the absent-model path resolves
        // straight to the failure pill).
        XCTAssertFalse(AppState.shouldWaitForLocalModel(engine: .auto, managerState: .notDownloaded))
        XCTAssertFalse(AppState.shouldWaitForLocalModel(engine: .local, managerState: .ready(version: "v")))
        XCTAssertFalse(AppState.shouldWaitForLocalModel(engine: .local, managerState: .failed(reason: "x")))
    }

    // MARK: - shouldCapture gating

    /// A missing/undownloaded on-device model is a user/environment condition with
    /// actionable copy (like `.apiKeyMissing`) — NOT a Zerro bug, so it must NOT
    /// reach the error tracker.
    func testLocalModelUnavailableIsNotCaptured() {
        XCTAssertFalse(
            AppState.shouldCapture(.localModelUnavailable),
            "a missing on-device model is a user/environment condition, not a captured bug"
        )
        // Mirrors `.apiKeyMissing`, which is likewise not captured.
        XCTAssertFalse(AppState.shouldCapture(.apiKeyMissing))
        // Sanity: a genuine engineering failure still captures, so the gate isn't
        // just returning false for everything.
        XCTAssertTrue(AppState.shouldCapture(.processingFailed))
    }

    // MARK: - Progress label

    /// Whole megabytes, "X MB / Y MB", matching the Settings download row.
    func testWaitLabelFormat() {
        let label = AppState.localModelWaitLabel(
            downloadedBytes: 312 * 1_048_576,
            totalBytes: 547 * 1_048_576
        )
        XCTAssertEqual(label, "Finishing on-device setup\u{2026} 312 MB / 547 MB")
    }

    /// Negative/garbage byte counts clamp to 0 MB rather than rendering a negative.
    func testWaitLabelClampsNegative() {
        let label = AppState.localModelWaitLabel(downloadedBytes: -5, totalBytes: -1)
        XCTAssertEqual(label, "Finishing on-device setup\u{2026} 0 MB / 0 MB")
    }

    // MARK: - Failure copy

    /// The dedicated reason carries its own short label + actionable detail that
    /// points the user at Settings (download) and names the OpenAI-cloud fallback —
    /// distinct from the generic `.processingFailed` placeholder it replaced.
    func testLocalModelUnavailableCopyIsActionable() {
        let reason = RecordingFailureReason.localModelUnavailable
        XCTAssertEqual(reason.headline, "Model needed")
        XCTAssertNotEqual(reason.headline, RecordingFailureReason.processingFailed.headline)
        XCTAssertTrue(reason.detail.contains("Settings"), "detail points at Settings to download the model")
        XCTAssertTrue(reason.detail.contains("OpenAI"), "detail names the cloud fallback")
        // Non-retryable in place (mirrors `.apiKeyMissing`): the Retry button
        // reopens the area selector to re-record once the model is downloaded.
        XCTAssertFalse(reason.isRetryable)
    }
}
