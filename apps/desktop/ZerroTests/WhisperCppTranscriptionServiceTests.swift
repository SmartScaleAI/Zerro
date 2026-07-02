//
//  WhisperCppTranscriptionServiceTests.swift
//  ZerroTests
//
//  Phase 1 (on-device whisper). Two layers, mirroring how
//  `OpenAITranscriptionService` is tested:
//
//   1. Pure token→word mapping, exercised WITHOUT the engine against synthetic
//      tokens (the analogue of DevWordTimingTests' fixture-based
//      `parseTranscript` checks).
//   2. A real end-to-end transcription: a short spoken `.m4a` fixture (committed,
//      ~15 KB) decoded + run through whisper using a small `tiny.en` model.
//
//  Model delivery (the tiny.en model is ~31 MB and NOT committed). In priority
//  order:
//    • $ZERRO_WHISPER_MODEL_PATH — optional override to an existing model file
//      (handy from an Xcode scheme / test plan, where env reaches the host).
//    • a checksum-verified copy at ~/Library/Caches/ZerroTests/whisper-models —
//      this is the path CI pre-populates so the test runs for real there.
//    • otherwise downloaded once, SHA-256-verified, then cached at that path.
//    • if it still can't be obtained (offline) the engine tests SKIP. That skip
//      is LOCAL-DEV ONLY: CI pre-places the model AND a post-test guard in
//      ci.yml fails the job if this suite didn't run, so engine coverage can't
//      go silently blind. ($ZERRO_WHISPER_TEST_REQUIRE forces fail-instead-of-
//      skip in contexts where env actually reaches the test host.)
//

import AVFoundation
import CryptoKit
import XCTest
@testable import Zerro

final class WhisperCppTranscriptionServiceTests: XCTestCase {

    // MARK: - Pure token → word mapping (no engine, no model)

    /// Sub-word tokens are grouped into whole words on leading-space boundaries,
    /// each word spanning its first token's start to its last token's end —
    /// the same shape `OpenAITranscriptionService` yields from Whisper's word
    /// array, so downstream consumers see an equivalent `[WordTiming]`.
    func testAggregateWordsGroupsSubwordTokensIntoWords() {
        // Realistic whisper tokenization of "Make the Get started button teal.":
        // word-initial tokens carry a leading space; "teal." is split across
        // sub-word tokens ("te", "al", ".") with no interior spaces.
        let tokens: [WhisperCppTranscriptionService.RawToken] = [
            .init(text: " Make",    start: 0.00, end: 0.20, isSpecial: false),
            .init(text: " the",     start: 0.20, end: 0.32, isSpecial: false),
            .init(text: " Get",     start: 0.32, end: 0.55, isSpecial: false),
            .init(text: " started", start: 0.55, end: 0.90, isSpecial: false),
            .init(text: " button",  start: 0.90, end: 1.25, isSpecial: false),
            .init(text: " te",      start: 1.25, end: 1.50, isSpecial: false),
            .init(text: "al",       start: 1.50, end: 1.70, isSpecial: false),
            .init(text: ".",        start: 1.70, end: 1.75, isSpecial: false),
        ]

        let words = WhisperCppTranscriptionService.aggregateWords(from: tokens)

        XCTAssertEqual(words.map(\.word), ["Make", "the", "Get", "started", "button", "teal."])
        XCTAssertEqual(words.first, WordTiming(word: "Make", start: 0.00, end: 0.20))
        // "teal." spans the first sub-word token's start to the last's end.
        XCTAssertEqual(words.last, WordTiming(word: "teal.", start: 1.25, end: 1.75))
        assertMonotonic(words)
    }

    /// Special / timestamp tokens (id ≥ EOT, surfaced as `isSpecial`) are dropped
    /// and never fold into an adjacent word.
    func testAggregateWordsSkipsSpecialTokens() {
        let tokens: [WhisperCppTranscriptionService.RawToken] = [
            .init(text: "[_BEG_]",  start: 0.00, end: 0.00, isSpecial: true),
            .init(text: " hello",   start: 0.10, end: 0.40, isSpecial: false),
            .init(text: " world",   start: 0.40, end: 0.80, isSpecial: false),
            .init(text: "[_TT_50]", start: 0.80, end: 0.80, isSpecial: true),
        ]

        let words = WhisperCppTranscriptionService.aggregateWords(from: tokens)

        XCTAssertEqual(words.map(\.word), ["hello", "world"])
        XCTAssertEqual(words.first, WordTiming(word: "hello", start: 0.10, end: 0.40))
        assertMonotonic(words)
    }

