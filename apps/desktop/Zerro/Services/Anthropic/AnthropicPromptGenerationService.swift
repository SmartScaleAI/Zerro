//
//  AnthropicPromptGenerationService.swift
//  Zerro
//
//  Phase 6 (multi-model 6C) — PromptGenerationService impl backed by the
//  Anthropic Messages API, for BYOK users running a Claude chat model on
//  their own key. Transcription is NOT handled here — it runs separately,
//  either on-device (whisper.cpp, no key) or on OpenAI cloud, so a Claude-only
//  user can transcribe with the on-device model and never needs an OpenAI key.
//
//  Wire format ported from the original server-side adapter (since removed
//  from the repository; verified against the Messages API 2026-06-10) and
//  the Phase 0 eval harness (Scripts/eval-models.mjs). KEEP IN SYNC with the
//  harness if either changes:
//    POST https://api.anthropic.com/v1/messages
//    Headers:  x-api-key: <key>   (NOT Authorization)
//              anthropic-version: 2023-06-01
//    Body: {
//      "model": "claude-opus-4-7",
//      "max_tokens": 16384,                 // REQUIRED by the Messages API
//      "system": "<composed system prompt>",// top-level, never a message
//      "messages": [{"role": "user", "content": [
//        {"type": "text", "text": "\n[0:00] "},
//        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "<base64>"}},
//        ...
//      ]}]
//    }
//    NO sampling params, NO `thinking` field (Opus 4.7 400s on temperature/
//    top_p/top_k; absent thinking = off — the eval-gated shape).
//  Response: content[] (join type=="text" blocks), stop_reason ("refusal" →
//    empty-content class; "max_tokens" → truncated class), usage
//    {input_tokens, output_tokens}, model.
//
//  The interleaved text/image rendering (timestamp tags, OCR lines, click
//  lines) is byte-identical to the OpenAI impl, the Managed interleave.ts,
//  and the eval harness — KEEP IN SYNC if you touch the format.
//

import Foundation
import os

struct AnthropicPromptGenerationService: PromptGenerationService {

    private nonisolated static let base = URL(string: "https://api.anthropic.com/v1")!
    private nonisolated static let apiVersion = "2023-06-01"
    /// Required by the Messages API. Generous headroom over the ~966-token
    /// typical so a long recording's longer response doesn't get cut off (the
    /// old 8192 ceiling truncated ~2-minute recordings — handoff-artifact-fence
    /// -leak). A response that still hits this limit is detected via
    /// `stop_reason == "max_tokens"` and surfaced as `.truncated`, never handed
    /// to the parser half-formed. KEEP IN SYNC with the server adapter's
    /// ANTHROPIC_MAX_TOKENS.
    private nonisolated static let maxTokens = 16384

    /// The registry model id to run (e.g. "claude-sonnet-4-6"). Selected per
    /// generation by BYOKRouting.
    let model: String

    /// J-06 test seams — behavior-identical defaults at every production call
    /// site (`nil ??` falls through to the live Keychain read; the shared
    /// session is what `performWithRetry` used unconditionally before). The
    /// adapter tests inject a fixed key + a URLProtocol-stubbed session so the
    /// full `generatePrompt` flow — status mapping, parsing, truncation — runs
    /// without Keychain or network.
    var apiKeyOverride: String?
    var session: URLSession = OpenAIClient.session

    func generatePrompt(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) async throws -> PromptGenerationResult {
        guard let apiKey = apiKeyOverride ?? ProviderKeys.resolveKey(for: .anthropic) else {
            throw PromptGenerationError.missingAPIKey
        }

        let model = self.model
        let bodyData = try await Task.detached(priority: .userInitiated) {
            try Self.encodeBody(timeline: timeline, systemPrompt: systemPrompt, model: model)
        }.value

        var request = URLRequest(url: Self.base.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        let data: Data
        let response: HTTPURLResponse
        do {
            // Generic URLSession + single-retry-on-429 plumbing (despite the
            // OpenAIClient namespace, nothing in it is OpenAI-specific).
            (data, response) = try await OpenAIClient.performWithRetry(request, session: session)
        } catch {
            throw PromptGenerationError.network(underlying: error)
        }

        switch response.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw PromptGenerationError.auth
        case 429:
            // J-03: Anthropic's 429 is always rate-limiting (`rate_limit_error`).
            // Credit/quota exhaustion arrives as a 400 `invalid_request_error`
            // distinguished only by message TEXT ("credit balance is too low"),
            // which is too brittle to match — so quota stays undetected here
            // and falls into the generic 400 → `.server` branch below.
            throw PromptGenerationError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Log.promptGen.error("Anthropic messages non-2xx \(response.statusCode, privacy: .public): \(body, privacy: .private)")
            throw PromptGenerationError.server(status: response.statusCode)
        }

        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw PromptGenerationError.decodeFailure(underlying: error)
        }

