//
//  CursorTrackerTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 1) — the continuous cursor track (§7). Drives
//  `CursorTracker.sampleOnce()` with an injected clock + cursor positions (no live
//  capture) to pin the load-bearing guarantees: samples are monotonic in `t`,
//  rebased to recording-zero, normalized into the captured region, span the full
//  duration, and out-of-region positions are dropped. Plus the sidecar round-trip.
//

import XCTest
@testable import Zerro

@MainActor
final class CursorTrackerTests: XCTestCase {

    // A simple global region (points, bottom-left). Cursor (300,350) is the
    // center → normalized (0.5, 0.5) top-left.
    private let region = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testSamplesAreMonotonicRebasedAndSpanDuration() {
        let base = SuspendingClock().now
        let step = Duration.milliseconds(33)
        var clock = base // advanced one step per `now()` read
        let tracker = CursorTracker(
            region: region,
            anchor: base,
            clockMultiplier: 1.0,
            now: { defer { clock = clock.advanced(by: step) }; return clock },
            location: { CGPoint(x: 300, y: 350) } // center, in-region
        )

        let ticks = 90 // ~3.0s at 33ms
        for _ in 0..<ticks { tracker.sampleOnce() }
        let samples = tracker.stop()

        XCTAssertEqual(samples.count, ticks, "every in-region tick yields a sample")
        // Rebased to recording-zero: the first sample sits at ~0.
        XCTAssertEqual(samples.first!.seconds, 0, accuracy: 0.0005)
        // Monotonic non-decreasing in t.
        for k in 1..<samples.count {
            XCTAssertGreaterThanOrEqual(samples[k].seconds, samples[k - 1].seconds)
        }
        // Spans the full duration (last ≈ (ticks-1) × 33ms).
        XCTAssertEqual(samples.last!.seconds, 0.033 * Double(ticks - 1), accuracy: 0.01)
        // Normalized to the region center, top-left origin (matches frame pixels).
        XCTAssertEqual(samples.first!.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples.first!.y, 0.5, accuracy: 0.0001)
    }

    func testOutOfRegionSamplesAreDropped() {
        let base = SuspendingClock().now
        let tracker = CursorTracker(
            region: region,
            anchor: base,
            clockMultiplier: 1.0,
            now: { base },
            location: { CGPoint(x: 5000, y: 5000) } // far outside the region
        )
        for _ in 0..<10 { tracker.sampleOnce() }
        XCTAssertTrue(tracker.stop().isEmpty, "cursor outside the captured region → no sample (like clicks)")
    }

    func testClockMultiplierScalesTimestamps() {
        let base = SuspendingClock().now
        let step = Duration.milliseconds(100)
        var clock = base
        let tracker = CursorTracker(
            region: region,
            anchor: base,
            clockMultiplier: 2.0, // DEV time-warp — cursor `t` scales identically to clicks/elapsed
            now: { defer { clock = clock.advanced(by: step) }; return clock },
            location: { CGPoint(x: 300, y: 350) }
        )
        tracker.sampleOnce() // wall 0.0  → t 0.0
        tracker.sampleOnce() // wall 0.1  → t 0.2 (×2)
        let samples = tracker.stop()
        XCTAssertEqual(samples[0].seconds, 0.0, accuracy: 0.0005)
        XCTAssertEqual(samples[1].seconds, 0.2, accuracy: 0.001)
    }

    func testCursorSidecarRoundTrips() throws {
        let mov = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-sidecar-\(UUID().uuidString).mov")
        let sidecar = mov.deletingPathExtension().appendingPathExtension("cursor.json")
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let samples = [
            CursorSample(seconds: 0.0, x: 0.1, y: 0.2),
            CursorSample(seconds: 0.5, x: 0.5, y: 0.5),
        ]
        RecordingSession.writeCursorSidecar(samples, beside: mov)

        let decoded = try JSONDecoder().decode([CursorSample].self, from: Data(contentsOf: sidecar))
        XCTAssertEqual(decoded, samples)
    }

    func testEmptyTrackWritesNoSidecar() {
        let mov = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-empty-\(UUID().uuidString).mov")
        let sidecar = mov.deletingPathExtension().appendingPathExtension("cursor.json")
        RecordingSession.writeCursorSidecar([], beside: mov)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "a normal recording (empty track) writes no cursor sidecar")
    }
}
