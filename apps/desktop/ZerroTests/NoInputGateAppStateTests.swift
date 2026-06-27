//
//  NoInputGateAppStateTests.swift
//  ZerroTests
//
//  Layer 0 — the AppState-level contract for the local no-input gate.
//
//  `RecordingInputGateTests` pins the pure predicate; this pins the wiring:
//  `runPromptGeneration(processed:)` consults the gate FIRST, so a recording with
//  no on-device signal (silent audio AND no clicks) is short-circuited to the
//  friendly `.noInputCaptured` failure BEFORE any analytics, route resolution, or
//  provider/local dispatch — and its working directory is discarded rather than
//  held for a paid resume.
//
//  Zero-dispatch proof without a stub proxy: the gate returns synchronously with
//  `.failed(.noInputCaptured)`. A real dispatch (managed/trial/BYOK) instead
//  leaves `state == .processing` with an in-flight task and would NEVER produce
//  this terminal state on the calling turn — so the synchronous outcome alone
//  distinguishes "gated" from "dispatched". The test therefore never starts a
//  real generation (no network/keychain in a unit test).
//

import XCTest
import CoreMedia
@testable import Zerro

@MainActor
final class NoInputGateAppStateTests: XCTestCase {

    /// A no-input recording (silent + clickless) is skipped at the routing entry:
    /// it lands on `.noInputCaptured` synchronously and the held-recording ref is
    /// torn down (never resumed as a pending paid generation).
    ///
    /// We assert the SYNCHRONOUS teardown — the billing-relevant guarantee — not
    /// the on-disk delete: `WorkingDirectory.remove(at:)` is a deliberate no-op
    /// under the test scheme's `-RetainEvalArtifacts YES`, and disk cleanup is
    /// best-effort/never load-bearing regardless. `processedRecording == nil` is
    /// what determines that the recording can't be resumed or charged.
    func testNoInputRecordingSkipsGenerationWithoutDispatch() throws {
        let app = AppState()

        // A real on-disk working directory, like the pipeline produces.
        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerro-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDir) }

        let processed = ProcessedRecording(
            audioURL: workingDir.appendingPathComponent("audio.m4a"),
            frames: [],
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            workingDirectory: workingDir,
            clicks: [],          // no clicks …
            hasSpeech: false     // … and silent → the gate fires
        )

        // Drive the routing entry exactly as the post-processing handoff does.
        app.state = .processing
        app.processedRecording = processed
        app.runPromptGeneration(processed: processed)

        // Gated synchronously, before any dispatch (a real managed/trial/BYOK run
        // would still be `.processing` with an in-flight task here, never this
        // terminal state on the calling turn).
        XCTAssertEqual(app.state, .failed(reason: .noInputCaptured))
        // The held recording is torn down — not retained for a paid resume.
        XCTAssertNil(app.processedRecording)
    }

    /// `.noInputCaptured` is non-retryable: re-running the same silent clip fails
    /// identically, so the pill offers no Retry trap — the fix is to record again.
    func testNoInputCapturedIsNotRetryable() {
        XCTAssertFalse(RecordingFailureReason.noInputCaptured.isRetryable)
    }

    /// The copy reads as informational, not a billing event: it reassures that
    /// nothing was charged.
    func testNoInputUserMessageSaysNothingWasCharged() {
        XCTAssertTrue(
            RecordingFailureReason.noInputCaptured.userMessage.contains("nothing was charged"),
            "Expected the no-input copy to reassure that nothing was charged, got: "
                + RecordingFailureReason.noInputCaptured.userMessage
        )
    }
}
