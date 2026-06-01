//
//  ModeSwitchDetectorTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 5/31/26.
//
//  Phase 18 — unit coverage for the local opposite-mode matcher. The
//  detector is pure string logic, so these are plain value-in/value-out
//  assertions. They drive the pattern-injecting `detect` overload with a
//  FIXED inline pattern set so the tests don't move when the bundled
//  ModeSwitchPatterns.json is tuned. One separate test (bundledPatterns…)
//  verifies the shipped JSON resource is wired and decodes.
//

import XCTest
@testable import Zerro

final class ModeSwitchDetectorTests: XCTestCase {

    // Representative, stable pattern set — a subset of the shipped JSON,
    // pinned here so behavioral assertions don't depend on tuning data.
    private let patterns = ModeSwitchPatterns(
        switchCues: ["instead", "actually", "no wait", "switch to", "make it", "give me", "just",
                     "can you", "could you", "would you", "first", "before"],
        instructTargets: ["instructions", "a prompt", "step by step", "for cursor", "a task"],
        explainTargets: ["an explanation", "explain this", "explain it", "explain", "describe", "walk through"],
        fillerTokens: ["um", "uh", "like", "you know"],
        appNameVariants: ["cursor": ["cursor ai", "cursor"]]
    )

    // MARK: - Helpers

