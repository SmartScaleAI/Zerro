//
//  ManagedUploadCapTests.swift
//  ZerroTests
//
//  F-07 — the client-side pre-upload size fuse. `encodeBody` used to base64
//  whatever was on disk and POST it, so an oversized recording uploaded in
//  full only to get the server's 413 back. The client now mirrors the server's
//  input fuse (`supabase/functions/generate/config.ts`: GENERATE_MAX_AUDIO_BYTES
//  = 2 MB on the decoded audio, GENERATE_MAX_PAYLOAD_BYTES = 60 MB on the raw
//  body) via `ManagedBackend.maxAudioUploadBytes` / `.maxPayloadUploadBytes`
//  and fails LOCALLY with the distinct `.payloadTooLarge` — no bytes leave the
//  machine, nothing is charged.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class ManagedUploadCapTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    /// Writes `bytes` zero bytes to a unique temp file.
    private func tempFile(bytes: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-cap-test-\(UUID().uuidString)")
        try? Data(count: bytes).write(to: url)
        tempFiles.append(url)
        return url
    }

    private func makeStack(
        genTransport: StubManagedTransport
    ) -> (session: StubManagedTransport, proxy: ManagedProxyClient) {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let tokens = SessionTokenManager(
            licenseKeySlot: InMemoryKeychainSlot("LICENSE-123"),
            transport: session
        )
        return (session, ManagedProxyClient(sessionTokens: tokens, transport: genTransport))
    }

    /// The F-07 contract: an over-cap audio file fails locally with the size
    /// error and NEVER touches the network — neither `/generate` nor even the
    /// `/session` token mint.
    func testOverCapAudioFailsLocallyWithoutNetwork() async {
        let gen = StubManagedTransport()
        let (session, proxy) = makeStack(genTransport: gen)
        let oversized = tempFile(bytes: ManagedBackend.maxAudioUploadBytes + 1)

        do {
            _ = try await proxy.generate(
                audioURL: oversized,
                frames: [ExtractedFrame(url: tempFile(bytes: 4), timestamp: .zero, index: 0)],
                durationSeconds: 12
            )
            XCTFail("expected payloadTooLarge")
        } catch let error as ManagedGenerationError {
            XCTAssertEqual(error, .payloadTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(gen.callCount, 0, "an over-cap payload must never be uploaded")
        XCTAssertEqual(session.callCount, 0, "no token should be minted for a doomed request")
    }

    /// An audio file exactly AT the cap is allowed — the boundary mirrors the
    /// server's strictly-greater-than rejection — and the request proceeds.
    func testAtCapAudioProceeds() async throws {
        let gen = StubManagedTransport()
        gen.enqueue(ManagedFixtures.generateJSON(), status: 200)
        let (_, proxy) = makeStack(genTransport: gen)

        let result = try await proxy.generate(
            audioURL: tempFile(bytes: ManagedBackend.maxAudioUploadBytes),
            frames: [ExtractedFrame(url: tempFile(bytes: 4), timestamp: .zero, index: 0)],
            durationSeconds: 12
        )
        XCTAssertEqual(result.result.prompt, "Do the thing.")
        XCTAssertEqual(gen.callCount, 1)
    }

    /// The dev-transcribe (call 1) path shares the audio fuse.
    func testDevTranscribeOverCapAudioFailsLocally() async {
        let gen = StubManagedTransport()
        let (_, proxy) = makeStack(genTransport: gen)

        do {
            _ = try await proxy.devTranscribe(
                audioURL: tempFile(bytes: ManagedBackend.maxAudioUploadBytes + 1),
                durationSeconds: 12
            )
            XCTFail("expected payloadTooLarge")
        } catch let error as ManagedGenerationError {
            XCTAssertEqual(error, .payloadTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(gen.callCount, 0)
    }

    /// The raw-body fuse: an under-cap audio but an encoded body over the
    /// payload limit (one huge frame) also fails locally. Exercised through
    /// the encode helper directly so the test doesn't round-trip ~80 MB
    /// through the full client stack.
    func testOversizedEncodedPayloadFailsLocally() {
        // A frame whose base64 alone (~4/3 × size) exceeds the 60 MB body cap.
        let hugeFrame = tempFile(bytes: 50 * 1024 * 1024)
        XCTAssertThrowsError(
            try ManagedProxyClient.encodeBody(
                audioURL: tempFile(bytes: 4),
                frames: [ManagedProxyClient.FrameUpload(url: hugeFrame, timestamp: 0, ocrText: nil)],
                durationSeconds: 12
            )
        ) { error in
            XCTAssertEqual(error as? ManagedGenerationError, .payloadTooLarge)
        }
    }

    /// A normal-size recording encodes cleanly (the fuse is far above anything
    /// a real ≤3-minute recording produces).
    func testUnderCapPayloadEncodes() throws {
        let body = try ManagedProxyClient.encodeBody(
            audioURL: tempFile(bytes: 1_500_000), // ~a real 3-min AAC file
            frames: (0..<36).map { i in
                ManagedProxyClient.FrameUpload(url: tempFile(bytes: 150_000), timestamp: Double(i), ocrText: nil)
            },
            durationSeconds: 180
        )
        XCTAssertLessThanOrEqual(body.count, ManagedBackend.maxPayloadUploadBytes)
    }
}