        // The generation was cut off at the output-token limit — the partial
        // text can carry an unterminated `<<<ZERRO_ARTIFACT` fence, so it must
        // NOT reach the parser as a clean success (handoff-artifact-fence-leak).
        // Checked before the empty-content guard because a truncated response
        // usually DOES have (partial) text.
        if decoded.stopReason == "max_tokens" {
            throw PromptGenerationError.truncated
        }

        // A safety refusal is stop_reason "refusal", usually with no text —
        // the model's choice, not an outage → emptyContent (server parity).
        let text = (decoded.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard decoded.stopReason != "refusal", !text.isEmpty else {
            throw PromptGenerationError.emptyContent
        }

        return PromptGenerationResult(
            prompt: text,
            usage: TokenUsage(
                inputTokens: decoded.usage?.inputTokens ?? 0,
                outputTokens: decoded.usage?.outputTokens ?? 0,
                model: decoded.model ?? model
            )
        )
    }

    // MARK: - Body encoding

    /// Builds the Messages API body from the timeline. Rendering rules are
    /// byte-identical to the OpenAI impl (one "\n[tag] " text block per
    /// frame, the image block, an optional OCR text block, speech/click
    /// lines). `model` is a parameter so the nonisolated static can run in a
    /// detached task without touching instance state.
    nonisolated static func encodeBody(
        timeline: InterleavedTimeline,
        systemPrompt: String,
        model: String
    ) throws -> Data {
        var content: [ContentBlock] = []
        for item in timeline.items {
            switch item {
            case .frame(_, let imageURL, let ocrText):
                let base64: String
                do {
                    base64 = try Data(contentsOf: imageURL).base64EncodedString()
                } catch {
                    throw PromptGenerationError.network(underlying: error)
                }
                content.append(.text("\n\(item.timestampTag) "))
                content.append(.image(mediaType: "image/jpeg", base64: base64))
                if let ocr = ocrText, !ocr.isEmpty {
                    content.append(.text("\n\(item.timestampTag) on-screen text: \(ocr)"))
                }
            case .speech(_, _, let text):
                content.append(.text("\n\(item.timestampTag) \"\(text)\""))
            case .click(_, let label):
                content.append(.text("\n\(item.timestampTag) clicked \"\(label)\""))
            case .rawText(let text):
                // Verbatim single text block — no tag, no quoting.
                content.append(.text(text))
            }
        }

        let body = MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: [MessageBody(role: "user", content: content)]
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw PromptGenerationError.decodeFailure(underlying: error)
        }
    }

    // MARK: - Key validation (Settings pill)

    /// Cheapest authenticated probe: GET /models with the key headers. Same
    /// semantics as OpenAIClient.validateKey.
    static func validateKey(_ apiKey: String) async -> OpenAIClient.KeyValidationResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }

        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        do {
            let (_, raw) = try await OpenAIClient.session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200...299: return .valid
            case 401, 403: return .invalidKey
            default: return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    // MARK: - Wire types — request

    private nonisolated struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [MessageBody]

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private nonisolated struct MessageBody: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    private nonisolated enum ContentBlock: Encodable {
        case text(String)
        case image(mediaType: String, base64: String)

        private enum CodingKeys: String, CodingKey {
            case type, text, source
        }

        private enum SourceKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .text)
            case .image(let mediaType, let base64):
                try container.encode("image", forKey: .type)
                var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(mediaType, forKey: .mediaType)
                try source.encode(base64, forKey: .data)
            }
        }
    }

    // MARK: - Wire types — response

    private struct MessagesResponse: Decodable {
        let content: [ResponseBlock]?
        let stopReason: String?
        let usage: Usage?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case content, usage, model
            case stopReason = "stop_reason"
        }

        struct ResponseBlock: Decodable {
            let type: String?
            let text: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }
}
