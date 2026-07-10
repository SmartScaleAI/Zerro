//
//  OpenAIClient.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Shared OpenAI-specific plumbing: API key resolution (Keychain at
//  request time, not at app launch — so Settings changes apply on
//  the next recording without a restart), the URLSession config, the
//  single-retry-on-429 wrapper, the multipart/form-data builder used
//  by the Whisper upload, and the typed mapping from HTTP status →
//  the right error case for each service.
//
//  The key is intentionally NEVER logged, NEVER echoed in error
//  messages, NEVER held statically. Read per-request, used once, dropped.
//

import Foundation

enum OpenAIClient {

    // MARK: - Constants

    /// Base URL for all OpenAI API requests in this app. Pinned so
    /// future moves to a regional endpoint / proxy are a one-line change.
    static let baseURL = URL(string: "https://api.openai.com/v1")!

    /// Default request timeout in seconds. 60s covers Whisper for the
    /// 3-minute audio cap; multimodal requests can take longer and may
    /// need a per-request override later (deferred until we see real
    /// p95 latency in production).
    static let defaultTimeout: TimeInterval = 60

    // MARK: - URLSession

    /// Shared session for all OpenAI calls. Default config is correct
    /// (we don't need caching for API requests). Pulled out so tests
    /// can swap to URLProtocol mock later.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = defaultTimeout
        config.timeoutIntervalForResource = defaultTimeout * 2
        config.urlCache = nil
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    // MARK: - API key

    /// Reads the OpenAI API key from Keychain. Returns nil if the user
    /// hasn't set one in Settings. Callers should map nil to their
    /// `missingAPIKey` error case rather than fabricating one.
    static func resolveAPIKey() -> String? {
        guard let key = KeychainStore.openAIAPIKey.read() else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Request building

    /// Stamps the Bearer auth header onto `request` using an
    /// already-resolved key. Mutating in place keeps multipart-body
    /// callers from rebuilding the entire request. Key resolution and the
    /// nil → `missingAPIKey` mapping happen earlier at the call site via
    /// `resolveAPIKey()`, so by here the key is known non-empty.
    static func authenticate(_ request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Single-retry-on-429

    /// Performs `request` via `session`, with one retry on
    /// HTTP 429. Respects `Retry-After` (in seconds) if present,
    /// falls back to a 2-second wait. Returns the response on success
    /// AND on non-429 errors — interpretation (auth vs server vs
    /// network) is the caller's job, since each service maps error
    /// cases differently.
    ///
    /// Why one retry and not exponential backoff: per Phase 9 plan,
    /// recordings are user-initiated and infrequent. A single retry
    /// handles the rare burst case; persistent rate-limiting deserves
    /// a user-visible message (not a hidden backoff that makes the
    /// pill appear stuck).
    ///
    /// J-03: a QUOTA-exhausted 429 (OpenAI `insufficient_quota`) is returned
    /// immediately, without the sleep + retry — it's a billing state, not a
    /// burst, so the retry can't succeed and would only delay the pill.
    ///
    /// `session` is injectable so tests can count requests through a
    /// URLProtocol stub; production call sites use the shared default.
    static func performWithRetry(
        _ request: URLRequest,
        session: URLSession = OpenAIClient.session
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            // URLSession should always return HTTPURLResponse for HTTP
            // schemes — if it doesn't, something is deeply wrong with
            // the request. Treat as network-class failure.
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 429 {
            return (data, httpResponse)
        }
        if isQuotaExhausted429(status: httpResponse.statusCode, body: data) {
            return (data, httpResponse)
        }

        let retryAfter = retryAfterSeconds(httpResponse) ?? 2.0
        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))

        let (retryData, retryResponse) = try await session.data(for: request)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (retryData, retryHTTP)
    }

    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        return TimeInterval(raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Quota-exhausted 429 (J-03)

    /// True iff a 429 response body is OpenAI's QUOTA/billing-exhausted error
    /// — `error.code`/`error.type` == "insufficient_quota" — as opposed to a
    /// transient rate-limit 429. Quota exhaustion won't clear in seconds, so
    /// `performWithRetry` skips its retry and the services map it to the
    /// dedicated `.quotaExhausted` error instead of the transient copy.
    ///
    /// OpenAI is the only provider detected here. Anthropic surfaces credit
    /// exhaustion as a 400 `invalid_request_error` distinguished only by
    /// message text, and Gemini folds daily-quota AND per-minute rate limits
    /// into one 429 RESOURCE_EXHAUSTED shape — neither is a stable signal,
    /// so both stay on the plain rate-limit path (their bodies simply never
    /// match this check).
    static func isQuotaExhausted429(status: Int, body: Data) -> Bool {
        guard status == 429 else { return false }
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
              let payload = envelope.error else {
            return false
        }
        return payload.code == "insufficient_quota" || payload.type == "insufficient_quota"
    }

    /// The provider error envelope: `{"error": {"code": ..., "type": ...}}`.
    /// Decoded leniently — Gemini sends a NUMERIC `code` through the same
    /// shared plumbing, so a non-string field decodes to nil rather than
    /// failing the whole envelope.
    private struct ErrorEnvelope: Decodable {
        let error: Payload?

        struct Payload: Decodable {
            let code: String?
            let type: String?

            private enum CodingKeys: String, CodingKey { case code, type }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil
                self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
            }
        }
    }

