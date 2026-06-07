//
//  AudioActivity.swift
//  Zerro
//
//  Created by Colin Breeding on 6/6/26.
//
//  Phase 6 — the no-speech gate. A cheap, post-hoc check on the isolated
//  `audio.m4a` that answers one question: does this clip contain any
//  detectable speech? When it doesn't (a silent screen-only recording, a
//  muted mic), the downstream STT call is skipped entirely — saving a
//  Whisper round-trip + its cost — and generation proceeds on frames + OCR
//  + clicks alone (Phase 5 + the existing empty-transcript handling cover
//  the output).
//
//  Computed POST-HOC from the decoded audio file (not from capture-time
//  state) so it also works on re-extraction in the eval harness, where the
//  manifest is rebuilt from the recorded `.mov` without any live signal.
//
//  Design: the energy math is a PURE function over a sample buffer
//  (`hasSpeech(samples:windowSize:threshold:)`) so it's unit-testable
//  without a real audio file; the file-decoding wrapper
//  (`hasSpeech(in:)`) just turns the m4a into mono float samples and hands
//  them to that core. The check is intentionally CONSERVATIVE: any single
//  window whose RMS exceeds the threshold marks the clip as having speech,
//  and any decode failure returns `true` — both bias toward transcribing,
//  so we can never silently drop real narration to save a few cents.
//
//  Not a model decision (no prompt/cost-cap tuning lives here) but the
//  threshold/window constants are in `ProcessingConfig` with the rest of
//  the tunables.
//

import AVFoundation
import Foundation
import os

enum AudioActivity {

    /// Decodes the audio at `audioURL` to mono float samples and reports
    /// whether any window carries speech-level energy. Best-effort: a missing,
    /// empty, or undecodable file returns `true` (bias toward transcribing —
    /// never drop real narration because the gate couldn't read the file).
    static func hasSpeech(
        in audioURL: URL,
        windowSize: Int = ProcessingConfig.speechWindowSamples,
        threshold: Float = ProcessingConfig.speechRMSThreshold
    ) -> Bool {
        guard let samples = monoSamples(of: audioURL) else {
            Log.processing.error("audio activity: decode failed — assuming speech present")
            return true
        }
        return hasSpeech(samples: samples, windowSize: windowSize, threshold: threshold)
    }

    /// Pure core: scan `samples` in non-overlapping windows of `windowSize`,
    /// compute each window's RMS, and return `true` as soon as one EXCEEDS
    /// `threshold`. An empty buffer is silence (`false`). Sample-rate-agnostic
    /// (operates on counts, not seconds) so it can be exercised with synthetic
    /// buffers in tests. A trailing partial window is measured too, so a short
    /// burst at the very end isn't lost.
    static func hasSpeech(
        samples: [Float],
        windowSize: Int = ProcessingConfig.speechWindowSamples,
        threshold: Float = ProcessingConfig.speechRMSThreshold
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        let window = max(1, windowSize)

        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            var sumSquares: Double = 0
            for i in start..<end {
                let s = Double(samples[i])
                sumSquares += s * s
            }
            let count = end - start
            let rms = (sumSquares / Double(count)).squareRoot()
            if rms > Double(threshold) { return true }
            start += window
        }
        return false
    }

    // MARK: - Decode

    /// Reads `audioURL` fully and returns its samples as a single mono float
    /// buffer (channel 0 — the narration track). Returns `nil` on any decode
    /// failure or an empty file, which the caller treats as "assume speech."
    private static func monoSamples(of audioURL: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        // Channel 0 only: the isolated narration is effectively mono, and
        // energy detection doesn't need the second channel. Copy out of the
        // (transient) buffer pointer into an owned array.
        let channel0 = channelData[0]
        return Array(UnsafeBufferPointer(start: channel0, count: frames))
    }
}
