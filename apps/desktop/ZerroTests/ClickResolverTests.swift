//
//  ClickResolverTests.swift
//  ZerroTests
//
//  Phase 4 — the pure pieces of click capture → resolution → interleave:
//    (a) coordinate normalization (RecordingSession.normalizedClick)
//    (b) click → label hit-testing (ClickResolver.label / .resolve)
//    (c) Interleaver.merge ordering with clicks (frame < click < speech)
//

import CoreGraphics
import CoreMedia
import XCTest
@testable import Zerro

final class ClickResolverTests: XCTestCase {

    // MARK: - (a) Coordinate normalization

    /// A region in global AppKit coords (points, bottom-left origin). The click
    /// at its geometric center normalizes to (0.5, 0.5) regardless of origin.
    func testNormalizeCenterOfRegion() throws {
        let region = CGRect(x: 100, y: 100, width: 200, height: 400) // maxY = 500
        let n = try XCTUnwrap(RecordingSession.normalizedClick(global: CGPoint(x: 200, y: 300), in: region))
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
    }

    /// The bottom-left→top-left flip: the region's TOP-LEFT screen corner
    /// (minX, maxY in bottom-left space) maps to normalized (0, 0).
    func testNormalizeTopLeftOrigin() throws {
        let region = CGRect(x: 100, y: 100, width: 200, height: 400) // top edge = y 500
        let n = try XCTUnwrap(RecordingSession.normalizedClick(global: CGPoint(x: 100, y: 500), in: region))
        XCTAssertEqual(n.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.0, accuracy: 1e-9)
        // …and the BOTTOM-RIGHT screen corner maps to (1, 1).
        let m = try XCTUnwrap(RecordingSession.normalizedClick(global: CGPoint(x: 300, y: 100), in: region))
        XCTAssertEqual(m.x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(m.y, 1.0, accuracy: 1e-9)
    }

    /// A click outside the captured region is dropped (nil) — both axes guarded.
    func testNormalizeOutsideRegionDropped() {
        let region = CGRect(x: 100, y: 100, width: 200, height: 400)
        XCTAssertNil(RecordingSession.normalizedClick(global: CGPoint(x: 50, y: 300), in: region), "left of region")
        XCTAssertNil(RecordingSession.normalizedClick(global: CGPoint(x: 350, y: 300), in: region), "right of region")
        XCTAssertNil(RecordingSession.normalizedClick(global: CGPoint(x: 200, y: 90), in: region), "below region")
        XCTAssertNil(RecordingSession.normalizedClick(global: CGPoint(x: 200, y: 520), in: region), "above region")
    }

    /// A degenerate (zero-size) region never normalizes.
    func testNormalizeDegenerateRegion() {
        XCTAssertNil(RecordingSession.normalizedClick(global: CGPoint(x: 0, y: 0), in: .zero))
    }

    // MARK: - (b) Click → label hit-testing

    /// Boxes are Vision's normalized BOTTOM-LEFT bounding boxes; the click is
    /// normalized TOP-LEFT. A click inside a label's box returns that label.
    private let demoLines = [
        OCRTextLine(text: "Book a Free Demo", box: CGRect(x: 0.30, y: 0.80, width: 0.20, height: 0.06)),
        OCRTextLine(text: "Sign in", box: CGRect(x: 0.70, y: 0.80, width: 0.10, height: 0.06)),
        OCRTextLine(text: "Footer note", box: CGRect(x: 0.10, y: 0.05, width: 0.30, height: 0.04)),
    ]

    func testHitTestContainingBox() {
        // Top-left click over "Book a Free Demo": x 0.40 within [0.30,0.50];
        // top-left y 0.17 → bottom-left 0.83 within [0.80,0.86].
        let label = ClickResolver.label(forClickX: 0.40, y: 0.17, lines: demoLines)
        XCTAssertEqual(label, "Book a Free Demo")
    }

    func testHitTestMissReturnsNil() {
        // Dead center of the screen — no box there, and nothing within radius.
        XCTAssertNil(ClickResolver.label(forClickX: 0.5, y: 0.5, lines: demoLines))
    }

    func testHitTestNearestWithinRadius() {
        // Just ABOVE the "Sign in" box (center 0.75, 0.83 in bottom-left), within
        // the default radius of its CENTER → resolves to it via the
        // nearest-center fallback. Box top edge (bottom-left) = 0.86; click at
        // bottom-left y 0.865 (top-left y 0.135) is ~0.035 from center (< 0.04),
        // and outside the box.
        let label = ClickResolver.label(forClickX: 0.75, y: 0.135, lines: demoLines)
        XCTAssertEqual(label, "Sign in")
    }

    func testHitTestBeyondRadiusIsNil() {
        // Far from every box, beyond the radius → no label.
        XCTAssertNil(ClickResolver.label(forClickX: 0.95, y: 0.5, lines: demoLines, radius: 0.04))
    }

    func testHitTestSmallestContainingWins() {
        // Two overlapping boxes contain the point; the tighter (smaller-area) one
        // is the more specific label and wins.
        let lines = [
            OCRTextLine(text: "Outer container", box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80)),
            OCRTextLine(text: "Inner button", box: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)),
        ]
        // Point inside both (center).
        let label = ClickResolver.label(forClickX: 0.5, y: 0.5, lines: lines)
        XCTAssertEqual(label, "Inner button")
    }

    func testHitTestSkipsBlankLabels() {
        let lines = [OCRTextLine(text: "   ", box: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))]
        XCTAssertNil(ClickResolver.label(forClickX: 0.5, y: 0.5, lines: lines))
    }

    /// A secret-bearing OCR line yields a label with `[REDACTED]`, never the raw
    /// secret — the resolver masks the label even if the line text arrived
    /// un-masked (structural defense against a click-label PII leak).
    func testHitTestRedactsSecretInLabel() {
        let secret = "colin@smartaiscaling.c..." // UI-truncated email
        let lines = [OCRTextLine(text: "Owner \(secret)", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))]
        let label = ClickResolver.label(forClickX: 0.5, y: 0.5, lines: lines)
        XCTAssertNotNil(label)
        XCTAssertFalse(label?.contains("smartaiscaling") ?? true, "raw secret leaked: \(label ?? "nil")")
        XCTAssertTrue(label?.contains("[REDACTED]") ?? false, "expected [REDACTED] in \(label ?? "nil")")
    }

    // MARK: - resolve() — nearest frame in time + drop when no label

    private func frame(at seconds: Double, index: Int, lines: [OCRTextLine]) -> ExtractedFrame {
        ExtractedFrame(
            url: URL(fileURLWithPath: "/tmp/frame-\(index).jpg"),
            timestamp: CMTime(seconds: seconds, preferredTimescale: 600),
            index: index,
            ocrText: nil,
            lines: lines
        )
    }

    func testResolvePicksNearestFrameInTime() {
        let frames = [
            frame(at: 1.0, index: 0, lines: [OCRTextLine(text: "Early", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))]),
            frame(at: 9.0, index: 1, lines: [OCRTextLine(text: "Late", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))]),
        ]
        // Click at t=8 (closer to the 9s frame), centered on the box.
        let resolved = ClickResolver.resolve(clicks: [RecordedClick(seconds: 8.0, x: 0.5, y: 0.5)], frames: frames)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.label, "Late")
        XCTAssertEqual(resolved.first?.seconds, 8.0)
    }

    func testResolveDropsClickWithNoHit() {
        let frames = [frame(at: 1.0, index: 0, lines: [OCRTextLine(text: "Corner", box: CGRect(x: 0.0, y: 0.0, width: 0.05, height: 0.05))])]
        // Click far from the only box → no label → dropped (no ResolvedClick).
        let resolved = ClickResolver.resolve(clicks: [RecordedClick(seconds: 1.0, x: 0.9, y: 0.9)], frames: frames)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testResolveDropsClickWhenNoFrames() {
        let resolved = ClickResolver.resolve(clicks: [RecordedClick(seconds: 1.0, x: 0.5, y: 0.5)], frames: [])
        XCTAssertTrue(resolved.isEmpty)
    }

    func testResolveEmptyClicks() {
        let frames = [frame(at: 1.0, index: 0, lines: [])]
        XCTAssertTrue(ClickResolver.resolve(clicks: [], frames: frames).isEmpty)
    }

    // MARK: - (c) Interleaver.merge ordering with clicks

    private func makeFrame(at seconds: Double, index: Int) -> ExtractedFrame {
        ExtractedFrame(
            url: URL(fileURLWithPath: "/tmp/frame-\(index).jpg"),
            timestamp: CMTime(seconds: seconds, preferredTimescale: 600),
            index: index
        )
    }

    /// At an equal start second the tie-break is frame < click < speech.
    func testMergeTieBreakFrameClickSpeech() {
        let timeline = Interleaver.merge(
            frames: [makeFrame(at: 5.0, index: 0)],
            transcript: Transcript(segments: [TranscriptSegment(start: 5.0, end: 8.0, text: "hello")], fullText: "hello"),
            clicks: [ResolvedClick(seconds: 5.0, label: "OK")]
        )
        XCTAssertEqual(timeline.items.count, 3)
        guard case .frame = timeline.items[0] else { return XCTFail("expected frame first, got \(timeline.items[0])") }
        guard case .click(_, let label) = timeline.items[1] else { return XCTFail("expected click second, got \(timeline.items[1])") }
        XCTAssertEqual(label, "OK")
        guard case .speech = timeline.items[2] else { return XCTFail("expected speech third, got \(timeline.items[2])") }
    }

    /// Overall chronological order is preserved across mixed item kinds.
    func testMergeChronological() {
        let timeline = Interleaver.merge(
            frames: [makeFrame(at: 0.0, index: 0), makeFrame(at: 6.0, index: 1)],
            transcript: Transcript(segments: [TranscriptSegment(start: 2.0, end: 4.0, text: "a")], fullText: "a"),
            clicks: [ResolvedClick(seconds: 3.0, label: "Save"), ResolvedClick(seconds: 7.0, label: "Close")]
        )
        let starts = timeline.items.map(\.startTime)
        XCTAssertEqual(starts, starts.sorted(), "timeline must be ascending by start time")
        // Spot-check the click at t=3 lands between the speech (2–4) and frame@6.
        guard case .click(_, let label3) = timeline.items[2] else {
            return XCTFail("expected click at index 2, got \(timeline.items[2])")
        }
        XCTAssertEqual(label3, "Save")
    }

    /// An empty-label click is dropped from the merge (nothing to render).
    func testMergeDropsEmptyLabelClick() {
        let timeline = Interleaver.merge(
            frames: [makeFrame(at: 0.0, index: 0)],
            transcript: Transcript(segments: [], fullText: ""),
            clicks: [ResolvedClick(seconds: 1.0, label: "")]
        )
        XCTAssertEqual(timeline.items.count, 1)
        guard case .frame = timeline.items[0] else { return XCTFail("expected only the frame") }
    }

    /// The rendered click line matches the byte-exact payload format.
    func testClickRendersInDebugDescription() {
        let timeline = Interleaver.merge(
            frames: [],
            transcript: Transcript(segments: [], fullText: ""),
            clicks: [ResolvedClick(seconds: 65.0, label: "Book a Free Demo")]
        )
        XCTAssertEqual(timeline.debugDescription, "[1:05] clicked \"Book a Free Demo\"")
    }
}
