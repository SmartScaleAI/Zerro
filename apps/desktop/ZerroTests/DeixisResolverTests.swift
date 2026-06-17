//
//  DeixisResolverTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 4) — the deixis alignment engine (§7). Pins the
//  load-bearing behaviors: referring-expression detection, the early-biased
//  window, dwell-vs-transit, the click > dwell > last-known priority, and that
//  the resolved point is in normalized frame space.
//

import XCTest
@testable import Zerro

final class DeixisResolverTests: XCTestCase {

    // MARK: - Referring-expression scan

    func testDetectsDeicticsAndDefiniteNounPhrases() {
        let words = phrase("make this the header bigger and that button teal")
        let refs = DeixisResolver.referringExpressions(in: words)
        let phrases = refs.map(\.phrase)
        XCTAssertTrue(phrases.contains("this"), "bare deictic")
        XCTAssertTrue(phrases.contains("the header"), "definite UI noun phrase")
        XCTAssertTrue(phrases.contains("that button"), "demonstrative noun phrase")
    }

    func testIgnoresNonReferringText() {
        let refs = DeixisResolver.referringExpressions(in: phrase("please increase the spacing slightly"))
        // "the spacing" — "spacing" isn't a UI-element noun → not a reference.
        XCTAssertTrue(refs.isEmpty, "ordinary prose yields no referring expressions")
    }

    // MARK: - Dwell vs transit

    func testHoverDwellSelectsTheRestPoint() {
        // "make this bigger": the cursor rests near (0.7, 0.4) during the window.
        let words = phrase("make this bigger", start: 2.0) // "this" ~2.2–2.5s
        var cursor: [CursorSample] = []
        // Transit in from the left up to t≈1.4, then DWELL at (0.7,0.4) from 1.4–2.4.
        for k in 0..<10 { cursor.append(CursorSample(seconds: 0.5 + 0.1 * Double(k), x: 0.1 + 0.05 * Double(k), y: 0.4)) }
        for k in 0..<20 { cursor.append(CursorSample(seconds: 1.4 + 0.05 * Double(k), x: 0.70 + 0.002 * Double(k % 3), y: 0.40)) }

        let anchors = DeixisResolver.resolve(words: words, cursorTrack: cursor)
        let a = anchors.first { $0.phrase == "this" }
        XCTAssertEqual(a?.source, .dwell)
        XCTAssertEqual(a?.point?.x ?? 0, 0.70, accuracy: 0.02, "dwell point is the rest cluster, not the transit")
        XCTAssertEqual(a?.point?.y ?? 0, 0.40, accuracy: 0.02)
        XCTAssertGreaterThan(a?.dwellConfidence ?? 0, 0.6, "a clear rest is high-confidence")
    }

    func testTransitMovementIsLowConfidence() {
        // The cursor sweeps straight across the window — no rest.
        let words = phrase("make this bigger", start: 2.0)
        var cursor: [CursorSample] = []
        for k in 0..<40 { cursor.append(CursorSample(seconds: 1.2 + 0.03 * Double(k), x: 0.05 + 0.02 * Double(k), y: 0.5)) }

        let a = DeixisResolver.resolve(words: words, cursorTrack: cursor).first { $0.phrase == "this" }
        XCTAssertNotNil(a)
        // A pure transit yields a weak dwell signal — exactly what M6 routes to
        // confirmAnchors rather than confidently editing.
        XCTAssertLessThan(a!.dwellConfidence, 0.6, "transit must not read as a confident dwell")
    }

    // MARK: - Priority: click > dwell > last-known

    func testClickInWindowWinsAndIsHighConfidence() {
        let words = phrase("change this now", start: 2.0) // "this" bare (~2.3s)
        // A dwell elsewhere, but a CLICK at 2.1s at (0.3,0.6) should win.
        var cursor: [CursorSample] = []
        for k in 0..<20 { cursor.append(CursorSample(seconds: 1.5 + 0.05 * Double(k), x: 0.8, y: 0.2)) } // dwell at (0.8,0.2)
        cursor.append(CursorSample(seconds: 2.12, x: 0.30, y: 0.60)) // the click position (uniquely nearest 2.12)
        let a = DeixisResolver.resolve(words: words, cursorTrack: cursor, clickTimes: [2.12]).first { $0.phrase == "this" }
        XCTAssertEqual(a?.source, .click)
        XCTAssertEqual(a?.dwellConfidence, 1.0)
        XCTAssertEqual(a?.point?.x ?? 0, 0.30, accuracy: 0.001)
    }

    func testLastKnownWhenCursorLeftTheWindow() {
        let words = phrase("now this part", start: 5.0) // window ~[4.0, 5.x]
        // All cursor samples are BEFORE the window (cursor left the region after).
        let cursor = (0..<10).map { CursorSample(seconds: 1.0 + 0.1 * Double($0), x: 0.5, y: 0.5) }
        let a = DeixisResolver.resolve(words: words, cursorTrack: cursor).first { $0.phrase == "this" }
        XCTAssertEqual(a?.source, .lastKnown)
        XCTAssertLessThan(a!.dwellConfidence, 0.3)
        XCTAssertEqual(a?.point?.x ?? 0, 0.5, accuracy: 0.001)
    }

    func testEmptySpaceYieldsNoPoint() {
        let words = phrase("make this bigger", start: 2.0)
        let a = DeixisResolver.resolve(words: words, cursorTrack: []).first { $0.phrase == "this" }
        XCTAssertEqual(a?.source, CandidateAnchor.Source.none)
        XCTAssertNil(a?.point)
        XCTAssertEqual(a?.dwellConfidence, 0.0)
    }

    func testWindowIsBiasedEarlierThanThePhrase() {
        // The dwell happens 600ms BEFORE "this" is said (pointing precedes
        // speech) — the 800ms lead must still capture it.
        let words = phrase("make this bigger", start: 3.0) // "this" ~3.2–3.5
        let cursor = (0..<15).map { CursorSample(seconds: 2.4 + 0.02 * Double($0), x: 0.55, y: 0.33) }
        let a = DeixisResolver.resolve(words: words, cursorTrack: cursor).first { $0.phrase == "this" }
        XCTAssertEqual(a?.source, .dwell)
        XCTAssertEqual(a?.point?.x ?? 0, 0.55, accuracy: 0.02)
    }

    // MARK: - Helpers

    /// Build evenly-spaced word timings from a sentence, starting at `start`,
    /// ~0.3s per word — enough that windows behave realistically.
    private func phrase(_ text: String, start: TimeInterval = 0.0) -> [WordTiming] {
        var t = start
        var out: [WordTiming] = []
        for w in text.split(separator: " ") {
            out.append(WordTiming(word: String(w), start: t, end: t + 0.25))
            t += 0.3
        }
        return out
    }
}