    /// Build a Transcript from (start, end, text) tuples.
    private func transcript(_ segments: [(TimeInterval, TimeInterval, String)]) -> Transcript {
        let segs = segments.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) }
        return Transcript(segments: segs, fullText: segs.map(\.text).joined(separator: " "))
    }

    private func detect(_ t: Transcript, _ mode: OutputMode) -> ModeSwitchDetection {
        ModeSwitchDetector.detect(transcript: t, selectedMode: mode, patterns: patterns)
    }

    // MARK: - Fires

    /// "…actually, just explain this instead" at the END of an Instruct
    /// recording → fires, suggests .explain, .high (.late).
    func testExplainRequestAtEndOfInstructRecordingFiresHigh() {
        let t = transcript([
            (0, 10, "Okay so this is the settings page I'm working on"),
            (10, 20, "and I want to make this save button bigger"),
            (20, 28, "and move it over to the right side"),
            (28, 33, "actually, just explain this instead"),
        ])
        let result = detect(t, .instruct)
        XCTAssertTrue(result.didMatch)
        XCTAssertEqual(result.suggestedMode, .explain)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.region, .late)
        XCTAssertEqual(result.matchedTarget, "explain this")
    }

    /// Polite-request phrasing at the end of an Instruct recording —
    /// "...could you explain the hierarchy before" — fires .explain.
    /// Regression for the real-world test where a "can you/could you …
    /// explain" request was missed because the cue list lacked the
    /// polite-request prefix. The cue ("could you") and the bare target
    /// ("explain") sit adjacent.
    func testPoliteRequestExplainAtEndOfInstructFires() {
        let t = transcript([
            (0, 12, "Reorganize my Xcode project directory into feature folders"),
            (12, 22, "group the services and the surfaces together"),
            (22, 28, "could you explain the hierarchy of the directory first"),
        ])
        let result = detect(t, .instruct)
        XCTAssertTrue(result.didMatch)
        XCTAssertEqual(result.suggestedMode, .explain)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.region, .late)
    }

    /// "can you explain this to me first" → fires (covers both the
    /// "can you" prefix and the trailing "first" ordering cue).
    func testCanYouExplainThisFires() {
        let t = transcript([
            (0, 6, "can you explain this to me first"),
        ])
        let result = detect(t, .instruct)
        XCTAssertTrue(result.didMatch)
        XCTAssertEqual(result.suggestedMode, .explain)
    }

    /// Guard: the polite-request cues do NOT over-fire. "can you make the
    /// save button bigger" in Instruct mode has the cue but NO explain
    /// target nearby, so it must stay silent — the cue requirement only
    /// matters paired with an opposite-mode target.
    func testPoliteRequestWithoutOppositeTargetDoesNotFire() {
        let t = transcript([
            (0, 6, "can you make the save button bigger and move it up"),
        ])
        let result = detect(t, .instruct)
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - Does not fire

    /// "the instructions on this page are confusing" mid-narration in
    /// Instruct mode → does NOT fire. In Instruct we scan only for
    /// EXPLAIN targets, so the Instruct-flavored noun is never a
    /// candidate, and there's no cue anyway. Bare noun, no cue, middle.
    func testBareInstructNounMidNarrationInInstructDoesNotFire() {
        let t = transcript([
            (0, 12, "Here is the dashboard with all the panels"),
            (12, 24, "the instructions on this page are confusing to me"),
            (24, 40, "and over here is the sidebar navigation"),
        ])
        let result = detect(t, .instruct)
        XCTAssertEqual(result, .noMatch)
    }

    /// Explain-mode toggle does NOT scan for explain-requests. The same
    /// "explain this instead" narration that fires in Instruct mode must
    /// be inert in Explain mode (we only ever scan the OPPOSITE — here,
    /// Instruct targets, none of which are present).
    func testExplainModeDoesNotScanForExplainRequests() {
        let t = transcript([
            (0, 8, "Here is the component I built"),
            (8, 13, "actually, just explain this instead"),
        ])
        let result = detect(t, .explain)
        XCTAssertFalse(result.didMatch)
        XCTAssertEqual(result, .noMatch)
    }

    /// A bare target with no nearby cue stays silent (strict cue + target
    /// requirement, fail-closed). "shows an explanation of the flow" has
    /// the target but no switch cue.
    func testBareTargetWithoutCueDoesNotFire() {
        let t = transcript([
            (0, 6, "This panel shows an explanation of the data flow"),
        ])
        let result = detect(t, .instruct)
        XCTAssertEqual(result, .noMatch)
    }

    /// Proximity: cue and target too far apart → no match. "switch to" at
    /// the head, "explain" ten words later, well beyond the window.
    func testCueAndTargetTooFarApartDoesNotFire() {
        let t = transcript([
            (0, 12, "switch to a new file and rename the function and clean things up explain"),
        ])
        let result = detect(t, .instruct)
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - Low confidence (detected, not surfaced)

    /// A valid opposite-mode request stranded in the MIDDLE of a long
    /// recording → didMatch true but `.low` (.middle), so AppState logs it
    /// and never shows the pill.
    func testMidRecordingMatchIsLowConfidence() {
        let t = transcript([
            (0, 15, "Intro narration that runs for a good while here"),
            (28, 33, "actually, just explain this instead"),
            (40, 60, "and then a long tail of more narration after that"),
        ])
        let result = detect(t, .instruct)
        XCTAssertTrue(result.didMatch)
        XCTAssertEqual(result.suggestedMode, .explain)
        XCTAssertEqual(result.region, .middle)
        XCTAssertEqual(result.confidence, .low)
    }

    // MARK: - Normalization

    /// Filler tokens (single + multi-word) are stripped so they don't pad
    /// the cue↔target distance: "um, you know, like, explain this instead"
    /// reads as tightly as "explain this instead".
    func testFillerStrippedSoCueAndTargetStayClose() {
        let t = transcript([
            (0, 6, "um, you know, like, explain this instead"),
        ])
        let result = detect(t, .instruct)
        XCTAssertTrue(result.didMatch)
        XCTAssertEqual(result.suggestedMode, .explain)
        XCTAssertEqual(result.confidence, .high)
    }

    /// App-name variants normalize so "for Cursor AI" matches the
    /// "for cursor" target (also exercises case-insensitivity). Explain
    /// mode → scans Instruct targets.
    func testAppNameVariantNormalizedForInstructTarget() {
        let t = transcript([
            (0, 7, "No wait, make it for Cursor AI instead"),
        ])
        let result = detect(t, .explain)
        XCTAssertTrue(result.didMatch)
        XCTAssertEqual(result.suggestedMode, .instruct)
        XCTAssertEqual(result.matchedTarget, "for cursor")
    }

    // MARK: - Empty / fail-closed

    /// Empty pattern set → fail-closed regardless of input.
    func testEmptyPatternsFailClosed() {
        let t = transcript([(0, 5, "actually just explain this instead")])
        let result = ModeSwitchDetector.detect(
            transcript: t, selectedMode: .instruct, patterns: .empty
        )
        XCTAssertEqual(result, .noMatch)
    }

    /// Silent (no speech) transcript → no match.
    func testEmptyTranscriptDoesNotFire() {
        let result = detect(transcript([]), .instruct)
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - Bundled resource wiring

    /// The shipped JSON resource is bundled and decodes with non-empty
    /// lists. Hosted by the app, so `.bundled` (Bundle.main) resolves the
    /// app's copy. Guards against the resource silently dropping out of
    /// the build (which would fail-close the whole feature in production).
    func testBundledPatternsLoadNonEmpty() {
        let bundled = ModeSwitchPatterns.bundled
        XCTAssertFalse(bundled.switchCues.isEmpty, "switch cues missing from bundled JSON")
        XCTAssertFalse(bundled.instructTargets.isEmpty, "instruct targets missing from bundled JSON")
        XCTAssertFalse(bundled.explainTargets.isEmpty, "explain targets missing from bundled JSON")
    }
}
