//
//  OpenAITranscriptionService.swift
//  VisualFlowAI
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
//  Response (verbose_json):
//    { duration, language, text, segments: [{id, start, end, text, ...}] }
//

import Foundation

struct OpenAITranscriptionService: TranscriptionService {

    /// Whisper model id. Pinned here so a future swap to a
    /// gpt-4o-transcribe variant is a single-line change with a
    /// before/after cost log diff to back the decision.
    static let model = "whisper-1"

    func transcribe(audioFileURL: URL) async throws -> Transcript {
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
        let body = builder.build(parts: [
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
        ])

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

        switch response.statusCode {
        case 200...299:
            break
        case 401:
            throw TranscriptionError.auth
        case 429:
            // performWithRetry already retried once; reaching here means
            // the retry also got 429.
            throw TranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8)
            throw TranscriptionError.server(status: response.statusCode, body: body)
        }

        let decoded: WhisperResponse
        do {
            decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        } catch {
            throw TranscriptionError.decodeFailure(underlying: error)
        }

        // Whisper segment text comes back with a leading space ("
        // Okay, so..."). Trim leading/trailing whitespace so it
        // doesn't leak into the interleaved timeline view as
        // `[0:00-0:11] " Okay..."`. fullText is preserved as Whisper
        // returned it — that string is what the model would see as a
        // standalone narration if we ever ran a frames-only pass.
        return Transcript(
            segments: (decoded.segments ?? []).map {
                TranscriptSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            fullText: decoded.text
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
    }

    private struct WhisperSegment: Decodable {
        let start: Double
        let end: Double
        let text: String
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
