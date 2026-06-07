//
//  AudioActivityTests.swift
//  ZerroTests
//
//  Phase 6 — the safety net for the no-speech gate.
//
//  `AudioActivity.hasSpeech(samples:windowSize:threshold:)` is the pure core of
//  the gate: it scans a normalized (−1…1) float buffer in non-overlapping
//  windows, computes each window's RMS, and reports whether ANY window exceeds
//  the speech-energy threshold. Because it imports no AVFoundation and reads no
//  file, its whole decision surface is exercisable with synthetic buffers — no
//  recording, no decode. These tests are the contract; the threshold/window
//  constants in ProcessingConfig are free to be tuned as long as these hold.
//
//  The gate is deliberately CONSERVATIVE (any one loud window ⇒ speech), so the
//  "one loud window" case below is the important one: a clip that is silent
//  except for a brief utterance must still transcribe.
//

import XCTest
@testable import Zerro

final class AudioActivityTests: XCTestCase {

    private let window = 1024
    private let threshold: Float = 0.01

    /// A buffer of pure silence (all zeros) has zero energy in every window →
    /// no speech. This is the case the gate exists to catch (muted mic / silent
    /// screen-only clip) so Whisper can be skipped.
    func testSilentBufferHasNoSpeech() {
        let silent = [Float](repeating: 0, count: window * 4)
        XCTAssertFalse(
            AudioActivity.hasSpeech(samples: silent, windowSize: window, threshold: threshold)
        )
    }

    /// A near-silent buffer whose energy stays BELOW the threshold (room-tone
    /// floor) is still treated as no speech — the threshold is what separates a
    /// quiet room from narration.
    func testSubThresholdBufferHasNoSpeech() {
        // RMS of a constant signal == its absolute amplitude. 0.002 ≪ 0.01.
        let quiet = [Float](repeating: 0.002, count: window * 4)
        XCTAssertFalse(
            AudioActivity.hasSpeech(samples: quiet, windowSize: window, threshold: threshold)
        )
    }

    /// A buffer at conversational level (well above the threshold across every
    /// window) is speech. RMS of a constant 0.2 signal is 0.2 > 0.01.
    func testSpeechLevelBufferHasSpeech() {
        let loud = [Float](repeating: 0.2, count: window * 4)
        XCTAssertTrue(
            AudioActivity.hasSpeech(samples: loud, windowSize: window, threshold: threshold)
        )
    }

    /// The conservative case: a clip that is silent EXCEPT for a single loud
    /// window (one brief utterance) must register as speech — the gate must not
    /// average a short burst away into silence.
    func testSingleLoudWindowHasSpeech() {
        var samples = [Float](repeating: 0, count: window * 4)
        // Fill exactly the second window with speech-level energy.
        for i in window..<(window * 2) { samples[i] = 0.3 }
        XCTAssertTrue(
            AudioActivity.hasSpeech(samples: samples, windowSize: window, threshold: threshold)
        )
    }

    /// A burst landing in the FINAL, partial window (buffer length not a
    /// multiple of windowSize) is still measured — it isn't dropped off the end.
    func testTrailingPartialWindowHasSpeech() {
        // 2.5 windows of silence, then a short loud tail inside the partial window.
        var samples = [Float](repeating: 0, count: window * 2 + window / 2)
        for i in (window * 2)..<samples.count { samples[i] = 0.3 }
        XCTAssertTrue(
            AudioActivity.hasSpeech(samples: samples, windowSize: window, threshold: threshold)
        )
    }

    /// An empty buffer is silence, not speech (degenerate input must not throw
    /// or default to true in the pure core).
    func testEmptyBufferHasNoSpeech() {
        XCTAssertFalse(
            AudioActivity.hasSpeech(samples: [], windowSize: window, threshold: threshold)
        )
    }
}
