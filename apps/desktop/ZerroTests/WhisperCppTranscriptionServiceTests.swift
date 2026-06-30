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
