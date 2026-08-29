//
//  BYOKChatAdapterTests.swift
//  ZerroTests
//
//  J-06 — full generatePrompt() coverage for the three Swift BYOK CHAT
//  adapters (OpenAI / Anthropic / Gemini) through a URLProtocol stub,
//  modeled on the original server adapter suites (providers/openai_test.ts,
//  anthropic_test.ts, gemini_test.ts — since removed from the repository).
//  What already lives elsewhere is deliberately NOT duplicated here:
//    - OpenAIStatusMappingTests — error(forStatus:) unit mapping
//    - ProviderQuota429Tests — quota-429 detection + retry behavior
//    - RetryAfterClampTests — the J-04 Retry-After clamp
//    - BYOKRoutingTests — encodeBody wire shapes + the B-04 caps
//    - InterleaveGoldenFixtureTests — the interleave rendering
//  This file pins the pieces only reachable through the full flow:
//  response DTO parsing (text extraction, usage mapping, model echo),
//  truncation/refusal/safety-block/empty-content detection, malformed-
//  body → .decodeFailure, the inline Anthropic/Gemini status mapping
//  (J-02 401/403 → .auth; J-03 429 → .rateLimited), network-error
//  mapping, and the per-provider request wiring (auth headers, B-04 cap
//  on the actual HTTP body).
//

import XCTest
@testable import Zerro

// MARK: - URLProtocol stub

