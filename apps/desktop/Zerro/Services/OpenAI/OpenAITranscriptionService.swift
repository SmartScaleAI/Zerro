//
//  OpenAITranscriptionService.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  TranscriptionService impl backed by Whisper via the OpenAI Audio
//  Transcriptions endpoint. Pinned to `whisper-1` for v1 — stable
//  model, documented `verbose_json` + segment timestamps shape, low
//  per-minute cost. `gpt-4o-transcribe` / `gpt-4o-mini-transcribe`
//  are newer alternatives we can swap in later by changing one string;
//  the response schema is shared.
//
//  Request shape (verified against live OpenAI docs at 2026-05-28):
//    POST https://api.openai.com/v1/audio/transcriptions
//    Headers:  Authorization: Bearer <key>
//    Body:     multipart/form-data
//              - file=<audio.m4a>  (Content-Type: audio/m4a)
//              - model=whisper-1
//              - response_format=verbose_json
//              - timestamp_granularities[]=segment
//              - timestamp_granularities[]=word   (Dev Mode only — §7 deixis)
//  Response (verbose_json):
//    { duration, language, text, segments: [{id, start, end, text, ...}],
//      words: [{word, start, end}]   (only when word granularity requested) }
//

import Foundation
import os

struct OpenAITranscriptionService: TranscriptionService {

    /// Whisper model id. Pinned here so a future swap to a
    /// gpt-4o-transcribe variant is a single-line change with a
    /// before/after cost log diff to back the decision.
    static let model = "whisper-1"

    /// Typed mapping from the Whisper response status to the error thrown
    /// for it — nil for 2xx success. Factored out of `transcribe` so the
    /// mapping is unit-testable without a live request. 401 AND 403 both
    /// map to `.auth` (J-02): OpenAI returns 403 for rejected keys and
    /// permission/region denials, which previously fell through to
    /// `.server` and surfaced as a misleading transient-outage message.
    /// A 429 reaching here is either quota exhaustion (`insufficient_quota`
    /// body, J-03 — performWithRetry deliberately didn't retry it) or a
    /// rate limit that outlived performWithRetry's single retry; `body`
    /// tells them apart.
    static func error(forStatus status: Int, body: Data = Data()) -> TranscriptionError? {
        switch status {
        case 200...299: return nil
        case 401, 403: return .auth
        case 429:
            return OpenAIClient.isQuotaExhausted429(status: status, body: body)
                ? .quotaExhausted
                : .rateLimited
        default: return .server(status: status)
        }
    }

    func transcribe(audioFileURL: URL, wordTimestamps: Bool) async throws -> Transcript {
        guard let apiKey = OpenAIClient.resolveAPIKey() else {
            throw TranscriptionError.missingAPIKey
        }

        // Load audio bytes synchronously. Whisper's per-request size
        // cap is 25MB; our 3-minute AAC-mono-44.1k recordings come in
        // well under that (typically <3MB). If we ever lift the
        // recording cap, this is one of the places to revisit.
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw TranscriptionError.network(underlying: error)
        }

        let builder = OpenAIClient.MultipartBuilder()
        var parts: [OpenAIClient.MultipartBuilder.Part] = [
            .file(
                name: "file",
                filename: audioFileURL.lastPathComponent,
                mimeType: "audio/m4a",
                data: audioData
            ),
            .text(name: "model", value: Self.model),
            .text(name: "response_format", value: "verbose_json"),
            // The trailing [] is required — OpenAI expects this exact
            // form field name for repeated values.
            .text(name: "timestamp_granularities[]", value: "segment")
        ]
        // Phase 2 (Dev Mode deixis): also request WORD-level timing. Gated so a
        // normal recording's request is byte-identical — only a Dev Mode
        // transcription adds this field. Whisper then returns a top-level
        // `words: [{word,start,end}]` array alongside `segments`.
        if wordTimestamps {
            parts.append(.text(name: "timestamp_granularities[]", value: "word"))
        }
        let body = builder.build(parts: parts)

        var request = URLRequest(url: OpenAIClient.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue(builder.contentType, forHTTPHeaderField: "Content-Type")
        OpenAIClient.authenticate(&request, apiKey: apiKey)
        request.httpBody = body

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await OpenAIClient.performWithRetry(request)
        } catch {
            throw TranscriptionError.network(underlying: error)
        }

        if let statusError = Self.error(forStatus: response.statusCode, body: data) {
            if case .server = statusError {
                // Log the provider's error body `.private` for local debugging
                // only — it must NOT ride into the typed error, which can reach
                // the error tracker, where the exception value is scrubbed by length, not by
                // content. The error keeps just the status code.
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Log.transcription.error("Whisper non-2xx \(response.statusCode, privacy: .public): \(body, privacy: .private)")
            }
            throw statusError
        }

        do {
            return try Self.parseTranscript(from: data)
        } catch {
            throw TranscriptionError.decodeFailure(underlying: error)
        }
    }

    /// Decode a Whisper `verbose_json` body into a `Transcript`. Split out from
    /// the network path so the segment/word mapping is unit-testable against a
    /// fixture (no live request). Throws the raw decode error; the caller wraps
    /// it as `TranscriptionError.decodeFailure`.
    static func parseTranscript(from data: Data) throws -> Transcript {
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        // Whisper segment text comes back with a leading space (" Okay, so...").
        // Trim leading/trailing whitespace so it doesn't leak into the
        // interleaved timeline view as `[0:00-0:11] " Okay..."`. fullText is
        // preserved as Whisper returned it.
        return Transcript(
            segments: (decoded.segments ?? []).map {
                TranscriptSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            fullText: decoded.text,
            // Phase 2 (Dev Mode deixis): present only when `wordTimestamps` was
            // requested (Whisper omits the array otherwise → empty).
            words: (decoded.words ?? []).map {
                WordTiming(
                    word: $0.word.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: $0.start,
                    end: $0.end
                )
            }
        )
    }

    // MARK: - Wire types
    //
    // Decode only the fields we use. Whisper's verbose_json carries
    // more per-segment metadata (avg_logprob, no_speech_prob, tokens,
    // etc.) — ignoring them keeps the wire type stable across minor
    // provider schema additions.

    private struct WhisperResponse: Decodable {
        let text: String
        let segments: [WhisperSegment]?
        /// Present only when `timestamp_granularities[]=word` was requested
        /// (Dev Mode). Absent → nil → empty `Transcript.words`.
        let words: [WhisperWord]?
    }

    private struct WhisperSegment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    private struct WhisperWord: Decodable {
        let word: String
        let start: Double
        let end: Double
    }

    // MARK: - Cost estimate

    /// Whisper-1 list price as of 2026-05-28 (USD per minute of audio).
    /// Update when OpenAI changes pricing. Used by AppState's per-session
    /// cost log; not consumed elsewhere.
    private static let pricePerMinute: Double = 0.006

    /// Returns the estimated USD cost for transcribing `audioDurationSeconds`
    /// of audio with Whisper-1. OpenAI bills per second internally but
    /// the published price is per minute — divide by 60 for the rate.
    static func estimatedCost(audioDurationSeconds: Double) -> Double {
        guard audioDurationSeconds.isFinite, audioDurationSeconds > 0 else { return 0 }
        return (audioDurationSeconds / 60.0) * pricePerMinute
    }
}