    /// All-special input (no speech tokens) yields no words rather than an empty
    /// phantom word.
    func testAggregateWordsWithOnlySpecialTokensYieldsNone() {
        let tokens: [WhisperCppTranscriptionService.RawToken] = [
            .init(text: "[_SOT_]", start: 0, end: 0, isSpecial: true),
            .init(text: "[_EOT_]", start: 0, end: 0, isSpecial: true),
        ]
        XCTAssertTrue(WhisperCppTranscriptionService.aggregateWords(from: tokens).isEmpty)
    }

    // MARK: - fullText assembly (P1-1)

    /// `fullText` joins whisper's per-segment texts and trims the result. Whisper
    /// prefixes each segment with a space, so a bare `joined()` leaks a leading
    /// space; trimming gives parity with `OpenAITranscriptionService`, whose
    /// `fullText` has no leading/trailing whitespace. Pure — runs without the
    /// engine or a model.
    func testAssembleFullTextTrimsLeadingAndTrailingWhitespace() {
        // Whisper emits each segment with a leading space.
        let parts = [" The quick brown fox", " jumps over the lazy dog."]
        let full = WhisperCppTranscriptionService.assembleFullText(fromSegmentTexts: parts)

        XCTAssertEqual(full, "The quick brown fox jumps over the lazy dog.")
        XCTAssertFalse(full.hasPrefix(" "), "no leading space")
        XCTAssertFalse(full.hasSuffix(" "), "no trailing space")
        XCTAssertEqual(full, full.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Empty / whitespace-only input yields an empty string (no phantom space).
    func testAssembleFullTextEmptyAndBlank() {
        XCTAssertEqual(WhisperCppTranscriptionService.assembleFullText(fromSegmentTexts: []), "")
        XCTAssertEqual(WhisperCppTranscriptionService.assembleFullText(fromSegmentTexts: [" ", "\n"]), "")
    }

    // MARK: - DTW token timing (P1-2)

    /// `t_dtw == 0` is a REAL DTW time (a word at audio start), NOT the
    /// "-1 = not computed" sentinel — it must be kept, not dropped to the
    /// heuristic `t0`/`t1`. This is the P1-2 fix (`>= 0`, was `> 0`).
    func testTokenTimesKeepsDTWTimeAtAudioStart() {
        let times = WhisperCppTranscriptionService.tokenTimes(tDTW: 0, t0: 5, t1: 12)
        XCTAssertEqual(times.start, 0.0, accuracy: 1e-9, "a t=0 DTW time is kept, not dropped to heuristic")
        XCTAssertEqual(times.end, 0.0, accuracy: 1e-9)
    }

    /// `t_dtw == -1` (DTW not computed for this token) → heuristic `t0`/`t1`.
    func testTokenTimesUsesHeuristicWhenDTWNotComputed() {
        let times = WhisperCppTranscriptionService.tokenTimes(tDTW: -1, t0: 5, t1: 12)
        XCTAssertEqual(times.start, 0.05, accuracy: 1e-9)
        XCTAssertEqual(times.end, 0.12, accuracy: 1e-9)
    }

    /// A positive DTW time collapses start/end to the single aligned moment.
    func testTokenTimesUsesPositiveDTW() {
        let times = WhisperCppTranscriptionService.tokenTimes(tDTW: 30, t0: 5, t1: 99)
        XCTAssertEqual(times.start, 0.30, accuracy: 1e-9)
        XCTAssertEqual(times.end, 0.30, accuracy: 1e-9)
    }

    /// `end` is never allowed to precede `start` (heuristic with reversed t0/t1).
    func testTokenTimesClampsEndAtLeastStart() {
        let times = WhisperCppTranscriptionService.tokenTimes(tDTW: -1, t0: 20, t1: 10)
        XCTAssertGreaterThanOrEqual(times.end, times.start)
    }

    /// A first word at audio start (start == 0) survives aggregation with its
    /// 0.0 start intact — the downstream effect of keeping the t=0 DTW time.
    func testAggregateWordsPreservesZeroStartFirstWord() {
        let tokens: [WhisperCppTranscriptionService.RawToken] = [
            .init(text: " Hello", start: 0.0, end: 0.20, isSpecial: false),
            .init(text: " world", start: 0.20, end: 0.45, isSpecial: false),
        ]
        let words = WhisperCppTranscriptionService.aggregateWords(from: tokens)
        XCTAssertEqual(words.first?.word, "Hello")
        XCTAssertEqual(words.first?.start ?? -1, 0.0, accuracy: 1e-9, "the first word keeps its t=0 start")
    }

    // MARK: - Full-drain audio decode (P1-3)

    /// A multi-second recording resamples to ~(16 kHz × duration) samples. The
    /// decoder pulls output in 16 384-frame chunks, so a 3 s clip needs several
    /// drain iterations; a single-pass convert would truncate to ~one chunk. This
    /// runs WITHOUT the engine or a model — just AVFoundation resampling.
    func testDecodeFullyDrainsMultiSecondBuffer() throws {
        let sourceRate = 44_100.0
        let seconds = 3.0
        let url = try Self.writeSyntheticSine(seconds: seconds, sampleRate: sourceRate)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try WhisperCppTranscriptionService.decodeToPCM16kMono(url)

        let expected = Int(WhisperCppTranscriptionService.whisperSampleRate * seconds)   // 48_000
        let tolerance = Int(Double(expected) * 0.02)                                     // 2% tail slack
        XCTAssertLessThanOrEqual(
            abs(decoded.samples.count - expected), tolerance,
            "resampled \(decoded.samples.count) samples; expected ~\(expected) (16kHz × \(seconds)s). "
            + "A non-draining single-pass would truncate to ~16384."
        )
        XCTAssertEqual(decoded.duration, seconds, accuracy: 0.05, "measured duration ≈ source duration")
    }

    // MARK: - init(modelURL:)

    /// A missing model file fails fast with `.modelUnavailable` (the case added
    /// for the later cached-model path), with no engine work attempted.
    func testInitThrowsModelUnavailableWhenModelMissing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        XCTAssertThrowsError(try WhisperCppTranscriptionService(modelURL: missing)) { error in
            guard case TranscriptionError.modelUnavailable = error else {
                return XCTFail("expected .modelUnavailable, got \(error)")
            }
        }
    }

    // MARK: - End-to-end engine

    /// Decodes the spoken fixture and transcribes it with the real engine: the
    /// text contains the expected phrase, and segments are ordered, non-empty,
    /// and carry a plausible duration.
    func testTranscribeProducesExpectedTranscript() async throws {
        let model = try await resolveTestModelOrSkip()
        let audio = try fixtureAudioURL()
        let service = try WhisperCppTranscriptionService(modelURL: model, model: .tinyEn)

        let transcript = try await service.transcribe(audioFileURL: audio)

        let normalized = Self.normalize(transcript.fullText)
        XCTAssertTrue(
            normalized.contains("quick brown fox"),
            "expected the spoken phrase; got fullText=\"\(transcript.fullText)\""
        )
        // P1-1: fullText carries no leading/trailing whitespace (whisper's first
        // segment leads with a space) — parity with OpenAITranscriptionService.
        XCTAssertEqual(
            transcript.fullText,
            transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            "fullText must be trimmed"
        )

        XCTAssertFalse(transcript.segments.isEmpty, "expected at least one segment")
        for segment in transcript.segments {
            XCTAssertFalse(
                segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "segments should be trimmed but non-empty"
            )
            XCTAssertLessThanOrEqual(segment.start, segment.end, "segment start ≤ end")
        }
        // Ordered by ascending start.
        for k in 1..<max(1, transcript.segments.count) {
            XCTAssertGreaterThanOrEqual(transcript.segments[k].start, transcript.segments[k - 1].start)
        }

        // Duration is the measured audio length (~2.5 s) — populated and plausible.
        let duration = try XCTUnwrap(transcript.durationSeconds)
        XCTAssertGreaterThan(duration, 1.0)
        XCTAssertLessThan(duration, 6.0)

        // Normal path requests no word timing.
        XCTAssertTrue(transcript.words.isEmpty, "word timing must be opt-in")
    }

    /// With `wordTimestamps: true`, word timings are populated and monotonic
    /// (the property the deixis resolver relies on).
    func testWordTimestampsArePopulatedAndMonotonic() async throws {
        let model = try await resolveTestModelOrSkip()
        let audio = try fixtureAudioURL()
        let service = try WhisperCppTranscriptionService(modelURL: model, model: .tinyEn)

        let transcript = try await service.transcribe(audioFileURL: audio, wordTimestamps: true)

        XCTAssertFalse(transcript.words.isEmpty, "expected word-level timing when requested")
        for word in transcript.words {
            XCTAssertFalse(word.word.isEmpty)
            XCTAssertLessThanOrEqual(word.start, word.end, "each word: start ≤ end")
        }
        assertMonotonic(transcript.words)

        // The same distinctive phrase should survive into the word stream.
        let joined = Self.normalize(transcript.words.map(\.word).joined(separator: " "))
        XCTAssertTrue(joined.contains("quick brown fox"), "got words=\(transcript.words.map(\.word))")
    }

    // MARK: - Helpers

    /// Word start times are non-decreasing.
    private func assertMonotonic(_ words: [WordTiming], file: StaticString = #filePath, line: UInt = #line) {
        for k in 1..<max(1, words.count) {
            XCTAssertGreaterThanOrEqual(
                words[k].start, words[k - 1].start,
                "word timings must be monotonic", file: file, line: line
            )
        }
    }

    /// Lowercased, punctuation-stripped, whitespace-collapsed — so assertions
    /// don't hinge on exact casing/punctuation from a tiny model.
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.map { ($0.isLetter || $0.isNumber || $0 == " ") ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Writes a synthetic mono 440 Hz sine to a temp `.caf` at `sampleRate` for
    /// `seconds` — the input for the engine-free decode/resample test (P1-3).
    private static func writeSyntheticSine(seconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-decode-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let total = AVAudioFrameCount((seconds * sampleRate).rounded())
        let chunk: AVAudioFrameCount = 8_192
        var written: AVAudioFrameCount = 0
        var phase = 0.0
        let step = 2.0 * Double.pi * 440.0 / sampleRate
        while written < total {
            let n = min(chunk, total - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else {
                throw NSError(domain: "WhisperCppTranscriptionServiceTests", code: 1)
            }
            buffer.frameLength = n
            if let channel = buffer.floatChannelData {
                for i in 0..<Int(n) {
                    channel[0][i] = Float(sin(phase))
                    phase += step
                }
            }
            try file.write(from: buffer)
            written += n
        }
        return url
    }

    /// The committed spoken fixture, looked up from the test bundle (synchronized
    /// groups copy it in flat; the recursive fallback covers a nested copy).
    private func fixtureAudioURL() throws -> URL {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: "fox", withExtension: "m4a") {
            return url
        }
        if let url = bundle.url(forResource: "fox", withExtension: "m4a", subdirectory: "Fixtures/Whisper") {
            return url
        }
        if let resourceURL = bundle.resourceURL,
           let found = FileManager.default
            .enumerator(at: resourceURL, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == "fox.m4a" }) {
            return found
        }
        throw XCTSkip("fox.m4a fixture not found in test bundle")
    }

    // MARK: - tiny.en test model resolution

    private enum TestModel {
        static let fileName = "ggml-tiny.en-q5_1.bin"
        static let url = URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q5_1.bin")!
        static let sha256 = "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b"
        static let byteSize = 32_166_155

        /// CI sets this so a missing/undownloadable model FAILS instead of skipping.
        static var isRequired: Bool {
            let raw = (ProcessInfo.processInfo.environment["ZERRO_WHISPER_TEST_REQUIRE"] ?? "").lowercased()
            return ["1", "true", "yes"].contains(raw)
        }
    }

    /// Resolves a local tiny.en model path, or throws `XCTSkip` when it can't be
    /// obtained and the run isn't marked required. Resolution order: explicit
    /// env path → checksum-verified cache → one-time verified download.
    private func resolveTestModelOrSkip() async throws -> URL {
        do {
            return try await Self.resolveTestModel()
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            if TestModel.isRequired {
                throw error   // CI: never silently skip the real engine coverage.
            }
            throw XCTSkip("tiny.en model unavailable (offline?) — \(error.localizedDescription)")
        }
    }

    private static func resolveTestModel() async throws -> URL {
        let fm = FileManager.default

        // 1. Explicit path (CI pre-download / local override).
        if let override = ProcessInfo.processInfo.environment["ZERRO_WHISPER_MODEL_PATH"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fm.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url
        }

        // 2. Checksum-verified cache.
        let cacheDir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ZerroTests/whisper-models", isDirectory: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent(TestModel.fileName)
        if fm.fileExists(atPath: cached.path), try checksumMatches(cached) {
            return cached
        }

        // 3. One-time download → verify → cache (atomic replace).
        let (temp, _) = try await URLSession.shared.download(from: TestModel.url)
        guard try checksumMatches(temp) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if fm.fileExists(atPath: cached.path) { try? fm.removeItem(at: cached) }
        try fm.moveItem(at: temp, to: cached)
        return cached
    }

    private static func checksumMatches(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == TestModel.byteSize else { return false }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == TestModel.sha256
    }
}
