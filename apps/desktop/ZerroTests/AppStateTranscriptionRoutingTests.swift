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
//   • a thrown `.modelUnavailable` / `.missingAPIKey` surfaces as the
//     `.localModelUnavailable` / `.apiKeyMissing` failure pill.
//  The injected services throw before generation, so no chat call is dispatched.
//
//  Phase 6 (Local Whisper) — adds the recording-time wait: when a model download
//  is IN FLIGHT and the engine can use it (.auto/.local), the transcription step
//  WAITS (driven by an injected `localModelStateProvider`) until the manager
//  reaches a terminal state — `.ready` → transcribe via the now-local service;
//  `.failed`/`.notDownloaded` → surface `.localModelUnavailable`.
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
        app.resolveTranscriptionService = { AppState.ResolvedTranscription(service: fake, isLocal: false) }

        let processed = makeProcessed(hasSpeech: true)
        drive(app, processed)
        try await waitUntilSettled(app)

        XCTAssertEqual(fake.callCount, 1, "AppState used the resolved service for transcription")
        XCTAssertEqual(fake.lastAudioURL?.lastPathComponent, "audio.m4a")
        XCTAssertEqual(fake.lastWordTimestamps, false, "a normal (non-Dev) recording requests no word timing")
    }

    func testNeedsLocalModelSurfacesAsLocalModelUnavailable() async throws {
        let app = AppState()
        // No download in flight (no manager wired → `.notDownloaded`), so the
        // Phase-6 wait is skipped and the resolver's `.modelUnavailable` surfaces
        // directly.
        app.resolveTranscriptionService = { throw TranscriptionError.modelUnavailable }

        drive(app, makeProcessed(hasSpeech: true))
        try await waitUntilSettled(app)

        guard case .failed(let reason) = app.state else {
            return XCTFail("expected .failed, got \(app.state)")
        }
        // Phase 6: the dedicated, actionable reason (replaces the Phase-1
        // `.processingFailed` placeholder).
        XCTAssertEqual(reason, .localModelUnavailable)
    }

    // MARK: - Phase 6 wait-for-download

    /// downloading + `.auto` → the transcription step WAITS, and once the manager
    /// reports `.ready` it proceeds to transcribe via the resolved (local) service.
    /// This is the primary persona: `.auto` with no OpenAI key whose model is
    /// finishing its first download — previously a `.missingAPIKey` failure.
    func testDownloadingThenReadyProceedsToLocalTranscription() async throws {
        let app = AppState()
        let fake = RecordingTranscriptionService()
        // isLocal: true — after the wait, the resolver yields the on-device engine.
        app.resolveTranscriptionService = { AppState.ResolvedTranscription(service: fake, isLocal: true) }

        // Evolve the model state across the wait's polls: downloading until the
        // third read, then ready.
        var reads = 0
        app.localModelStateProvider = {
            reads += 1
            return reads >= 3
                ? .ready(version: "test-v1")
                : .downloading(progress: 0.5, downloadedBytes: 100, totalBytes: 200)
        }

        drive(app, makeProcessed(hasSpeech: true))
        try await waitUntilSettled(app)

        XCTAssertGreaterThanOrEqual(reads, 3, "the step polled the model state until it became ready")
        XCTAssertEqual(fake.callCount, 1, "after the model was ready, transcription ran via the resolved local service")
    }

    /// downloading + `.local` also waits (engine set explicitly), then transcribes
    /// on `.ready`.
    func testDownloadingThenReadyWaitsForExplicitLocalEngine() async throws {
        let app = AppState()
        let prefs = PreferencesStore()
        prefs.sttEngine = .local
        app.preferences = prefs
        let fake = RecordingTranscriptionService()
        app.resolveTranscriptionService = { AppState.ResolvedTranscription(service: fake, isLocal: true) }

        var reads = 0
        app.localModelStateProvider = {
            reads += 1
            return reads >= 2
                ? .ready(version: "test-v1")
                : .downloading(progress: 0.9, downloadedBytes: 180, totalBytes: 200)
        }

        drive(app, makeProcessed(hasSpeech: true))
        try await waitUntilSettled(app)

        XCTAssertEqual(fake.callCount, 1, "explicit .local engine waited, then transcribed once ready")
    }

    /// downloading → `.failed`: the wait ends, the resolver runs and (with no
    /// installed model) throws `.modelUnavailable`, which surfaces as the dedicated
    /// `.localModelUnavailable` pill — NOT a transcribe attempt.
    func testDownloadEndingInFailedSurfacesLocalModelUnavailable() async throws {
        let app = AppState()
        // A failed download leaves no model, so the resolver throws
        // `.modelUnavailable` (engine `.local` with no model installed) — it never
        // returns a service, so transcription is structurally never attempted.
        app.resolveTranscriptionService = { throw TranscriptionError.modelUnavailable }

        var reads = 0
        app.localModelStateProvider = {
            reads += 1
            return reads >= 2
                ? .failed(reason: "network dropped")
                : .downloading(progress: 0.2, downloadedBytes: 40, totalBytes: 200)
        }

        drive(app, makeProcessed(hasSpeech: true))
        try await waitUntilSettled(app)

        guard case .failed(let reason) = app.state else {
            return XCTFail("expected .failed, got \(app.state)")
        }
        XCTAssertEqual(reason, .localModelUnavailable)
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