    // MARK: - Key validation
    //
    // Phase 11: lightweight validator used by Settings (revalidate on
    // change) and by onboarding's API key step (replacing the old prefix-
    // only sanity check). Hits GET /v1/models because it's the cheapest
    // authenticated endpoint OpenAI exposes — a 200 means the key works,
    // a 401 means it doesn't, anything else is "couldn't tell" and is
    // intentionally NOT surfaced as invalid (we don't want a transient
    // hiccup to nuke a working key in the UI).

    enum KeyValidationResult: Equatable {
        case valid
        case invalidKey
        /// Validation couldn't complete because of a network/server hiccup.
        /// The UI keeps the previous valid/invalid disposition rather than
        /// punishing the user for a transient issue.
        case inconclusive
    }

    /// Validates `apiKey` against OpenAI by issuing a cheap authenticated
    /// GET. Trims whitespace; an empty key returns `.invalidKey` without
    /// hitting the network. Throws nothing — the result enum already
    /// carries every outcome the caller cares about.
    static func validateKey(_ apiKey: String) async -> KeyValidationResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        authenticate(&request, apiKey: trimmed)

        let response: HTTPURLResponse
        do {
            let (_, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { return .inconclusive }
            response = http
        } catch {
            return .inconclusive
        }

        switch response.statusCode {
        case 200...299:
            return .valid
        case 401, 403:
            return .invalidKey
        default:
            return .inconclusive
        }
    }

    // MARK: - Multipart/form-data

    /// Builds a `multipart/form-data` body from an array of text +
    /// binary parts. The companion `MultipartBuilder.contentType` is
    /// what the caller sets as the request's `Content-Type` header.
    ///
    /// Why this lives here and not in a generic utilities file: the
    /// Whisper upload is the only multipart user in the app. Adding
    /// a generic library would be premature.
    struct MultipartBuilder {
        let boundary: String

        init() {
            // Random boundary per builder so concurrent uploads don't
            // accidentally share one. UUID is 32 hex chars — plenty
            // to make collision-with-actual-payload-bytes a non-issue.
            self.boundary = "vf-boundary-\(UUID().uuidString)"
        }

        var contentType: String { "multipart/form-data; boundary=\(boundary)" }

        /// Builds the body bytes from the supplied parts in order.
        /// Order matters for some endpoints (OpenAI is forgiving here
        /// but other providers aren't) — caller controls it.
        func build(parts: [Part]) -> Data {
            var body = Data()
            for part in parts {
                body.append("--\(boundary)\r\n")
                switch part {
                case .text(let name, let value):
                    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                    body.append("\(value)\r\n")
                case .file(let name, let filename, let mimeType, let data):
                    body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                    body.append("Content-Type: \(mimeType)\r\n\r\n")
                    body.append(data)
                    body.append("\r\n")
                }
            }
            body.append("--\(boundary)--\r\n")
            return body
        }

        enum Part {
            case text(name: String, value: String)
            case file(name: String, filename: String, mimeType: String, data: Data)
        }
    }
}

// MARK: - Data convenience

/// Internal helper so the multipart builder reads cleanly. UTF-8 is
/// safe for every header/value we emit (ASCII-only field names + UTF-8
/// values). File and boundary appends pass `Data` directly.
private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
