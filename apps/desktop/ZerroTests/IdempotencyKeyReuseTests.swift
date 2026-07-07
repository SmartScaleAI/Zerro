//
//  IdempotencyKeyReuseTests.swift
//  ZerroTests
//
//  B-07 (part 2) — regression pins for the idempotency-key STABILITY contract:
//  one key per recording (`ProcessedRecording.idempotencyKey`), reused across
//  EVERY retry so the server replays a charged result instead of double-charging.
//
//  The transport-level half (a 401 → token-refresh → retry rides the SAME
//  `Idempotency-Key` header) is pinned in `ManagedProxyClientTests.
//  testIdempotencyKeySentAndReusedAcrossRefresh`. This file pins the
//  APP-level half those tests can't see:
//    • `AppState.retryFailedPrompt` (the user-driven Retry on the error pill)
//      re-dispatches with the SAME key the first attempt used — it must never
//      mint a fresh one (that would re-bill a charged-but-dropped generation).
//    • Each NEW recording mints its OWN key (per-recording, not a constant),
//      and a retry leaves the held recording's key unchanged.
//
//  Drives the real `runPromptGeneration` route: an `EntitlementStore` pinned
//  to `.managed` routes `.managedProxy`, and the proxy runs against the shared
//  `StubManagedTransport` doubles — every /generate request is recorded, so the
//  header assertions read exactly what would hit the wire.
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

    // MARK: - (b) retryFailedPrompt reuses the recording's key

    /// First attempt fails retryably (503 → `.providerUnavailable`), the user
    /// taps Retry (`retryFailedPrompt`) — the second /generate request must
    /// carry the SAME `Idempotency-Key` as the first: the recording's stable
    /// `ProcessedRecording.idempotencyKey`, never a freshly minted one.
    func testRetryFailedPromptReusesIdempotencyKey() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(#"{"error":"openai_unavailable"}"#, status: 503) // attempt 1
        gen.enqueue(#"{"error":"openai_unavailable"}"#, status: 503) // user retry

        let app = makeManagedApp(sessionTransport: session, genTransport: gen)
        let processed = try makeProcessed(idempotencyKey: "STABLE-KEY-1")

        // First dispatch → retryable failure.
        app.state = .processing
        app.processedRecording = processed
        app.runPromptGeneration(processed: processed)
        try await waitUntilSettled(app)

        guard case .failed(let reason) = app.state else {
            return XCTFail("expected a retryable failure, got \(app.state)")
        }
        XCTAssertEqual(reason, .providerUnavailable)
        XCTAssertTrue(app.canRetryFailure, "a 503 with the recording held must offer Retry")
        XCTAssertEqual(gen.requests.count, 1)
        XCTAssertEqual(gen.requests[0].value(forHTTPHeaderField: "Idempotency-Key"), "STABLE-KEY-1")

        // User-driven Retry → the SAME key rides the second request.
        app.retryFailedPrompt()
        try await waitUntilSettled(app)

        XCTAssertEqual(gen.requests.count, 2, "retry must re-dispatch exactly one more /generate")
        XCTAssertEqual(gen.requests[1].value(forHTTPHeaderField: "Idempotency-Key"), "STABLE-KEY-1",
                       "a user-driven retry must reuse the recording's key — a fresh key would double-charge")
        XCTAssertEqual(
            gen.requests[0].value(forHTTPHeaderField: "Idempotency-Key"),
            gen.requests[1].value(forHTTPHeaderField: "Idempotency-Key")
        )
        // The held recording still carries the original key (set once, unchanged).
        XCTAssertEqual(app.processedRecording?.idempotencyKey, "STABLE-KEY-1")
    }

    // MARK: - (c) one key per recording, set once

    /// The key is minted once per NEW recording — two recordings never share a
    /// key (it's per-recording, not a constant), and it's never empty. The
    /// "unchanged across retry" half is pinned above (the key is a `let`; the
    /// retry path reuses the same `ProcessedRecording` value).
    func testEachNewRecordingMintsItsOwnKey() throws {
        let first = try makeProcessed()
        let second = try makeProcessed()
        XCTAssertFalse(first.idempotencyKey.isEmpty)
        XCTAssertFalse(second.idempotencyKey.isEmpty)
        XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey,
                          "every new recording must mint its own key")
    }

    // MARK: - Helpers

    /// An AppState wired for the `.managedProxy` route: a `.managed`-pinned
    /// EntitlementStore (held strongly by the test — AppState's ref is weak)
    /// plus a ManagedProxyClient over the stub transports.
    private func makeManagedApp(
        sessionTransport: StubManagedTransport,
        genTransport: StubManagedTransport
    ) -> AppState {
        let app = AppState()
        let store = EntitlementStore.preview(
            .managed(creditsRemaining: 100, resetDate: .distantFuture)
        )
        entitlements = store
        app.entitlements = store
        let tokens = SessionTokenManager(
            licenseKeySlot: InMemoryKeychainSlot("LICENSE-123"),
            transport: sessionTransport
        )
        app.managedProxyClient = ManagedProxyClient(sessionTokens: tokens, transport: genTransport)
        return app
    }

    /// A ProcessedRecording whose working dir + audio.m4a really exist on disk
    /// (the proxy path reads the audio at request-build time; a missing file
    /// would fail `.artifactUnreadable` before any request is recorded).
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
