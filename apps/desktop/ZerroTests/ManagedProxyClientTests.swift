//
//  ManagedProxyClientTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/2/26.
//
//  Phase E — unit coverage for the Managed generation proxy. Two stub
//  transports: one for the session manager (mints tokens), one for the proxy
//  (serves `/generate`). Covers:
//    • Success → prompt + usage + credits parsed into the result.
//    • A 401 mid-use → ONE transparent token refresh + retry, then success.
//    • 402 → out-of-credits; 5xx → retryable provider error.
//    • The request sends audio + frames + mode ONLY — never a transcript or
//      system prompt — and a Bearer token, never the license key.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class ManagedProxyClientTests: XCTestCase {

    private func makeStack(
        sessionTransport: StubManagedTransport,
        genTransport: StubManagedTransport,
        key: String = "LICENSE-123"
    ) -> (SessionTokenManager, ManagedProxyClient) {
        let tokens = SessionTokenManager(
            licenseKeySlot: InMemoryKeychainSlot(key),
            transport: sessionTransport
        )
        let proxy = ManagedProxyClient(sessionTokens: tokens, transport: genTransport)
        return (tokens, proxy)
    }

    private func frames() -> [ExtractedFrame] {
        [ExtractedFrame(url: ManagedFixtures.tempFile(), timestamp: .zero, index: 0)]
    }

    // MARK: - Success

    func testSuccessParsesResult() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(ManagedFixtures.generateJSON(prompt: "Ship it.", creditsRemaining: 42), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        let result = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            mode: .instruct,
            durationSeconds: 12
        )

        XCTAssertEqual(result.result.prompt, "Ship it.")
        XCTAssertEqual(result.result.usage.inputTokens, 1200)
        XCTAssertEqual(result.result.usage.outputTokens, 300)
        XCTAssertEqual(result.creditsRemaining, 42)
    }

    // MARK: - Token expiry → refresh-and-retry once

    func testTokenExpiredRefreshesAndRetriesOnce() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200) // validToken
        session.enqueue(ManagedFixtures.sessionJSON(token: "T2"), status: 200) // refreshToken
        let gen = StubManagedTransport()
        gen.enqueue(#"{"error":"invalid_token"}"#, status: 401)                 // first attempt
        gen.enqueue(ManagedFixtures.generateJSON(prompt: "Retried.", creditsRemaining: 5), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        let result = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            mode: .explain,
            durationSeconds: nil
        )

        XCTAssertEqual(result.result.prompt, "Retried.")
        // Exactly two /generate attempts; the retry used the refreshed token.
        XCTAssertEqual(gen.requests.count, 2)
        XCTAssertEqual(gen.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer T1")
        XCTAssertEqual(gen.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer T2")
        XCTAssertEqual(session.callCount, 2)
    }

    // MARK: - Idempotency key (M1)

    /// The `Idempotency-Key` header is sent, and the SAME key rides the
    /// post-refresh retry — so a 401-driven retry can't make the server
    /// double-charge.
    func testIdempotencyKeySentAndReusedAcrossRefresh() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200) // validToken
        session.enqueue(ManagedFixtures.sessionJSON(token: "T2"), status: 200) // refreshToken
        let gen = StubManagedTransport()
        gen.enqueue(#"{"error":"invalid_token"}"#, status: 401)                 // first attempt
        gen.enqueue(ManagedFixtures.generateJSON(prompt: "Retried.", creditsRemaining: 5), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        _ = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            mode: .instruct,
            durationSeconds: nil,
            idempotencyKey: "REC-KEY-1"
        )

        XCTAssertEqual(gen.requests.count, 2)
        XCTAssertEqual(gen.requests[0].value(forHTTPHeaderField: "Idempotency-Key"), "REC-KEY-1")
        XCTAssertEqual(gen.requests[1].value(forHTTPHeaderField: "Idempotency-Key"), "REC-KEY-1")
    }

    func testRepeatedAuthFailureSurfacesAuthFailed() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        session.enqueue(ManagedFixtures.sessionJSON(token: "T2"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(#"{"error":"invalid_token"}"#, status: 401)
        gen.enqueue(#"{"error":"invalid_token"}"#, status: 401)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        await assertThrows(.authFailed) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), mode: .instruct, durationSeconds: nil)
        }
    }

    // MARK: - Error mapping

    func testOutOfCreditsMapped() async throws {
        let (session, gen) = freshStubs(genStatus: 402, genBody: #"{"error":"out_of_credits"}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.outOfCredits) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), mode: .instruct, durationSeconds: nil)
        }
    }

    func testServerErrorIsRetryableProviderUnavailable() async throws {
        let (session, gen) = freshStubs(genStatus: 503, genBody: #"{"error":"openai_unavailable","retryable":true}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.providerUnavailable) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), mode: .instruct, durationSeconds: nil)
        }
    }

    func testNotEntitledMapped() async throws {
        let (session, gen) = freshStubs(genStatus: 403, genBody: #"{"error":"not_entitled"}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.notEntitled) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), mode: .instruct, durationSeconds: nil)
        }
    }

    // MARK: - Payload shape

    func testRequestSendsAudioFramesModeOnly() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(ManagedFixtures.generateJSON(), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen, key: "SECRET-KEY")

        _ = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            mode: .instruct,
            durationSeconds: 7,
            clicks: [ResolvedClick(seconds: 1.5, label: "Save")]
        )

        let req = gen.requests[0]
        XCTAssertEqual(req.url, ManagedBackend.generateURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T1")

        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Exactly mode + audio + frames + clicks + has_speech — nothing else.
        XCTAssertEqual(Set(json.keys), ["mode", "audio", "frames", "clicks", "has_speech"])
        XCTAssertEqual(json["mode"] as? String, "instruct")
        // Phase 6: the no-speech hint defaults to true when not specified.
        XCTAssertEqual(json["has_speech"] as? Bool, true)
        // No transcript / prompt / system prompt smuggled in.
        let raw = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("transcript"))
        XCTAssertFalse(raw.contains("system"))
        XCTAssertFalse(raw.contains("SECRET-KEY"), "license key must never reach /generate")

        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        XCTAssertEqual(audio["mime"] as? String, "audio/m4a")
        XCTAssertNotNil(audio["data"] as? String)
        XCTAssertEqual(audio["duration_seconds"] as? Double, 7)

        let frameArr = try XCTUnwrap(json["frames"] as? [[String: Any]])
        XCTAssertEqual(frameArr.count, 1)
        XCTAssertEqual(frameArr[0]["mime"] as? String, "image/jpeg")
        XCTAssertNotNil(frameArr[0]["data"] as? String)

        // Phase 4: the clicks ride as { timestamp, label } objects.
        let clickArr = try XCTUnwrap(json["clicks"] as? [[String: Any]])
        XCTAssertEqual(clickArr.count, 1)
        XCTAssertEqual(clickArr[0]["timestamp"] as? Double, 1.5)
        XCTAssertEqual(clickArr[0]["label"] as? String, "Save")
    }

    /// Phase 6: a no-speech recording sends `has_speech:false`, the flag the
    /// server keys on to skip Whisper.
    func testRequestSendsHasSpeechFalseWhenNoSpeech() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(ManagedFixtures.generateJSON(), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen, key: "SECRET-KEY")

        _ = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            mode: .instruct,
            durationSeconds: 7,
            hasSpeech: false
        )

        let body = try XCTUnwrap(gen.requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["has_speech"] as? Bool, false)
    }

    // MARK: - Helpers

    private func freshStubs(genStatus: Int, genBody: String) -> (StubManagedTransport, StubManagedTransport) {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(genBody, status: genStatus)
        return (session, gen)
    }

    private func assertThrows(
        _ expected: ManagedGenerationError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ManagedGenerationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
