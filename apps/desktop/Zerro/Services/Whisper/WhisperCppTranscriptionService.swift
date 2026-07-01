//
//  WhisperCppTranscriptionService.swift
//  Zerro
//
//  On-device `TranscriptionService` backed by whisper.cpp (the official
//  prebuilt `whisper.xcframework`, vendored via the local `WhisperFramework`
//  SwiftPM package and imported as `whisper`). It produces a `Transcript` that
//  is shape-equivalent to `OpenAITranscriptionService` — same per-segment
//  trimming, same joined `fullText`, same optional word-level timing — so a
//  later phase can route to it without any change to AppState's orchestration.
//
//  Phase 1 scope: this type is implemented and unit-tested but is NOT wired
//  into the pipeline. Nothing constructs it outside of tests, so the app's
//  behavior is unchanged.
//
//  Pipeline (all heavy work runs OFF the main actor — see `transcribe`):
//    1. Decode the input container (audio.m4a / AAC) to the 16 kHz mono Float32
//       PCM whisper requires, via AVFoundation (AVAudioFile + AVAudioConverter).
//    2. Run `whisper_full` on those samples.
//    3. Map result segments → `TranscriptSegment` (leading/trailing whitespace
//       trimmed per segment, matching `OpenAITranscriptionService`), join the
//       provider's segment text into `fullText`, and carry the measured audio
//       duration into `durationSeconds`.
//    4. When `wordTimestamps == true`, additionally enable token-level
//       timestamps + DTW (with the alignment-heads preset that MATCHES the
//       loaded model) and aggregate tokens into `WordTiming` values. When
//       false, no word timing is requested (keeps it cheap), matching the
//       existing OpenAI behavior.
//
//  No network, no API key. Failure mapping:
//    * audio decode / convert failure       → .decodeFailure
//    * engine init / inference failure       → .decodeFailure
//    * missing model file (checked at init)  → .modelUnavailable
//

// `@preconcurrency` on AVFoundation: AVAudioFile/AVAudioConverter/AVAudioPCMBuffer
// (AVFAudio) predate Sendable annotations, and AVAudioConverter's input block is
// typed `@Sendable` while taking a non-Sendable buffer. The decode below uses
// them entirely within one synchronous nonisolated function (nothing actually
// crosses an isolation boundary), so the Sendable warnings are noise — suppress
// them at the import rather than scattering per-call suppressions.
@preconcurrency import AVFoundation
import Foundation
import os
import whisper

struct WhisperCppTranscriptionService: TranscriptionService {

    // MARK: - Production model

