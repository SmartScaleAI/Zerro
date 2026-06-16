//
//  MinRecordingDurationTests.swift
//  ZerroTests
//
//  The safety net for the manual-stop minimum-duration floor.
//
//  `AppState.stopRecording` discards a manually-stopped recording shorter than
//  `ProcessingConfig.minRecordingSeconds` instead of processing it. The whole
//  decision is the pure `ProcessingConfig.isBelowMinimumDuration(seconds:)`
//  predicate, factored out exactly so it's exercisable here without a live
//  capture session, writer, or Analytics. These tests are the contract: the
//  boundary is INCLUSIVE at the floor (a clip exactly at the threshold is kept),
//  and the floor value the gate enforces is the same one the `.recordingTooShort`
//  copy interpolates — so they can never drift.
//

import XCTest
@testable import Zerro

final class MinRecordingDurationTests: XCTestCase {

    /// A clip strictly shorter than the floor is discarded — the gate fires.
    func testBelowFloorIsTooShort() {
        XCTAssertTrue(ProcessingConfig.isBelowMinimumDuration(seconds: 0))
        XCTAssertTrue(ProcessingConfig.isBelowMinimumDuration(seconds: 4.9))
        XCTAssertTrue(
            ProcessingConfig.isBelowMinimumDuration(
                seconds: ProcessingConfig.minRecordingSeconds - 0.001
            )
        )
    }

    /// "At least 5 seconds" means exactly the floor is long enough — the boundary
    /// is inclusive, so a clip right at the threshold is KEPT (gate does not fire).
    func testExactlyFloorIsKept() {
        XCTAssertFalse(
            ProcessingConfig.isBelowMinimumDuration(
                seconds: ProcessingConfig.minRecordingSeconds
            )
        )
    }

    /// Anything past the floor is plainly kept.
    func testAboveFloorIsKept() {
        XCTAssertFalse(ProcessingConfig.isBelowMinimumDuration(seconds: 5.1))
        XCTAssertFalse(ProcessingConfig.isBelowMinimumDuration(seconds: 180))
    }

    /// The floor and the auto-stop cap are unrelated ends of the same scale:
    /// the minimum must sit far below the 180s cap, never collide with it.
    func testFloorIsFarBelowAutoStopCap() {
        XCTAssertLessThan(
            ProcessingConfig.minRecordingSeconds,
            ProcessingConfig.maxRecordingSeconds
        )
    }

    /// `.recordingTooShort` is non-retryable: a Retry would just re-show the same
    /// failure — the user records again instead.
    func testRecordingTooShortIsNotRetryable() {
        XCTAssertFalse(RecordingFailureReason.recordingTooShort.isRetryable)
    }

    /// The user-facing copy interpolates the floor from its single source of
    /// truth, so the number in the message always matches the enforced threshold.
    func testUserMessageStatesTheFloor() {
        let message = RecordingFailureReason.recordingTooShort.userMessage
        XCTAssertTrue(
            message.contains("\(Int(ProcessingConfig.minRecordingSeconds)) seconds"),
            "Expected the copy to name the \(Int(ProcessingConfig.minRecordingSeconds))s floor, got: \(message)"
        )
    }
}
