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
import os

struct OpenAIPromptGenerationService: PromptGenerationService {

    /// GPT-4o model id. Pinned here so a future swap to a date-stamped
    /// variant (e.g. `gpt-4o-2024-08-06`) or a newer model is a
    /// single-line change with a before/after token-cost diff to back
    /// the decision. `nonisolated` so `encodeBody` can read it off the
    /// main actor.
    nonisolated static let model = "gpt-4o"

    func generatePrompt(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) async throws -> PromptGenerationResult {
        guard let apiKey = OpenAIClient.resolveAPIKey() else {
            throw PromptGenerationError.missingAPIKey
        }

        // Build + JSON-encode the multimodal request body OFF the main
        // actor. The per-frame disk read + base64 and the full-body
        // encode (with all image data inlined) run uninterrupted before
        // the first network await — for a typical 3-minute recording
        // that's ~150 file reads plus tens of MB of base64/JSON, a
        // multi-hundred-ms hitch if left on main. `encodeBody` is
        // `nonisolated`, so the detached task genuinely stays off-main.
        // The base64 body is dropped after the request — never held on
        // the in-memory timeline.
        let bodyData = try await Task.detached(priority: .userInitiated) {
            try Self.encodeBody(timeline: timeline, systemPrompt: systemPrompt)
        }.value

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
            // Log the provider's error body `.private` for local debugging
            // only — it must NOT ride into the typed error, which can reach
            // Sentry where the exception value is scrubbed by length, not by
            // content. The error keeps just the status code.
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Log.promptGen.error("Chat Completions non-2xx \(response.statusCode, privacy: .public): \(body, privacy: .private)")
            throw PromptGenerationError.server(status: response.statusCode)
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

    // MARK: - Body encoding

    /// Builds the Chat Completions request body — one text block per
    /// timeline item plus one image_url block per frame — and JSON-encodes
    /// the whole thing with each frame's base64 inlined. The model
    /// concatenates adjacent text blocks transparently; newlines are
    /// prefixed so each tag/segment lands on its own line in the rendered
    /// prompt, matching the kickoff's interleaving example exactly.
    ///
    /// Each frame's JPEG is read off disk and base64-encoded here, at
    /// request-build time — the 33% overhead is dropped after the request,
    /// never held on the in-memory timeline (mirrors the Managed path's
    /// `ManagedProxyClient.encodeBody` discipline). `nonisolated` so it
    /// runs in a detached task off the main actor: under the project's
    /// MainActor-default isolation an unmarked static on this struct would
    /// be implicitly main-isolated and bounce the work right back to main.
    nonisolated static func encodeBody(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) throws -> Data {
        var userContent: [UserContentBlock] = []
        for item in timeline.items {
            switch item {
            case .frame(_, let imageURL, let ocrText):
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
                // Phase 3: the frame's redacted on-screen text rides right AFTER
                // its image block, only when OCR found something. Byte-identical
                // to the Managed (interleave.ts) and eval (eval-models.mjs)
                // renderings — KEEP IN SYNC if you touch this format.
                if let ocr = ocrText, !ocr.isEmpty {
                    userContent.append(.text("\n\(item.timestampTag) on-screen text: \(ocr)"))
                }

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

        do {
            return try JSONEncoder().encode(requestBody)
        } catch {
            // Encoding our own request body should never fail; if it
            // does, it's a programming error, not a runtime one.
            throw PromptGenerationError.decodeFailure(underlying: error)
        }
    }

    // MARK: - Image encoding

    /// Reads the JPEG at `url` and wraps its base64 in a data URL.
    /// The 33% base64 overhead is added at request-build time and
    /// dropped after the request — never held on the in-memory
    /// timeline. `nonisolated` so it stays off-main when called from
    /// `encodeBody`'s detached task.
    nonisolated private static func base64DataURL(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    // MARK: - Wire types — request

    // Wire types are pure Codable data with no main-actor state; their
    // `Encodable` conformances are `nonisolated` so `encodeBody` can
    // serialize them entirely off the main actor.
    private nonisolated struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
    }

    private nonisolated enum Message: Encodable {
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

nonisolated enum UserContentBlock: Encodable {
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
