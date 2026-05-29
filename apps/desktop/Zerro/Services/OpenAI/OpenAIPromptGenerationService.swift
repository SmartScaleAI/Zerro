//
//  OpenAIPromptGenerationService.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  PromptGenerationService impl backed by GPT-4o multimodal via the
//  OpenAI Chat Completions endpoint. Pinned to `gpt-4o` for v1 —
//  85 image tokens at detail:"low" (vs 2833 for gpt-4o-mini, which is
//  counter-intuitively more expensive for image-heavy payloads).
//
//  Request shape (verified against live OpenAI docs at 2026-05-28):
//    POST https://api.openai.com/v1/chat/completions
//    Headers:  Authorization: Bearer <key>
//              Content-Type:  application/json
//    Body:     {
//      "model": "gpt-4o",
//      "messages": [
//        {"role": "system", "content": "<locked PromptGenerationSystemPrompt>"},
//        {"role": "user", "content": [
//          {"type": "text", "text": "\n[0:00] "},
//          {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,...", "detail": "low"}},
//          {"type": "text", "text": "\n[0:00\u{2013}0:08] \"okay so this is...\""},
//          ...
//        ]}
//      ]
//    }
//  Response:
//    {choices: [{message: {content: "..."}, ...}], usage: {prompt_tokens, completion_tokens, total_tokens}, model: "..."}
//
//  Image content: each frame's local JPEG is read + base64-encoded at
//  request-build time, wrapped in a `data:image/jpeg;base64,…` URL,
//  and sent at `detail: "high"`. Phase 8 downsamples frames to ≤1024px
//  longest edge, which "high" can fully exploit (model tiles the
//  image into ~512px chunks and reads each). Costs ~4× the per-image
//  token count vs "low" (340 vs 85 for gpt-4o), but for typical
//  3-minute recordings keeps total cost well under the $0.07/request
//  cap and produces concrete visual descriptions instead of paraphrased
//  narration. Step 3 verification showed "low" couldn't read fine
//  on-screen detail (logo geometry, small text); revisit if cost data
//  from real usage shows headroom is gone.
//

import Foundation

struct OpenAIPromptGenerationService: PromptGenerationService {

    /// GPT-4o model id. Pinned here so a future swap to a date-stamped
    /// variant (e.g. `gpt-4o-2024-08-06`) or a newer model is a
    /// single-line change with a before/after token-cost diff to back
    /// the decision.
    static let model = "gpt-4o"

    func generatePrompt(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) async throws -> PromptGenerationResult {
        guard let apiKey = OpenAIClient.resolveAPIKey() else {
            throw PromptGenerationError.missingAPIKey
        }

        // Build the multimodal user content array. One text block per
        // timeline item + one image_url block per frame; the model
        // concatenates adjacent text blocks transparently. Newlines
        // are prefixed so each tag/segment lands on its own line in
        // the rendered prompt — matches the kickoff's interleaving
        // example exactly.
        var userContent: [UserContentBlock] = []
        for item in timeline.items {
            switch item {
            case .frame(_, let imageURL):
                let dataURL: String
                do {
                    dataURL = try Self.base64DataURL(from: imageURL)
                } catch {
                    // Frame failed to read from disk — treat as a
                    // network-class failure rather than emptyContent
                    // (the cause is local I/O, not the model).
                    throw PromptGenerationError.network(underlying: error)
                }
                userContent.append(.text("\n\(item.timestampTag) "))
                userContent.append(.imageURL(url: dataURL, detail: "high"))

            case .speech(_, _, let text):
                userContent.append(.text("\n\(item.timestampTag) \"\(text)\""))
            }
        }

        let requestBody = ChatRequest(
            model: Self.model,
            messages: [
                .systemMessage(content: systemPrompt),
                .userMessage(content: userContent)
            ]
        )

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(requestBody)
        } catch {
            // Encoding our own request body should never fail; if it
            // does, it's a programming error, not a runtime one.
            throw PromptGenerationError.decodeFailure(underlying: error)
        }

        var request = URLRequest(url: OpenAIClient.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OpenAIClient.authenticate(&request, apiKey: apiKey)
        request.httpBody = bodyData

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await OpenAIClient.performWithRetry(request)
        } catch {
            throw PromptGenerationError.network(underlying: error)
        }

        switch response.statusCode {
        case 200...299:
            break
        case 401:
            throw PromptGenerationError.auth
        case 429:
            throw PromptGenerationError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8)
            throw PromptGenerationError.server(status: response.statusCode, body: body)
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw PromptGenerationError.decodeFailure(underlying: error)
        }

        guard let content = decoded.choices.first?.message.content,
              !content.isEmpty else {
            throw PromptGenerationError.emptyContent
        }

        return PromptGenerationResult(
            prompt: content,
            usage: TokenUsage(
                inputTokens: decoded.usage?.promptTokens ?? 0,
                outputTokens: decoded.usage?.completionTokens ?? 0,
                model: decoded.model ?? Self.model
            )
        )
    }

    // MARK: - Image encoding

    /// Reads the JPEG at `url` and wraps its base64 in a data URL.
    /// The 33% base64 overhead is added at request-build time and
    /// dropped after the request — never held on the in-memory
    /// timeline.
    private static func base64DataURL(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    // MARK: - Wire types — request

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
    }

    private enum Message: Encodable {
        case systemMessage(content: String)
        case userMessage(content: [UserContentBlock])

        private enum CodingKeys: String, CodingKey {
            case role, content
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .systemMessage(let content):
                try container.encode("system", forKey: .role)
                try container.encode(content, forKey: .content)
            case .userMessage(let blocks):
                try container.encode("user", forKey: .role)
                try container.encode(blocks, forKey: .content)
            }
        }
    }

    // MARK: - Cost estimate

    /// gpt-4o list price as of 2026-05-28 (USD per 1M tokens). Update
    /// when OpenAI changes pricing. Used by AppState's per-session
    /// cost log; not consumed elsewhere. If we date-stamp the model id
    /// later (gpt-4o-2024-08-06 etc.), pricing varies per snapshot —
    /// the response carries the exact model used so the log line is
    /// always honest about which alias was billed.
    private static let inputPricePerMillion: Double = 2.50
    private static let outputPricePerMillion: Double = 10.00

    /// Returns the estimated USD cost for a single completion given
    /// the reported token usage. Input + output priced separately.
    static func estimatedCost(usage: TokenUsage) -> Double {
        let inputCost = Double(usage.inputTokens) / 1_000_000 * inputPricePerMillion
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPricePerMillion
        return inputCost + outputCost
    }

    // MARK: - Wire types — response

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        let usage: Usage?
        let model: String?

        struct Choice: Decodable {
            let message: ChoiceMessage
        }

        struct ChoiceMessage: Decodable {
            let content: String?
        }

        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
    }
}

// MARK: - UserContentBlock
//
// Polymorphic content block — the `content` field on a user message is
// an array mixing text and image_url entries. Custom Encodable emits
// the right JSON shape for each variant. Kept outside the impl struct
// so the same type can be reused by future provider impls (Anthropic's
// content shape is similar enough that this maps cleanly).

enum UserContentBlock: Encodable {
    case text(String)
    case imageURL(url: String, detail: String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private enum ImageURLKeys: String, CodingKey {
        case url, detail
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageURL(let url, let detail):
            try container.encode("image_url", forKey: .type)
            var imageContainer = container.nestedContainer(
                keyedBy: ImageURLKeys.self, forKey: .imageURL
            )
            try imageContainer.encode(url, forKey: .url)
            try imageContainer.encode(detail, forKey: .detail)
        }
    }
}
