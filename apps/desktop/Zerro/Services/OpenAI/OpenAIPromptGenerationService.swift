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
//      "max_completion_tokens": 16384,
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

    /// The pre-multi-model BYOK default. Kept as the init default so legacy
    /// call sites/tests are unchanged; the production path now passes the
    /// user's REGISTRY selection via BYOKRouting (multi-model 6C), so this
    /// only applies when no registry model is threaded through.
    nonisolated static let defaultModel = "gpt-4o"

    /// The model id to run (e.g. "gpt-5.4-mini"). Selected per generation by
    /// BYOKRouting.
    let model: String

    /// J-06 test seams — behavior-identical defaults at every production call
    /// site (`nil ??` falls through to the live Keychain read; the shared
    /// session is what `performWithRetry` used unconditionally before). The
    /// adapter tests inject a fixed key + a URLProtocol-stubbed session so the
    /// full `generatePrompt` flow — status mapping, parsing, truncation — runs
    /// without Keychain or network.
    var apiKeyOverride: String?
    var session: URLSession = OpenAIClient.session

    /// B-04 — output-token cap so a BYOK generation on the user's own key is
    /// bounded instead of running to the model's default max. Mirrors the
    /// original server adapter's OPENAI_MAX_OUTPUT_TOKENS. Typical output is
    /// ~1k tokens;
    /// 16384 is ample headroom (a normal response never truncates — only a
    /// runaway is cut, surfaced as `.truncated` via finish_reason "length").
    /// Sent as `max_completion_tokens` — NOT the deprecated `max_tokens` —
    /// matching the server and required by the GPT-5.x family.
    private nonisolated static let maxCompletionTokens = 16384

    init(model: String = OpenAIPromptGenerationService.defaultModel) {
        self.model = model
    }

    /// Typed mapping from the Chat Completions response status to the error
    /// thrown for it — nil for 2xx success. Factored out of `generatePrompt`
    /// so the mapping is unit-testable without a live request. 401 AND 403
    /// both map to `.auth` (J-02): OpenAI returns 403 for rejected keys and
    /// permission/region denials, which previously fell through to `.server`
    /// and surfaced as a misleading transient-outage message. A 429 reaching
    /// here is either quota exhaustion (`insufficient_quota` body, J-03 —
    /// performWithRetry deliberately didn't retry it) or a rate limit that
    /// outlived performWithRetry's single retry; `body` tells them apart.
    static func error(forStatus status: Int, body: Data = Data()) -> PromptGenerationError? {
        switch status {
        case 200...299: return nil
        case 401, 403: return .auth
        case 429:
            return OpenAIClient.isQuotaExhausted429(status: status, body: body)
                ? .quotaExhausted
                : .rateLimited
        default: return .server(status: status)
        }
    }

    func generatePrompt(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) async throws -> PromptGenerationResult {
        guard let apiKey = apiKeyOverride ?? OpenAIClient.resolveAPIKey() else {
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
        let model = self.model
        let bodyData = try await Task.detached(priority: .userInitiated) {
            try Self.encodeBody(timeline: timeline, systemPrompt: systemPrompt, model: model)
        }.value

        var request = URLRequest(url: OpenAIClient.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OpenAIClient.authenticate(&request, apiKey: apiKey)
        request.httpBody = bodyData

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await OpenAIClient.performWithRetry(request, session: session)
        } catch {
            throw PromptGenerationError.network(underlying: error)
        }

        if let statusError = Self.error(forStatus: response.statusCode, body: data) {
            if case .server = statusError {
                // Log the provider's error body `.private` for local debugging
                // only — it must NOT ride into the typed error, which can reach
                // the error tracker, where the exception value is scrubbed by length, not by
                // content. The error keeps just the status code.
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                Log.promptGen.error("Chat Completions non-2xx \(response.statusCode, privacy: .public): \(body, privacy: .private)")
            }
            throw statusError
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw PromptGenerationError.decodeFailure(underlying: error)
        }

        // A `length` finish means the generation was cut off at the output-token
        // limit; the partial content can carry an unterminated `<<<ZERRO_ARTIFACT`
        // fence, so it must NOT reach the parser as a clean success
        // (handoff-artifact-fence-leak). Checked before the empty-content guard
        // because a truncated response usually DOES have (partial) content.
        if decoded.choices.first?.finishReason == "length" {
            throw PromptGenerationError.truncated
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
                model: decoded.model ?? model
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
    /// never held on the in-memory timeline. `nonisolated` so it
    /// runs in a detached task off the main actor: under the project's
    /// MainActor-default isolation an unmarked static on this struct would
    /// be implicitly main-isolated and bounce the work right back to main.
    nonisolated static func encodeBody(
        timeline: InterleavedTimeline,
        systemPrompt: String,
        model: String = OpenAIPromptGenerationService.defaultModel
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
                // to the eval (eval-models.mjs)
                // rendering — KEEP IN SYNC if you touch this format.
                if let ocr = ocrText, !ocr.isEmpty {
                    userContent.append(.text("\n\(item.timestampTag) on-screen text: \(ocr)"))
                }

            case .speech(_, _, let text):
                userContent.append(.text("\n\(item.timestampTag) \"\(text)\""))

            case .click(_, let label):
                // Phase 4: a click line — `\n[M:SS] clicked "<label>"`.
                // Byte-identical to the eval
                // (eval-models.mjs) rendering — KEEP IN SYNC if you touch this.
                userContent.append(.text("\n\(item.timestampTag) clicked \"\(label)\""))

            case .rawText(let text):
                // Verbatim single text block — no tag, no newline prefix, no quoting.
                userContent.append(.text(text))
            }
        }

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .systemMessage(content: systemPrompt),
                .userMessage(content: userContent)
            ],
            maxCompletionTokens: maxCompletionTokens
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
        /// B-04 output cap — see `maxCompletionTokens`.
        let maxCompletionTokens: Int

        private enum CodingKeys: String, CodingKey {
            case model, messages
            case maxCompletionTokens = "max_completion_tokens"
        }
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

    // Cost estimation moved to `BYOKCostEstimator` (multi-model 6C) — the
    // single Swift pricing table (kept in sync with the eval harness's
    // CHAT_PRICING), covering all three providers (this file's gpt-4o
    // constants would have been another drift-prone copy).

    // MARK: - Wire types — response

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        let usage: Usage?
        let model: String?

        struct Choice: Decodable {
            let message: ChoiceMessage
            /// `"stop"` on a complete response, `"length"` when the model hit
            /// the output-token limit (→ truncated). Optional: absent on some
            /// streamed/edge shapes, which we treat as non-truncated.
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
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
