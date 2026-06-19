//
//  CursorTracker.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 1) — the continuous cursor track (§7). Pointing
//  is usually a HOVER, not a click, so the Phase-1 click layer is too sparse to
//  resolve "make *this* bigger" to an element. This samples the global cursor at
//  ~30Hz and records where it rested, on the same clock as the clicks/frames/
//  transcript, so the deixis resolver (M4) can find the dwell under each
//  referring expression.
//
//  Why POLLING, not a `.mouseMoved` monitor (§7, research-confirmed):
//    • A move monitor emits NOTHING while the cursor is still — but a still
//      cursor IS the dwell we must detect. Polling samples the rest too.
//    • A GLOBAL mouse poll needs NO permission (unlike key/Input-Monitoring),
//      so the cursor track adds zero to Dev Mode's permission footprint.
//
//  Clock + coordinate space mirror `RecordingSession`'s click capture EXACTLY:
//  `seconds` = SuspendingClock since the session's first-sample anchor ×
//  `clockMultiplier`; `x`/`y` = `[0,1]` top-left within the captured region via
//  `RecordingSession.normalizedClick`. So a cursor sample, a click, and a
//  keyframe with the same timestamp describe the same instant.
//
//  Owned by `RecordingSession`, started only for a Dev Mode recording. The clock
//  + location sources are injectable so the sampler is deterministically testable
//  without a live capture.
//

import Foundation
import AppKit

@MainActor
final class CursorTracker {

    /// ~30Hz. Fast enough to catch a brief hover-dwell, slow enough to stay
    /// negligible (one `NSEvent.mouseLocation` read + an append per tick).
    static let interval: Duration = .milliseconds(33)

    /// Captured samples, in capture order (monotonic `seconds`). Read once at
    /// `stop()`.
    private(set) var samples: [CursorSample] = []

    /// Captured region in GLOBAL AppKit coords (points, bottom-left) — the
    /// selection rect, else the display frame. The SAME rect clicks normalize
    /// against.
    private let region: CGRect
    /// The session's SuspendingClock anchor (recording-zero). Cursor `seconds`
    /// are measured from here, identically to clicks.
    private let anchor: SuspendingClock.Instant
    /// Encoded-vs-wall clock correction, applied to `seconds` exactly as clicks
    /// and the elapsed ticker apply it.
    private let clockMultiplier: Double
    /// Injectable clock + cursor reads so the sampler is unit-testable.
    private let now: @MainActor () -> SuspendingClock.Instant
    private let location: @MainActor () -> CGPoint

    private var task: Task<Void, Never>?

    init(
        region: CGRect,
        anchor: SuspendingClock.Instant,
        clockMultiplier: Double,
        now: @escaping @MainActor () -> SuspendingClock.Instant = { SuspendingClock().now },
        location: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.region = region
        self.anchor = anchor
        self.clockMultiplier = clockMultiplier
        self.now = now
        self.location = location
    }

    /// Begin polling. Idempotent. The loop mirrors `RecordingSession`'s elapsed
    /// publish task (a self-driven `Task` sleep, independent of frame arrival).
    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                self.sampleOnce()
            }
        }
    }

    /// Take one sample. Appends `(t, x, y)` when the cursor is inside the captured
    /// region; drops an out-of-region position (the cursor is on the pill, another
    /// window, or another display — nothing in-frame to point at), exactly as
    /// clicks are dropped. Separated from the timer so tests can drive it with an
    /// injected clock + locations.
    func sampleOnce() {
        guard let n = RecordingSession.normalizedClick(global: location(), in: region) else { return }
        let t = Self.seconds(from: anchor, to: now()) * clockMultiplier
        samples.append(CursorSample(seconds: t, x: n.x, y: n.y))
    }

    /// Stop polling and return the captured track.
    @discardableResult
    func stop() -> [CursorSample] {
        task?.cancel()
        task = nil
        return samples
    }

    /// Seconds between two SuspendingClock instants as a Double (seconds +
    /// attoseconds), matching `RecordingSession.seconds(since:)` so the cursor
    /// track shares the clicks' timescale.
    static func seconds(from start: SuspendingClock.Instant, to end: SuspendingClock.Instant) -> Double {
        let d = start.duration(to: end)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
