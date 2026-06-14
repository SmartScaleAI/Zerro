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
    /// Throws `TranscriptionError` for the known failure modes. Step 5
    /// of Phase 9 maps these onto the amber failure pill.
    func transcribe(audioFileURL: URL) async throws -> Transcript
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
}