/// Serves queued outcomes in order, captures every request (headers + body)
/// that reaches the "network", and counts hits. State is static (URLProtocol
/// instantiates per request) and lock-guarded; the suite runs serially.
private nonisolated final class ChatAdapterStubURLProtocol: URLProtocol {
    enum Outcome {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Outcome] = []
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var lastCapturedRequest: URLRequest?
    nonisolated(unsafe) private static var lastCapturedBody = Data()

    static func reset(_ outcomes: [Outcome]) {
        lock.withLock {
            queue = outcomes
            requestCount = 0
            lastCapturedRequest = nil
            lastCapturedBody = Data()
        }
    }

    static var hits: Int { lock.withLock { requestCount } }
    static var lastRequest: URLRequest? { lock.withLock { lastCapturedRequest } }
    static var lastBody: Data { lock.withLock { lastCapturedBody } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession hands the POST body to a URLProtocol as a stream, not
    /// `httpBody` — drain it so tests can assert on the encoded request.
    private static func drainBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while stream.hasBytesAvailable {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                stream.read(ptr.baseAddress!, maxLength: ptr.count)
            }
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    override func startLoading() {
        let body = Self.drainBody(of: request)
        let outcome: Outcome = Self.lock.withLock {
            Self.requestCount += 1
            Self.lastCapturedRequest = request
            Self.lastCapturedBody = body
            return Self.queue.isEmpty
                ? .response(status: 200, headers: [:], body: Data("{}".utf8))
                : Self.queue.removeFirst()
        }
        switch outcome {
        case .response(let status, let headers, let responseBody):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class BYOKChatAdapterTests: XCTestCase {

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatAdapterStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A speech-only timeline: exercises the full flow without any frame
    /// file on disk (the disk-read failure path gets its own test).
    private let timeline = InterleavedTimeline(items: [
        .speech(start: 0, end: 2, text: "make the save button teal")
    ])

    private func makeOpenAI() -> OpenAIPromptGenerationService {
        var service = OpenAIPromptGenerationService(model: "gpt-4o")
        service.apiKeyOverride = "sk-test-key"
        service.session = stubbedSession()
        return service
    }

    private func makeAnthropic() -> AnthropicPromptGenerationService {
        var service = AnthropicPromptGenerationService(model: "claude-sonnet-4-6")
        service.apiKeyOverride = "sk-ant-test-key"
        service.session = stubbedSession()
        return service
    }

    private func makeGemini() -> GeminiPromptGenerationService {
        var service = GeminiPromptGenerationService(model: "gemini-3.5-flash")
        service.apiKeyOverride = "AIza-test-key"
        service.session = stubbedSession()
        return service
    }

    private func stub(_ status: Int, _ json: String, headers: [String: String] = [:]) {
        ChatAdapterStubURLProtocol.reset([
            .response(status: status, headers: headers, body: Data(json.utf8))
        ])
    }

    private func expectError(
        _ run: () async throws -> PromptGenerationResult,
        _ check: (PromptGenerationError) -> Bool,
        _ label: String
    ) async {
        do {
            _ = try await run()
            XCTFail("expected \(label), got success")
        } catch let error as PromptGenerationError {
            XCTAssertTrue(check(error), "expected \(label), got \(error)")
        } catch {
            XCTFail("expected \(label), got untyped \(error)")
        }
    }

    private func lastBodyJSON() throws -> NSDictionary {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: ChatAdapterStubURLProtocol.lastBody) as? NSDictionary
        )
    }

    // MARK: - OpenAI

    func testOpenAIWellFormedResponseParses() async throws {
        stub(200, """
        {"choices":[{"message":{"content":"Refined prompt"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":12,"completion_tokens":5},"model":"gpt-4o-2024-08-06"}
        """)
        let result = try await makeOpenAI().generatePrompt(timeline: timeline, systemPrompt: "sys")
        XCTAssertEqual(result.prompt, "Refined prompt")
        XCTAssertEqual(result.usage.inputTokens, 12)
        XCTAssertEqual(result.usage.outputTokens, 5)
        XCTAssertEqual(result.usage.model, "gpt-4o-2024-08-06", "the response's model echo wins over the requested id")
    }

    func testOpenAIRequestCarriesAuthCapAndSystemPrompt() async throws {
        stub(200, """
        {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
        """)
        _ = try await makeOpenAI().generatePrompt(timeline: timeline, systemPrompt: "the system prompt")

        let request = try XCTUnwrap(ChatAdapterStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 16384, "B-04 cap rides the actual HTTP body")
        XCTAssertEqual(body["model"] as? String, "gpt-4o")
        let messages = try XCTUnwrap(body["messages"] as? [NSDictionary])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "the system prompt")
    }

    func testOpenAILengthFinishThrowsTruncated() async {
        stub(200, """
        {"choices":[{"message":{"content":"partial <<<ZERRO_ARTIFACT"},"finish_reason":"length"}]}
        """)
        await expectError({ try await self.makeOpenAI().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .truncated = $0 { return true }; return false }, ".truncated")
    }

    func testOpenAIEmptyContentThrows() async {
        for body in [
            #"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#,
            #"{"choices":[{"message":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[]}"#,
        ] {
            stub(200, body)
            await expectError({ try await self.makeOpenAI().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                              { if case .emptyContent = $0 { return true }; return false }, ".emptyContent for \(body)")
        }
    }

    func testOpenAIMalformedBodyThrowsDecodeFailure() async {
        stub(200, "<html>not json</html>")
        await expectError({ try await self.makeOpenAI().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .decodeFailure = $0 { return true }; return false }, ".decodeFailure")
    }

    func testOpenAI403MapsToAuthThroughTheFullFlow() async {
        stub(403, #"{"error":{"message":"unsupported_country_region_territory"}}"#)
        await expectError({ try await self.makeOpenAI().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .auth = $0 { return true }; return false }, ".auth")
    }

    func testOpenAI500MapsToServerWithStatusOnly() async {
        stub(500, #"{"error":{"message":"secret internals sk-leaky"}}"#)
        await expectError({ try await self.makeOpenAI().generatePrompt(timeline: self.timeline, systemPrompt: "sys") }, {
            if case .server(let status) = $0 { return status == 500 }
            return false
        }, ".server(500)")
    }

    func testOpenAINetworkErrorMapsToNetwork() async {
        ChatAdapterStubURLProtocol.reset([.failure(URLError(.notConnectedToInternet))])
        await expectError({ try await self.makeOpenAI().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .network = $0 { return true }; return false }, ".network")
    }

    func testFrameDiskReadFailureMapsToNetworkWithoutTouchingTheWire() async {
        let missing = InterleavedTimeline(items: [
            .frame(timestamp: 0,
                   imageURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg"),
                   ocrText: nil)
        ])
        ChatAdapterStubURLProtocol.reset([])
        await expectError({ try await self.makeOpenAI().generatePrompt(timeline: missing, systemPrompt: "sys") },
                          { if case .network = $0 { return true }; return false }, ".network")
        XCTAssertEqual(ChatAdapterStubURLProtocol.hits, 0, "a local I/O failure must not issue a request")
    }

    // MARK: - Anthropic

    func testAnthropicWellFormedResponseJoinsTextBlocks() async throws {
        stub(200, """
        {"content":[{"type":"text","text":"Refined "},{"type":"tool_use","id":"x"},{"type":"text","text":"prompt"}],
         "stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":7},"model":"claude-sonnet-4-6-20260115"}
        """)
        let result = try await makeAnthropic().generatePrompt(timeline: timeline, systemPrompt: "sys")
        XCTAssertEqual(result.prompt, "Refined prompt", "non-text blocks are skipped, text blocks joined")
        XCTAssertEqual(result.usage.inputTokens, 20)
        XCTAssertEqual(result.usage.outputTokens, 7)
        XCTAssertEqual(result.usage.model, "claude-sonnet-4-6-20260115")
    }

    func testAnthropicRequestCarriesKeyHeadersCapAndTopLevelSystem() async throws {
        stub(200, """
        {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
        """)
        _ = try await makeAnthropic().generatePrompt(timeline: timeline, systemPrompt: "the system prompt")

        let request = try XCTUnwrap(ChatAdapterStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Anthropic auth is x-api-key, never Bearer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["max_tokens"] as? Int, 16384, "B-04 cap rides the actual HTTP body")
        XCTAssertEqual(body["system"] as? String, "the system prompt", "system prompt is top-level, never a message")
    }

    func testAnthropicMaxTokensStopThrowsTruncated() async {
        stub(200, """
        {"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}
        """)
        await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .truncated = $0 { return true }; return false }, ".truncated")
    }

    func testAnthropicRefusalThrowsEmptyContentEvenWithText() async {
        stub(200, """
        {"content":[{"type":"text","text":"I can't help with that."}],"stop_reason":"refusal"}
        """)
        await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .emptyContent = $0 { return true }; return false }, ".emptyContent")
    }

    func testAnthropicEmptyContentThrows() async {
        for body in [
            #"{"content":[],"stop_reason":"end_turn"}"#,
            #"{"content":[{"type":"tool_use","id":"x"}],"stop_reason":"end_turn"}"#,
            #"{"stop_reason":"end_turn"}"#,
        ] {
            stub(200, body)
            await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                              { if case .emptyContent = $0 { return true }; return false }, ".emptyContent for \(body)")
        }
    }

    func testAnthropicAuthStatusesMapToAuth() async {
        for status in [401, 403] {
            stub(status, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
            await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                              { if case .auth = $0 { return true }; return false }, ".auth for \(status)")
        }
    }

    func testAnthropic429MapsToRateLimited() async {
        // performWithRetry burns its single retry first (Retry-After: 0 keeps
        // the test instant) — the second 429 must surface as .rateLimited.
        ChatAdapterStubURLProtocol.reset([
            .response(status: 429, headers: ["Retry-After": "0"],
                      body: Data(#"{"type":"error","error":{"type":"rate_limit_error"}}"#.utf8)),
            .response(status: 429, headers: ["Retry-After": "0"],
                      body: Data(#"{"type":"error","error":{"type":"rate_limit_error"}}"#.utf8)),
        ])
        await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .rateLimited = $0 { return true }; return false }, ".rateLimited")
        XCTAssertEqual(ChatAdapterStubURLProtocol.hits, 2, "a plain 429 keeps its single retry")
    }

    func testAnthropicServerErrorAndMalformedBody() async {
        stub(529, #"{"type":"error","error":{"type":"overloaded_error"}}"#)
        await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") }, {
            if case .server(let status) = $0 { return status == 529 }
            return false
        }, ".server(529)")

        stub(200, "not json at all")
        await expectError({ try await self.makeAnthropic().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .decodeFailure = $0 { return true }; return false }, ".decodeFailure")
    }

    // MARK: - Gemini

    func testGeminiWellFormedResponseSkipsThoughtsAndFoldsThoughtTokens() async throws {
        stub(200, """
        {"candidates":[{"content":{"parts":[{"text":"internal plan","thought":true},{"text":"Refined prompt"}]},
                        "finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":30,"candidatesTokenCount":9,"thoughtsTokenCount":4},
         "modelVersion":"gemini-3.5-flash-001"}
        """)
        let result = try await makeGemini().generatePrompt(timeline: timeline, systemPrompt: "sys")
        XCTAssertEqual(result.prompt, "Refined prompt", "thought parts are filtered out of the returned text")
        XCTAssertEqual(result.usage.inputTokens, 30)
        XCTAssertEqual(result.usage.outputTokens, 13, "thoughts bill as output — 9 + 4 folded")
        XCTAssertEqual(result.usage.model, "gemini-3.5-flash-001")
    }

    func testGeminiRequestCarriesKeyHeaderModelPathAndCap() async throws {
        stub(200, """
        {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}
        """)
        _ = try await makeGemini().generatePrompt(timeline: timeline, systemPrompt: "sys")

        let request = try XCTUnwrap(ChatAdapterStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-3.5-flash:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test-key")
        XCTAssertFalse(request.url?.absoluteString.contains("AIza-test-key") ?? true,
                       "the key must ride the header, never the URL (it would log)")

        let body = try lastBodyJSON()
        let config = try XCTUnwrap(body["generationConfig"] as? NSDictionary)
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 16384, "B-04 cap rides the actual HTTP body")
    }

    func testGeminiMaxTokensFinishThrowsTruncated() async {
        stub(200, """
        {"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}
        """)
        await expectError({ try await self.makeGemini().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .truncated = $0 { return true }; return false }, ".truncated")
    }

    func testGeminiPromptBlockAndSafetyFinishThrowEmptyContent() async {
        for body in [
            // Prompt-level safety block: no candidates at all.
            #"{"promptFeedback":{"blockReason":"SAFETY"}}"#,
            // Candidate-level non-STOP finish, even with text present.
            #"{"candidates":[{"content":{"parts":[{"text":"cut"}]},"finishReason":"SAFETY"}]}"#,
            // Thought-only parts: nothing usable after filtering.
            #"{"candidates":[{"content":{"parts":[{"text":"plan","thought":true}]},"finishReason":"STOP"}]}"#,
            // No candidates.
            #"{"candidates":[]}"#,
        ] {
            stub(200, body)
            await expectError({ try await self.makeGemini().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                              { if case .emptyContent = $0 { return true }; return false }, ".emptyContent for \(body)")
        }
    }

    func testGeminiAuthStatusesMapToAuth() async {
        for status in [401, 403] {
            stub(status, #"{"error":{"code":403,"message":"API key not valid","status":"PERMISSION_DENIED"}}"#)
            await expectError({ try await self.makeGemini().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                              { if case .auth = $0 { return true }; return false }, ".auth for \(status)")
        }
    }

    func testGemini429MapsToRateLimited() async {
        // Gemini's numeric error.code must not trip the (OpenAI-only) quota
        // detection — the 429 keeps its retry and surfaces as .rateLimited.
        let body = Data(#"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
        ChatAdapterStubURLProtocol.reset([
            .response(status: 429, headers: ["Retry-After": "0"], body: body),
            .response(status: 429, headers: ["Retry-After": "0"], body: body),
        ])
        await expectError({ try await self.makeGemini().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .rateLimited = $0 { return true }; return false }, ".rateLimited")
        XCTAssertEqual(ChatAdapterStubURLProtocol.hits, 2)
    }

    func testGeminiServerErrorAndMalformedBody() async {
        stub(503, #"{"error":{"code":503,"status":"UNAVAILABLE"}}"#)
        await expectError({ try await self.makeGemini().generatePrompt(timeline: self.timeline, systemPrompt: "sys") }, {
            if case .server(let status) = $0 { return status == 503 }
            return false
        }, ".server(503)")

        stub(200, "{truncated jso")
        await expectError({ try await self.makeGemini().generatePrompt(timeline: self.timeline, systemPrompt: "sys") },
                          { if case .decodeFailure = $0 { return true }; return false }, ".decodeFailure")
    }
}
