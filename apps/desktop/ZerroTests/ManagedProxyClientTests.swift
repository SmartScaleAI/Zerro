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
//    • The request sends audio + frames + clicks (+ model/has_speech) ONLY —
//      never a transcript, a system prompt, or anything that steers the
//      server-owned prompt — and a Bearer token, never the license key.
//    • convert (Phase 6): text-only body to /convert, suffixed idempotency
//      key, same refresh-once + error taxonomy.
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
        gen.enqueue(ManagedFixtures.generateJSON(prompt: "Ship it.", creditsRemaining: 42, creditsCharged: 7), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        let result = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            durationSeconds: 12
        )

        XCTAssertEqual(result.result.prompt, "Ship it.")
        XCTAssertEqual(result.result.usage.inputTokens, 1200)
        XCTAssertEqual(result.result.usage.outputTokens, 300)
        XCTAssertEqual(result.creditsRemaining, 42)
        // Multi-model D2: the exact server spend for the "−N credits" toast.
        XCTAssertEqual(result.creditsCharged, 7)
    }

    /// A pre-D2 backend body (no `credits_charged`) still parses — the toast
    /// simply has nothing to show during a rollout window.
    func testPreD2ResponseParsesWithoutCreditsCharged() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(ManagedFixtures.generateJSONPreD2(creditsRemaining: 12), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        let result = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            durationSeconds: 12
        )
        XCTAssertEqual(result.creditsRemaining, 12)
        XCTAssertNil(result.creditsCharged)
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
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), durationSeconds: nil)
        }
    }

    // MARK: - Error mapping

    func testOutOfCreditsMapped() async throws {
        let (session, gen) = freshStubs(genStatus: 402, genBody: #"{"error":"out_of_credits"}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.outOfCredits) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), durationSeconds: nil)
        }
    }

    func testServerErrorIsRetryableProviderUnavailable() async throws {
        let (session, gen) = freshStubs(genStatus: 503, genBody: #"{"error":"openai_unavailable","retryable":true}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.providerUnavailable) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), durationSeconds: nil)
        }
    }

    func testNotEntitledMapped() async throws {
        let (session, gen) = freshStubs(genStatus: 403, genBody: #"{"error":"not_entitled"}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.notEntitled) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), durationSeconds: nil)
        }
    }

    /// The server returns 422 when the generation hit the output-token limit
    /// and withheld the half-formed prompt (handoff-artifact-fence-leak); the
    /// client surfaces it distinctly so the pill shows a "too long" state rather
    /// than a generic provider error or a leaked fence.
    func testResponseTruncatedMapped() async throws {
        let (session, gen) = freshStubs(genStatus: 422, genBody: #"{"error":"response_truncated","retryable":false}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.responseTruncated) {
            _ = try await proxy.generate(audioURL: ManagedFixtures.tempFile(), frames: self.frames(), durationSeconds: nil)
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
            durationSeconds: 7,
            clicks: [ResolvedClick(seconds: 1.5, label: "Save")]
        )

        let req = gen.requests[0]
        XCTAssertEqual(req.url, ManagedBackend.generateURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T1")

        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Exactly model + audio + frames + clicks + has_speech — nothing else.
        // Typed-artifact refactor: `mode` is gone from the wire; the client
        // sends NOTHING that steers the server-owned prompt.
        XCTAssertEqual(Set(json.keys), ["model", "audio", "frames", "clicks", "has_speech"])
        XCTAssertFalse(json.keys.contains("mode"), "v1 mode field must not ride the wire")
        // Multi-model 6B: when no model is passed, the registry default
        // (the recommended model) rides as the explicit wire value.
        XCTAssertEqual(json["model"] as? String, ModelRegistry.defaultModelID)
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
            durationSeconds: 7,
            hasSpeech: false
        )

        let body = try XCTUnwrap(gen.requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["has_speech"] as? Bool, false)
    }

    /// Multi-model 6B: the selected model id rides in the body verbatim.
    func testRequestSendsSelectedModel() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(ManagedFixtures.generateJSON(), status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        _ = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: frames(),
            durationSeconds: 7,
            model: "claude-opus-4-7"
        )

        let body = try XCTUnwrap(gen.requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-opus-4-7")
    }

    // MARK: - Convert (Phase 6 — the free "Write agent prompt" fallback)

    func testConvertPostsToConvertURLWithSuffixedIdempotencyKey() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(#"{"prompt":"<<<ZERRO_ARTIFACT type=\"agent_prompt\" title=\"T\">>>\nbody\n<<<END_ZERRO_ARTIFACT>>>"}"#, status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        let raw = try await proxy.convert(
            sourceText: "The error is a stale lockfile.",
            context: "## Attached Context\n**Clicks:** clicked \"Install\"",
            model: "gemini-3.5-flash",
            idempotencyKey: "REC-1:convert"
        )

        XCTAssertTrue(raw.contains("<<<ZERRO_ARTIFACT"))
        let request = try XCTUnwrap(gen.requests.first)
        XCTAssertEqual(request.url, ManagedBackend.convertURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "REC-1:convert")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer T1")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            ["source_text", "context", "model"],
            "the convert body carries text fields ONLY — no audio, no frames, no transcript"
        )
        XCTAssertEqual(json["source_text"] as? String, "The error is a stale lockfile.")
        XCTAssertEqual(json["model"] as? String, "gemini-3.5-flash")
    }

    func testConvertOmitsNilContextAndRefreshesOnceOn401() async throws {
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        session.enqueue(ManagedFixtures.sessionJSON(token: "T2"), status: 200)
        let gen = StubManagedTransport()
        gen.enqueue(#"{"error":"invalid_token"}"#, status: 401)
        gen.enqueue(#"{"prompt":"converted"}"#, status: 200)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)

        let raw = try await proxy.convert(sourceText: "src", context: nil, idempotencyKey: "K:convert")
        XCTAssertEqual(raw, "converted")
        XCTAssertEqual(gen.callCount, 2, "exactly one refresh+retry")
        XCTAssertEqual(gen.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer T2")
        XCTAssertEqual(gen.requests[1].value(forHTTPHeaderField: "Idempotency-Key"), "K:convert")

        let body = try XCTUnwrap(gen.requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["context"], "nil context is omitted from the wire, not sent as null/empty")
    }

    func testConvertErrorMapping() async {
        // (status, expected) — same taxonomy as generate's parse.
        let cases: [(Int, String, ManagedGenerationError)] = [
            (429, #"{"error":"rate_limited"}"#, .rateLimited),
            (503, #"{"error":"provider_unavailable"}"#, .providerUnavailable),
            (403, #"{"error":"not_entitled"}"#, .notEntitled),
        ]
        for (status, body, expected) in cases {
            let (session, gen) = freshStubs(genStatus: status, genBody: body)
            let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
            await assertThrows(expected) {
                _ = try await proxy.convert(sourceText: "src", context: nil)
            }
        }
    }

    func testConvertEmptyPromptIsMalformed() async {
        let (session, gen) = freshStubs(genStatus: 200, genBody: #"{"prompt":""}"#)
        let (_, proxy) = makeStack(sessionTransport: session, genTransport: gen)
        await assertThrows(.malformedResponse) {
            _ = try await proxy.convert(sourceText: "src", context: nil)
        }
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
