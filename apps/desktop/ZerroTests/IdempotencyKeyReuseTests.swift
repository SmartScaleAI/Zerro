//
//  IdempotencyKeyReuseTests.swift
//  ZerroTests
//
//  Regression pins for the idempotency-key STABILITY contract: one key per
//  recording (`ProcessedRecording.idempotencyKey`), reused across EVERY
//  retry — the key is the recording's stable identity for provider-side
//  request dedup and the local history/recovery bookkeeping.
//    • `AppState.retryFailedPrompt` (the user-driven Retry on the error pill)
//      re-dispatches the SAME held recording — it must never mint a fresh
//      key or swap in a different `ProcessedRecording`.
//    • Each NEW recording mints its OWN key (per-recording, not a constant).
//
//  Drives the real `runPromptGeneration` entry point with the transcription
//  resolver INJECTED to fail deterministically, so the local pipeline settles
//  on a controlled failure with no installed-model inspection, no real
//  Keychain reads, and no network.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class IdempotencyKeyReuseTests: XCTestCase {

    private var workingDirs: [URL] = []
    /// AppState holds `entitlements` weakly — the test owns the store.
    private var entitlements: EntitlementStore?

    override func tearDown() {
        for dir in workingDirs { try? FileManager.default.removeItem(at: dir) }
        workingDirs.removeAll()
        entitlements = nil
        super.tearDown()
    }

    // MARK: - retryFailedPrompt re-dispatches the SAME recording

    /// First attempt fails retryably, the user taps Retry
    /// (`retryFailedPrompt`) — the held recording (and therefore its stable
    /// `idempotencyKey`) must be the exact value the first attempt used.
    func testRetryFailedPromptReusesTheHeldRecordingAndKey() async throws {
        let app = makeApp()
        // A retryable network-class failure from the injected resolver: the
        // pipeline maps it to `.networkOffline`, which offers Retry.
        app.resolveTranscriptionService = {
            throw TranscriptionError.network(underlying: URLError(.notConnectedToInternet))
        }
        let processed = try makeProcessed(idempotencyKey: "STABLE-KEY-1")

        app.state = .processing
        app.processedRecording = processed
        app.runPromptGeneration(processed: processed)
        try await waitUntilSettled(app)

        guard case .failed(let reason) = app.state else {
            return XCTFail("expected a retryable failure, got \(app.state)")
        }
        XCTAssertEqual(reason, .networkOffline)
        XCTAssertTrue(app.canRetryFailure, "a transient failure with the recording held must offer Retry")
        XCTAssertEqual(app.processedRecording?.idempotencyKey, "STABLE-KEY-1")

        app.retryFailedPrompt()
        try await waitUntilSettled(app)

        // The retry re-ran against the SAME held recording — key unchanged.
        XCTAssertEqual(app.processedRecording?.idempotencyKey, "STABLE-KEY-1",
                       "a user-driven retry must reuse the recording's key — never mint a fresh one")
        XCTAssertEqual(app.processedRecording?.workingDirectory, processed.workingDirectory)
    }

    // MARK: - one key per recording, set once

    func testEachNewRecordingMintsItsOwnKey() throws {
        let first = try makeProcessed()
        let second = try makeProcessed()
        XCTAssertFalse(first.idempotencyKey.isEmpty)
        XCTAssertFalse(second.idempotencyKey.isEmpty)
        XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey,
                          "every new recording must mint its own key")
    }

    // MARK: - Helpers

    /// An AppState over a licensed, in-memory entitlement store (held strongly
    /// by the test — AppState's ref is weak).
    private func makeApp() -> AppState {
        let app = AppState()
        let store = EntitlementStore.preview(.byok)
        entitlements = store
        app.entitlements = store
        return app
    }

    /// A ProcessedRecording whose working dir + audio.m4a really exist on disk.
    private func makeProcessed(idempotencyKey: String = UUID().uuidString) throws -> ProcessedRecording {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerro-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workingDirs.append(dir)
        let audioURL = dir.appendingPathComponent("audio.m4a")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: audioURL)
        return ProcessedRecording(
            audioURL: audioURL,
            frames: [],
            duration: CMTime(seconds: 4, preferredTimescale: 600),
            workingDirectory: dir,
            clicks: [],
            hasSpeech: true,
            idempotencyKey: idempotencyKey
        )
    }

    private func waitUntilSettled(_ app: AppState, timeout: TimeInterval = 5) async throws {
        var waited = 0.0
        while waited < timeout {
            if case .processing = app.state {} else { return }
            try await Task.sleep(nanoseconds: 10_000_000)   // 10 ms
            waited += 0.01
        }
        XCTFail("generation never settled within \(timeout)s")
    }
}
