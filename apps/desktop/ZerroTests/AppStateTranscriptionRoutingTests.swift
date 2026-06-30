//
//  AppStateTranscriptionRoutingTests.swift
//  ZerroTests
//
//  Phase 3 (Local Whisper) — the AppState-level wiring of the STT seam. A fresh
//  `AppState()` has `entitlements == nil`, so `runPromptGeneration` falls back to
//  the `.local` route (`runLocalPromptGeneration`). We inject
//  `resolveTranscriptionService` (mirroring `canGenerateLocallyProvider`) to drive the
//  transcription step without a Keychain/model/network:
//   • the recording uses whatever service the resolver returns (proving the
//     hardcoded `OpenAITranscriptionService()` is gone), and
//   • a thrown `.modelUnavailable` / `.missingAPIKey` surfaces as the existing
//     `.processingFailed` (Phase-1 placeholder) / `.apiKeyMissing` failure pill.
//  The injected services throw before generation, so no chat call is dispatched.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class AppStateTranscriptionRoutingTests: XCTestCase {

    /// Records the transcribe call, then throws so the flow stops before any chat
    /// generation (no network in a unit test).
    private final class RecordingTranscriptionService: TranscriptionService {
        struct StopError: Error {}
        private(set) var callCount = 0
        private(set) var lastAudioURL: URL?
        private(set) var lastWordTimestamps: Bool?
        func transcribe(audioFileURL: URL, wordTimestamps: Bool) async throws -> Transcript {
            callCount += 1
            lastAudioURL = audioFileURL
            lastWordTimestamps = wordTimestamps
            throw StopError()
        }
    }

    private var workingDirs: [URL] = []

    override func tearDown() {
        for dir in workingDirs { try? FileManager.default.removeItem(at: dir) }
        workingDirs.removeAll()
        super.tearDown()
    }

    func testLocalPathUsesResolvedServiceForTranscription() async throws {
        let app = AppState()
        let fake = RecordingTranscriptionService()
        app.resolveTranscriptionService = { fake }

        let processed = makeProcessed(hasSpeech: true)
        drive(app, processed)
        try await waitUntilSettled(app)

        XCTAssertEqual(fake.callCount, 1, "AppState used the resolved service for transcription")
        XCTAssertEqual(fake.lastAudioURL?.lastPathComponent, "audio.m4a")
        XCTAssertEqual(fake.lastWordTimestamps, false, "a normal (non-Dev) recording requests no word timing")
    }

    func testNeedsLocalModelSurfacesAsProcessingFailed() async throws {
        let app = AppState()
        app.resolveTranscriptionService = { throw TranscriptionError.modelUnavailable }

        drive(app, makeProcessed(hasSpeech: true))
        try await waitUntilSettled(app)

        guard case .failed(let reason) = app.state else {
            return XCTFail("expected .failed, got \(app.state)")
        }
        // Phase-1 placeholder mapping (the dedicated reason lands in Phase 6).
        XCTAssertEqual(reason, .processingFailed)
    }

    func testNeedsOpenAIKeySurfacesAsApiKeyMissing() async throws {
        let app = AppState()
        app.resolveTranscriptionService = { throw TranscriptionError.missingAPIKey }

        drive(app, makeProcessed(hasSpeech: true))
        try await waitUntilSettled(app)

        guard case .failed(let reason) = app.state else {
            return XCTFail("expected .failed, got \(app.state)")
        }
        XCTAssertEqual(reason, .apiKeyMissing)
    }

    // NOTE: the no-speech non-breaking case (the resolver is never consulted, so a
    // silent clip is byte-identical to before) is guaranteed structurally — the
    // resolution lives inside `if processed.hasSpeech` and `sttWasLocal` stays
    // false — and isn't driven here because the no-speech path proceeds into chat
    // generation, which a unit test deliberately does not dispatch.

    // MARK: - Helpers

    private func drive(_ app: AppState, _ processed: ProcessedRecording) {
        app.state = .processing
        app.processedRecording = processed
        app.runPromptGeneration(processed: processed)
    }

    private func waitUntilSettled(_ app: AppState, timeout: TimeInterval = 5) async throws {
        var waited = 0.0
        while waited < timeout {
            if case .processing = app.state {} else { return }
            try await Task.sleep(nanoseconds: 10_000_000)   // 10 ms
            waited += 0.01
        }
    }

    private func makeProcessed(hasSpeech: Bool) -> ProcessedRecording {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerro-stt-route-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workingDirs.append(dir)
        return ProcessedRecording(
            audioURL: dir.appendingPathComponent("audio.m4a"),
            frames: [],
            duration: CMTime(seconds: 4, preferredTimescale: 600),
            workingDirectory: dir,
            clicks: [],
            hasSpeech: hasSpeech
        )
    }
}
