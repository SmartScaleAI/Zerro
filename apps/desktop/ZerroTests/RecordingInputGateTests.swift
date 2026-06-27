//
//  RecordingInputGateTests.swift
//  ZerroTests
//
//  Layer 0 — the safety net for the local "no input" gate.
//
//  `RecordingInputGate.shouldSkipGeneration(hasSpeech:clickCount:)` is the pure
//  core of the gate: it answers whether a recording has NO on-device signal a
//  request could come from (silent audio AND no clicks) and so should be skipped
//  before any provider dispatch. Because it's a pure function over primitives it
//  needs no AppState, no ProcessedRecording, and no recording — its whole truth
//  table is exercisable directly. These tests ARE the contract: skip IFF
//  (no speech AND no clicks). ANY speech or ANY click keeps generation, so a real
//  request — a Dev Mode click-only request, or narrated normal mode — is never
//  dropped. The cases below are the four corners of that table.
//

import XCTest
@testable import Zerro

final class RecordingInputGateTests: XCTestCase {

    /// The case the gate exists to catch: silent audio AND no clicks — nothing a
    /// request could come from, a guaranteed `ZERRO_NO_REQUEST`. Skip it so the
    /// recording costs the user nothing.
    func testNoSpeechNoClicksSkips() {
        XCTAssertTrue(
            RecordingInputGate.shouldSkipGeneration(hasSpeech: false, clickCount: 0)
        )
    }

    /// No speech but at least one click — a Dev Mode click-only request still
    /// carries a non-speech signal of intent, so it must NOT be skipped (the
    /// safety margin against dropping a real request).
    func testNoSpeechWithClicksDoesNotSkip() {
        XCTAssertFalse(
            RecordingInputGate.shouldSkipGeneration(hasSpeech: false, clickCount: 1)
        )
        XCTAssertFalse(
            RecordingInputGate.shouldSkipGeneration(hasSpeech: false, clickCount: 42)
        )
    }

    /// Speech present, no clicks — narration carries the request, so never skip.
    func testSpeechWithoutClicksDoesNotSkip() {
        XCTAssertFalse(
            RecordingInputGate.shouldSkipGeneration(hasSpeech: true, clickCount: 0)
        )
    }

    /// Speech AND clicks — plainly a real request; never skip.
    func testSpeechWithClicksDoesNotSkip() {
        XCTAssertFalse(
            RecordingInputGate.shouldSkipGeneration(hasSpeech: true, clickCount: 3)
        )
    }
}
