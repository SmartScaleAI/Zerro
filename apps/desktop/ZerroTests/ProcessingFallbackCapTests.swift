//
//  ProcessingFallbackCapTests.swift
//  ZerroTests
//
//  F-06 — the no-candidates fixed-interval fallback must honor the SAME
//  28-frame ceiling (`ProcessingConfig.maxKeyframes`) the normal selector path
//  enforces. Before the fix it capped at `maxFramesPerMinute * 3` (180 frames),
//  so a long recording whose Pass-1 analysis produced no candidates could ship
//  ~90 frames — a ~6× cost + payload blowout. `fallbackSampleSeconds` is a pure
//  function of the capped duration, so the whole contract is testable without
//  a recording.
//

import XCTest
@testable import Zerro

@MainActor
final class ProcessingFallbackCapTests: XCTestCase {

    /// The F-06 regression: a full-length (180s) no-candidates recording must
    /// yield at most `maxKeyframes` fallback frames, not ~90.
    func testLongRecordingCapsAtMaxKeyframes() {
        let times = ProcessingPipeline.fallbackSampleSeconds(
            cappedDurationSeconds: ProcessingConfig.maxRecordingSeconds
        )
        XCTAssertFalse(times.isEmpty)
        XCTAssertLessThanOrEqual(times.count, ProcessingConfig.maxKeyframes)
    }

    /// Even an abnormal over-cap duration (a malformed container that slipped
    /// a huge duration through) stays under the ceiling.
    func testOverCapDurationStaysUnderCeiling() {
        let times = ProcessingPipeline.fallbackSampleSeconds(cappedDurationSeconds: 3600)
        XCTAssertLessThanOrEqual(times.count, ProcessingConfig.maxKeyframes)
    }

    /// The capped fallback still SPANS the recording (widened stride) rather
    /// than clustering all its frames in the opening minute.
    func testCappedFallbackSpansTheRecording() {
        let duration = ProcessingConfig.maxRecordingSeconds
        let times = ProcessingPipeline.fallbackSampleSeconds(cappedDurationSeconds: duration)
        let widenedInterval = duration / Double(ProcessingConfig.maxKeyframes)
        XCTAssertGreaterThanOrEqual(times.last ?? 0, duration - 2 * widenedInterval)
        // Times are strictly increasing and within the recording.
        XCTAssertEqual(times, times.sorted())
        XCTAssertLessThanOrEqual(times.last ?? 0, duration + 0.001)
    }

    /// A short recording is untouched by the cap — it keeps the legacy
    /// fixed-interval cadence (2s at today's config).
    func testShortRecordingKeepsLegacyCadence() {
        let times = ProcessingPipeline.fallbackSampleSeconds(cappedDurationSeconds: 5)
        XCTAssertEqual(times, [2.0, 4.0])
    }

    /// The min-length guard is preserved: a duration too short to yield even
    /// one sample returns [] so the caller's empty-times guard still throws
    /// `.emptyRecording`.
    func testTooShortYieldsEmpty() {
        XCTAssertTrue(ProcessingPipeline.fallbackSampleSeconds(cappedDurationSeconds: 1).isEmpty)
        XCTAssertTrue(ProcessingPipeline.fallbackSampleSeconds(cappedDurationSeconds: 0).isEmpty)
    }
}