    /// The intended PRODUCTION model. It is referenced by URL + checksum and
    /// downloaded/cached in a later phase — it is deliberately NOT committed to
    /// the repo and NOT bundled in the app (it is ~547 MB). Recording the
    /// checksum + byte size here lets the later download step verify integrity
    /// before the file is trusted as a model.
    ///
    /// `large-v3-turbo-q5_0` is the chosen default: the turbo decoder is ~8×
    /// faster than `large-v3` at near-large quality, and the q5_0 quantization
    /// keeps it small enough to ship as a one-time download while still
    /// supporting word-level DTW alignment.
    nonisolated enum ProductionModel {
        /// The single source of truth for the production model's identity +
        /// integrity. `LocalModelManager` downloads and verifies against this exact
        /// spec; the convenience accessors below forward to it, so the URL +
        /// checksum literals live in exactly one place.
        static let spec = ModelSpec(
            id: "ggml-large-v3-turbo-q5_0",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            // Canonical source (the same host whisper.cpp's own download script uses).
            sourceURL: URL(string:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            // SHA-256 of the model file, lowercase hex.
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            // Exact byte size of the model file.
            byteSize: 574_041_195
        )

        // Convenience forwarders — the literals live only in `spec`.
        static var id: String { spec.id }
        static var fileName: String { spec.fileName }
        static var downloadURL: URL { spec.sourceURL }
        static var sha256: String { spec.sha256 }
        static var byteSize: Int { spec.byteSize }

        /// The model this service is constructed for by default (selects the DTW
        /// alignment-heads preset, which must match the loaded weights).
        static let kind: WhisperModel = .largeV3Turbo
    }

    // MARK: - Stored

    private let modelURL: URL
    private let model: WhisperModel

    /// - Parameters:
    ///   - modelURL: Path to a ggml whisper model file. Tests inject a small
    ///     fixture model; a later phase supplies the real cached production path.
    ///     Throws `.modelUnavailable` if the file does not exist.
    ///   - model: Which model `modelURL` is. Defaults to the production model so
    ///     the documented `init(modelURL:)` call works unchanged. This selects
    ///     the DTW alignment-heads preset, which MUST match the loaded model for
    ///     word-level timing to be meaningful (a whisper.cpp requirement). Tests
    ///     pass `.tinyEn` to match the tiny.en fixture model.
    init(modelURL: URL, model: WhisperModel = ProductionModel.kind) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw TranscriptionError.modelUnavailable
        }
        self.modelURL = modelURL
        self.model = model
    }

    // MARK: - TranscriptionService

    func transcribe(audioFileURL: URL, wordTimestamps: Bool) async throws -> Transcript {
        // Capture only Sendable values; `whisper_full` and the AVFoundation
        // decode are CPU/GPU-heavy and synchronous, so they run on a detached
        // task (off the main actor). A bare `nonisolated async` would stay on
        // the caller's actor under this project's approachable-concurrency
        // settings, so `Task.detached` is used deliberately.
        let modelPath = modelURL.path
        let model = self.model
        let parts = try await Task.detached(priority: .userInitiated) {
            let decoded = try Self.decodeToPCM16kMono(audioFileURL)
            return try Self.runEngine(
                modelPath: modelPath,
                model: model,
                samples: decoded.samples,
                durationSeconds: decoded.duration,
                wordTimestamps: wordTimestamps
            )
        }.value
        // Assemble the public `Transcript` here on the caller's actor: its
        // hand-written initializer is main-actor isolated, so building it inside
        // the off-actor engine would be an isolation violation.
        return Transcript(
            segments: parts.segments,
            fullText: parts.fullText,
            words: parts.words,
            durationSeconds: parts.duration
        )
    }

    // MARK: - Audio decode (16 kHz mono Float32)

    /// whisper.cpp requires 16 kHz, mono, 32-bit float PCM samples. Decode the
    /// input container to that, measuring the source duration for
    /// `Transcript.durationSeconds`. Any failure is surfaced as `.decodeFailure`.
    nonisolated static func decodeToPCM16kMono(_ url: URL) throws -> (samples: [Float], duration: TimeInterval) {
        do {
            let file = try AVAudioFile(forReading: url)
            let inputFormat = file.processingFormat
            let totalFrames = file.length
            let duration = inputFormat.sampleRate > 0 ? Double(totalFrames) / inputFormat.sampleRate : 0

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.whisperSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw WhisperEngineError.audioFormatUnavailable
            }

            guard totalFrames > 0,
                  let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: AVAudioFrameCount(totalFrames)
                  ) else {
                // Empty / unreadable audio → no speech. Mirror the no-speech
                // contract: empty samples produce an empty Transcript downstream.
                return ([], duration)
            }
            try file.read(into: inputBuffer)

            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw WhisperEngineError.converterUnavailable
            }

            // Size the output for the full resampled length plus generous slack
            // so the whole file converts in a single pass.
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(totalFrames) * ratio).rounded(.up)) + 16_384
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw WhisperEngineError.audioFormatUnavailable
            }

            var providedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inStatus in
                if providedInput {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                providedInput = true
                inStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw conversionError ?? WhisperEngineError.conversionFailed
            }

            let count = Int(outputBuffer.frameLength)
            guard count > 0, let channel = outputBuffer.floatChannelData else {
                return ([], duration)
            }
            return (Array(UnsafeBufferPointer(start: channel[0], count: count)), duration)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.decodeFailure(underlying: error)
        }
    }

    // MARK: - Engine

    /// Runs `whisper_full` and maps its output into the parts of a `Transcript`
    /// (segments, joined full text, word timings, measured duration). Returns the
    /// parts rather than a built `Transcript` so the main-actor-isolated
    /// `Transcript.init` is called by `transcribe` on the caller's actor, not
    /// here off-actor. Pure C interop + value mapping, safe to run off the main
    /// actor.
    nonisolated static func runEngine(
        modelPath: String,
        model: WhisperModel,
        samples: [Float],
        durationSeconds: TimeInterval,
        wordTimestamps: Bool
    ) throws -> (segments: [TranscriptSegment], fullText: String, words: [WordTiming], duration: TimeInterval) {
        // whisper + ggml are extremely chatty on stderr; route their logs into a
        // sink so they don't flood test/CI output. Idempotent.
        whisper_log_set({ _, _, _ in }, nil)

        // No detectable speech → empty transcript (matches the protocol's
        // no-speech contract; `OpenAITranscriptionService` returns the same).
        guard !samples.isEmpty else {
            return (segments: [], fullText: "", words: [], duration: durationSeconds)
        }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true        // Metal (auto-falls back to CPU if unavailable)
        if wordTimestamps {
            // DTW token timestamps give materially better word alignment. The
            // alignment-heads preset MUST match the loaded model or the DTW
            // output is meaningless — `model` selects the right one.
            contextParams.dtw_token_timestamps = true
            contextParams.dtw_aheads_preset = model.alignmentHeadsPreset
        }

        guard let ctx = whisper_init_from_file_with_params(modelPath, contextParams) else {
            throw TranscriptionError.decodeFailure(underlying: WhisperEngineError.engineInitFailed)
        }
        defer { whisper_free(ctx) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = false
        params.single_segment = false
        params.suppress_blank = true
        // Word-level timing is only meaningful with token timestamps on; keep it
        // off otherwise so a normal (non-Dev) transcription stays cheap.
        params.token_timestamps = wordTimestamps
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard result == 0 else {
            throw TranscriptionError.decodeFailure(underlying: WhisperEngineError.inferenceFailed(code: Int(result)))
        }

        let segmentCount = whisper_full_n_segments(ctx)
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(Int(segmentCount))
        var rawTextParts: [String] = []
        rawTextParts.reserveCapacity(Int(segmentCount))
        var words: [WordTiming] = []

        for i in 0..<segmentCount {
            let raw = whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? ""
            rawTextParts.append(raw)
            segments.append(TranscriptSegment(
                start: centisecondsToSeconds(whisper_full_get_segment_t0(ctx, i)),
                end: centisecondsToSeconds(whisper_full_get_segment_t1(ctx, i)),
                // Whisper segment text comes back with a leading space; trim it
                // per segment so it doesn't leak into the interleaved timeline
                // (matches OpenAITranscriptionService.parseTranscript).
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            if wordTimestamps {
                words.append(contentsOf: aggregateWords(from: rawTokens(ctx: ctx, segment: i)))
            }
        }

        // The provider's full text is the joined segment text (whisper has no
        // separate top-level text field); the per-segment leading spaces make the
        // join read naturally, then the whole thing is trimmed (P1-1).
        return (
            segments: segments,
            fullText: Self.assembleFullText(fromSegmentTexts: rawTextParts),
            words: words,
            duration: durationSeconds
        )
    }

    /// Joins whisper's per-segment texts into the transcript `fullText`, trimming
    /// the leading/trailing whitespace off the result. Whisper emits each segment
    /// with a leading space, so a bare `joined()` carries a leading space from the
    /// first segment; trimming gives parity with `OpenAITranscriptionService`,
    /// whose `fullText` has none (P1-1). Pure, so the trim is unit-testable
    /// without the engine.
    nonisolated static func assembleFullText(fromSegmentTexts parts: [String]) -> String {
        parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token → word mapping

    /// One whisper token lifted out of the C context into a plain Swift value,
    /// so the token→word aggregation below can be unit-tested without invoking
    /// the engine (mirrors how `OpenAITranscriptionService.parseTranscript` is
    /// fixture-testable).
    struct RawToken: Sendable, Equatable {
        /// Raw token text exactly as whisper emits it. A word-initial token
        /// carries a single leading space (" the"); continuation / sub-word
        /// tokens do not ("'re", " ing" without the space).
        let text: String
        /// Seconds from audio start. With DTW enabled this is the DTW-aligned
        /// time; otherwise whisper's heuristic token time.
        let start: TimeInterval
        let end: TimeInterval
        /// Special / timestamp tokens (id ≥ EOT). Skipped when forming words.
        let isSpecial: Bool
    }

    /// Lifts a segment's tokens out of the C context into `[RawToken]`.
    nonisolated static func rawTokens(ctx: OpaquePointer, segment: Int32) -> [RawToken] {
        let endOfTranscript = whisper_token_eot(ctx)
        let count = whisper_full_n_tokens(ctx, segment)
        var tokens: [RawToken] = []
        tokens.reserveCapacity(Int(count))
        for t in 0..<count {
            let id = whisper_full_get_token_id(ctx, segment, t)
            let data = whisper_full_get_token_data(ctx, segment, t)
            let text = whisper_full_get_token_text(ctx, segment, t).map { String(cString: $0) } ?? ""
            // Prefer the DTW-aligned timestamp when present (> 0); otherwise fall
            // back to whisper's heuristic token span.
            let hasDTW = data.t_dtw > 0
            let start = centisecondsToSeconds(hasDTW ? data.t_dtw : data.t0)
            let end = centisecondsToSeconds(hasDTW ? data.t_dtw : data.t1)
            tokens.append(RawToken(
                text: text,
                start: start,
                end: Swift.max(end, start),
                isSpecial: id >= endOfTranscript
            ))
        }
        return tokens
    }

    /// Aggregates sub-word tokens into whole words. A token whose text starts
    /// with whitespace begins a new word; special / timestamp tokens are
    /// dropped. Each word's `start` is its first token's start and `end` its
    /// last token's end, so word timings stay monotonic when token timings are.
    nonisolated static func aggregateWords(from tokens: [RawToken]) -> [WordTiming] {
        var words: [WordTiming] = []
        var pending: [RawToken] = []

        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            let text = pending.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            words.append(WordTiming(word: text, start: first.start, end: Swift.max(last.end, first.start)))
        }

        for token in tokens {
            if token.isSpecial { continue }
            // A leading space / newline marks a word boundary: close the word
            // accumulated so far before starting this one.
            if let lead = token.text.first, lead == " " || lead == "\n" {
                flush()
            }
            pending.append(token)
        }
        flush()
        return words
    }

    // MARK: - Constants & helpers

    /// whisper.cpp's fixed input sample rate (`WHISPER_SAMPLE_RATE`).
    nonisolated static let whisperSampleRate: Double = 16_000

    /// whisper segment/token timestamps are in centiseconds (10 ms units).
    nonisolated static func centisecondsToSeconds(_ value: Int64) -> TimeInterval {
        TimeInterval(value) / 100.0
    }
}

// MARK: - WhisperModel

/// The whisper models this service knows how to align. Selecting the case is
/// how the caller tells the engine which DTW alignment-heads preset to use for
/// word-level timing — the preset MUST match the loaded model (a whisper.cpp
/// requirement) or DTW timestamps are garbage. Kept as a Swift enum so the C
/// preset enum never leaks into the service's API or the tests.
nonisolated enum WhisperModel: Sendable {
    /// Production default — `ggml-large-v3-turbo-q5_0`.
    case largeV3Turbo
    /// English-only tiny model used by tests (`ggml-tiny.en*`).
    case tinyEn
    /// Multilingual base model.
    case base

    var alignmentHeadsPreset: whisper_alignment_heads_preset {
        switch self {
        case .largeV3Turbo: return WHISPER_AHEADS_LARGE_V3_TURBO
        case .tinyEn: return WHISPER_AHEADS_TINY_EN
        case .base: return WHISPER_AHEADS_BASE
        }
    }
}

// MARK: - WhisperEngineError

/// Internal engine failures. These are never user-visible: they ride inside
/// `TranscriptionError.decodeFailure(underlying:)` for logging only, matching
/// how `OpenAITranscriptionService` keeps raw provider detail out of the typed
/// error surface.
private enum WhisperEngineError: Error {
    case engineInitFailed
    case inferenceFailed(code: Int)
    case audioFormatUnavailable
    case converterUnavailable
    case conversionFailed
}
