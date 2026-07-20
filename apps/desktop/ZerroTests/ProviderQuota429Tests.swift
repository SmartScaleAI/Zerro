//
//  ProviderQuota429Tests.swift
//  ZerroTests
//
//  J-03 — a provider QUOTA 429 (OpenAI `insufficient_quota`) is not a burst,
//  so it must not burn `performWithRetry`'s single retry (the second request
//  fails identically and only delays the pill), and it must map to the
//  dedicated `.quotaExhausted` / `.providerQuotaExhausted` shape instead of
//  the transient rate-limit copy. Pins:
//    - performWithRetry: quota 429 → exactly ONE request; plain rate-limit
//      429 → the single retry still happens.
//    - status mapping: 429 + quota body → .quotaExhausted for BOTH OpenAI
//      adapters; 429 + rate-limit/empty body → .rateLimited (unchanged).
//    - detection stays OpenAI-only: Anthropic/Gemini-shaped bodies (which
//      flow through the same shared plumbing) never match.
//    - the new failure reason is non-retryable and gated out of
//      error-tracker capture, like the other user-fixable reasons.
//

import XCTest
@testable import Zerro

// MARK: - URLProtocol stub

/// Serves queued (status, headers, body) responses in order and counts every
/// request that reaches the "network", so the retry behavior is asserted by
/// hit count. State is static (URLProtocol instantiates per request) and
/// lock-guarded; the suite runs serially so tests don't interleave.
private nonisolated final class Quota429StubURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Stub] = []
    nonisolated(unsafe) private static var requestCount = 0

    static func reset(stubs: [Stub]) {
        lock.withLock {
            queue = stubs
            requestCount = 0
        }
    }

    static var hits: Int { lock.withLock { requestCount } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub = Self.lock.withLock {
            Self.requestCount += 1
            return Self.queue.isEmpty
                ? Stub(status: 200, headers: [:], body: Data("{}".utf8))
                : Self.queue.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.openai.com/v1")!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class ProviderQuota429Tests: XCTestCase {

    /// OpenAI's quota/billing-exhausted 429 body (both `type` and `code` are
    /// `insufficient_quota` on the live API; either alone should match).
    private static let quotaBody = Data("""
    {"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}
    """.utf8)

    /// OpenAI's transient rate-limit 429 body — must keep the retry + the
    /// `.rateLimited` mapping.
    private static let rateLimitBody = Data("""
    {"error":{"message":"Rate limit reached for gpt-4o in organization org-x on tokens per min.","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"}}
    """.utf8)

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Quota429StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func someRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    }

    // MARK: performWithRetry — retry behavior

    func testQuota429IsReturnedWithoutRetry() async throws {
        Quota429StubURLProtocol.reset(stubs: [
            .init(status: 429, headers: ["Retry-After": "0"], body: Self.quotaBody),
            // Would succeed if the retry (wrongly) fired — the hit count
            // and returned status prove it never does.
            .init(status: 200, headers: [:], body: Data("{}".utf8))
        ])

        let (data, response) = try await OpenAIClient.performWithRetry(
            someRequest(), session: stubbedSession()
        )

        XCTAssertEqual(Quota429StubURLProtocol.hits, 1, "a quota 429 must not burn the retry")
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(data, Self.quotaBody, "the first response rides back to the caller for mapping")
    }

    func testPlainRateLimit429StillRetriesOnce() async throws {
        Quota429StubURLProtocol.reset(stubs: [
            .init(status: 429, headers: ["Retry-After": "0"], body: Self.rateLimitBody),
            .init(status: 200, headers: [:], body: Data("{}".utf8))
        ])

        let (_, response) = try await OpenAIClient.performWithRetry(
            someRequest(), session: stubbedSession()
        )

        XCTAssertEqual(Quota429StubURLProtocol.hits, 2, "a genuine rate-limit 429 keeps its single retry")
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: Status mapping — both OpenAI adapters

    func testQuota429MapsToQuotaExhaustedForBothOpenAIAdapters() throws {
        let pgError = try XCTUnwrap(OpenAIPromptGenerationService.error(forStatus: 429, body: Self.quotaBody))
        guard case .quotaExhausted = pgError else {
            return XCTFail("prompt generation must map a quota 429 to .quotaExhausted, got \(pgError)")
        }
        let txError = try XCTUnwrap(OpenAITranscriptionService.error(forStatus: 429, body: Self.quotaBody))
        guard case .quotaExhausted = txError else {
            return XCTFail("transcription must map a quota 429 to .quotaExhausted, got \(txError)")
        }
    }

    func testRateLimit429StillMapsToRateLimited() throws {
        for body in [Self.rateLimitBody, Data()] {
            let pgError = try XCTUnwrap(OpenAIPromptGenerationService.error(forStatus: 429, body: body))
            guard case .rateLimited = pgError else {
                return XCTFail("a non-quota 429 must stay .rateLimited, got \(pgError)")
            }
            let txError = try XCTUnwrap(OpenAITranscriptionService.error(forStatus: 429, body: body))
            guard case .rateLimited = txError else {
                return XCTFail("a non-quota 429 must stay .rateLimited, got \(txError)")
            }
        }
    }

    // MARK: Detection stays OpenAI-only

    func testDetectionIgnoresOtherProvidersAndJunk() {
        // Gemini's RESOURCE_EXHAUSTED envelope: numeric `code` must decode
        // leniently (not crash the envelope) and must not match.
        let gemini = Data("""
        {"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}
        """.utf8)
        XCTAssertFalse(OpenAIClient.isQuotaExhausted429(status: 429, body: gemini))

        // Anthropic's 429 is always rate_limit_error — never quota.
        let anthropic = Data("""
        {"type":"error","error":{"type":"rate_limit_error","message":"Number of requests has exceeded your rate limit."}}
        """.utf8)
        XCTAssertFalse(OpenAIClient.isQuotaExhausted429(status: 429, body: anthropic))

        // Non-JSON body and a quota body on a non-429 status: both false.
        XCTAssertFalse(OpenAIClient.isQuotaExhausted429(status: 429, body: Data("<html>429</html>".utf8)))
        XCTAssertFalse(OpenAIClient.isQuotaExhausted429(status: 200, body: Self.quotaBody))
    }

    // MARK: Failure-reason posture

    func testProviderQuotaExhaustedIsNonRetryableAndNotCaptured() {
        XCTAssertFalse(
            RecordingFailureReason.providerQuotaExhausted.isRetryable,
            "quota won't recover in seconds — Retry would be a trap"
        )
        XCTAssertFalse(
            AppState.shouldCapture(.providerQuotaExhausted),
            "user-fixable provider billing, not a Zerro bug — keep it out of the error tracker"
        )
        XCTAssertNil(
            RecordingFailureReason.providerQuotaExhausted.settingsDeepLink,
            "the fix is on the provider's billing page, not in Zerro's Settings"
        )
    }

    func testProviderQuotaExhaustedCopyIsDistinctFromRateLimited() {
        let quota = RecordingFailureReason.providerQuotaExhausted
        XCTAssertNotEqual(quota.userMessage, RecordingFailureReason.rateLimited.userMessage)
        XCTAssertNotEqual(quota.headline, RecordingFailureReason.rateLimited.headline)
        XCTAssertTrue(
            quota.userMessage.contains("quota"),
            "the copy must name the quota/billing cause, not a transient outage"
        )
    }
}
