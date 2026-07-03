//
//  TranscriptionService.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Provider-neutral protocol for speech-to-text. The Phase 9 v1
//  concrete impl is `OpenAITranscriptionService` (Whisper); future
//  providers (Anthropic / Gemini / local) implement this same shape so
//  AppState's orchestration doesn't change when we swap.
//
//  Segment-level timestamps are NOT optional in the return type — the
//  Phase 9 interleaver (Step 2) merges these with frame timestamps into
//  a single chronological timeline, and that merge depends on having
//  per-segment start/end times. A provider that can't deliver them
//  doesn't satisfy this protocol.
//

import Foundation

protocol TranscriptionService: Sendable {
    /// Transcribes the audio at `audioFileURL`. The returned Transcript
    /// carries segment-level timestamps in seconds-from-audio-start
    /// plus the provider's full text (with the provider's
    /// punctuation / capitalization — typically better than what naive
    /// segment concatenation would produce).
    ///
    /// `wordTimestamps` (Phase 2, Dev Mode deixis §7): when true, also request
    /// WORD-level timing (`Transcript.words`) for the deixis resolver's
    /// `[phrase−800ms, phrase+200ms]` windowing. Defaults false so a NORMAL
    /// recording's request is byte-identical to before — word timing is captured
    /// only for a Dev Mode recording, which needs it.
    ///
    /// Throws `TranscriptionError` for the known failure modes. Step 5
    /// of Phase 9 maps these onto the amber failure pill.
    func transcribe(audioFileURL: URL, wordTimestamps: Bool) async throws -> Transcript
}

extension TranscriptionService {
    /// Back-compat overload — the normal (non-Dev) path never asks for word
    /// timing, so every existing call site stays unchanged.
    func transcribe(audioFileURL: URL) async throws -> Transcript {
        try await transcribe(audioFileURL: audioFileURL, wordTimestamps: false)
    }
}

// MARK: - Transcript

struct Transcript: Sendable {
    /// Ordered by `start` (ascending). Empty when the audio carried no
    /// detectable speech (user was silent / mic was muted) — in that
    /// case `fullText` is also empty/whitespace.
    let segments: [TranscriptSegment]

    /// The provider's full text. Prefer this over `segments.map(\.text).joined()`
    /// for display — Whisper applies sentence-level punctuation +
    /// capitalization across segment boundaries.
    let fullText: String

    /// Phase 2 (Dev Mode deixis §7) — WORD-level timings, present only when the
    /// transcription was requested with `wordTimestamps: true` (a Dev Mode
    /// recording). Empty otherwise. The resolver scans these to window the cursor
    /// around each referring expression. Approximate (~0.1–0.2s, worse near
    /// pauses, §11) — the early-biased window absorbs the slop.
    let words: [WordTiming]

    /// Phase 2 (Dev Mode, managed 2-call flow) — the STT provider's MEASURED audio
    /// duration in seconds, when known. Populated only on the managed Dev Mode
    /// call 1 (`dev_transcribe`) so call 2's cost meter bills against the SAME
    /// server-measured duration the normal managed path uses (rather than the
    /// client's local container duration). `nil` on the BYOK local path (which
    /// generates locally and never bills on this duration) and on a no-speech run.
    let durationSeconds: Double?

    init(segments: [TranscriptSegment], fullText: String, words: [WordTiming] = [], durationSeconds: Double? = nil) {
        self.segments = segments
        self.fullText = fullText
        self.words = words
        self.durationSeconds = durationSeconds
    }
}

// MARK: - WordTiming

/// Phase 2 (Dev Mode deixis §7) — one word with its start/end in
/// seconds-from-audio-start (the same clock the cursor track + frames rebase to).
struct WordTiming: Sendable, Equatable, Codable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
}

// MARK: - TranscriptSegment

struct TranscriptSegment: Sendable {
    /// Seconds from the start of the audio file.
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

// MARK: - TranscriptionError

/// Known failure shapes. Phase 9 Step 5 maps these to
/// RecordingFailureReason cases (apiKeyMissing, apiAuth, networkOffline,
/// rateLimited, providerError). The associated values are for logging,
/// never user-visible.
enum TranscriptionError: Error {
    case missingAPIKey
    case auth
    case rateLimited
    case network(underlying: Error)
    /// Non-2xx provider response. Carries the status code ONLY — useful and
    /// non-sensitive. The raw response body is deliberately NOT an associated
    /// value: this error can reach `CrashReporting.capture`, where the PostHog error tracker
    /// SDK derives the exception value from the error's description, and a raw
    /// provider body would ride into that value scrubbed only by a length clamp
    /// (not a content filter). The body is logged `.private` at the throw site
    /// for local debugging instead. See `OpenAITranscriptionService`.
    case server(status: Int)
    case decodeFailure(underlying: Error)
    /// A required local model file is missing / not yet downloaded. Thrown only
    /// by the on-device engine (`WhisperCppTranscriptionService`) when its
    /// injected model path doesn't exist. Deliberately NOT mapped to a
    /// user-facing `RecordingFailureReason` yet — the local path isn't wired
    /// into the pipeline in this phase, so there's no surface that can raise it.
    case modelUnavailable
}
