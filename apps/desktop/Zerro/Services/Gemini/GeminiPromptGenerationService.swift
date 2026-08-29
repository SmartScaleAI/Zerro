//
//  GeminiPromptGenerationService.swift
//  Zerro
//
//  Phase 6 (multi-model 6C) — PromptGenerationService impl backed by the
//  Gemini generateContent API, for BYOK users running a Gemini chat model on
//  their own key. Transcription is NOT handled here — it runs separately,
//  either on-device (whisper.cpp, no key) or on OpenAI cloud, so a Gemini-only
//  user can transcribe with the on-device model and never needs an OpenAI key.
//
//  Wire format ported from the original server-side adapter (since removed
//  from the repository; verified against ai.google.dev docs 2026-06-04) and
//  the Phase 0 eval harness (Scripts/eval-models.mjs). KEEP IN SYNC with the
//  harness if either changes:
//    POST {base}/models/{model}:generateContent
//    Headers:  x-goog-api-key: <key>   (header, never the URL — it would log)
//    Body: {
//      "systemInstruction": {"parts": [{"text": "<composed system prompt>"}]},
//      "contents": [{"role": "user", "parts": [
//        {"text": "\n[0:00] "},
//        {"inlineData": {"mimeType": "image/jpeg", "data": "<base64>"},
//         "mediaResolution": {"level": "media_resolution_high"}},   // per-part (Gemini 3)
//        {"text": "\n[0:00–0:08] \"okay so this is...\""}, ...
//      ]}],
//      "generationConfig": {"maxOutputTokens": 16384,
//                           "thinkingConfig": {"thinkingLevel": "low"}}
//    }
//  Response: candidates[0].content.parts (skip `thought` parts),
//    usageMetadata {promptTokenCount, candidatesTokenCount, thoughtsTokenCount
//    — thoughts billed as output, folded in}, modelVersion.
//
//  The interleaved text/image rendering (timestamp tags, OCR lines, click
//  lines) is byte-identical to the OpenAI impl and the eval harness
//  (InterleaveGoldenFixtureTests pins it) — KEEP IN SYNC if you touch the
//  format.
//

import Foundation
import os

struct GeminiPromptGenerationService: PromptGenerationService {

    // `nonisolated` so the off-main encodeBody/detached task can read them
    // under the project's MainActor-default isolation (same as the OpenAI
    // impl's `model` static).
    private nonisolated static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    /// Mirrors the server's GEMINI_THINKING_LEVEL default — the rewrite task
    /// rarely benefits from deep thinking, and "high" bills thinking tokens.
    private nonisolated static let thinkingLevel = "low"

    /// B-04 — output-token cap so a BYOK generation on the user's own key is
    /// bounded instead of running to the model's default max. Mirrors the
    /// original server adapter's GEMINI_MAX_OUTPUT_TOKENS. Typical output is
    /// ~1k tokens;
    /// 16384 is ample headroom (a normal response never truncates — only a
    /// runaway is cut, surfaced as `.truncated` via finishReason MAX_TOKENS).
    private nonisolated static let maxOutputTokens = 16384

    /// The registry model id to run (e.g. "gemini-3.5-flash"). Selected per
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
        guard let apiKey = apiKeyOverride ?? ProviderKeys.resolveKey(for: .gemini) else {
            throw PromptGenerationError.missingAPIKey
        }

        // Off-main body build, same discipline as the OpenAI impl: per-frame
        // disk read + base64 + full JSON encode before the first await.
        let model = self.model
        let bodyData = try await Task.detached(priority: .userInitiated) {
            try Self.encodeBody(timeline: timeline, systemPrompt: systemPrompt)
        }.value

        var request = URLRequest(
            url: Self.base.appendingPathComponent("models/\(model):generateContent")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
            // J-03: Gemini folds daily-quota exhaustion AND per-minute rate
            // limits into the same 429 RESOURCE_EXHAUSTED shape, separable
            // only by undocumented quotaId strings in the details array —
            // not a stable signal, so no quota detection here; every 429
            // stays on the rate-limit path.
            throw PromptGenerationError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Log.promptGen.error("Gemini generateContent non-2xx \(response.statusCode, privacy: .public): \(body, privacy: .private)")
            throw PromptGenerationError.server(status: response.statusCode)
        }

        let decoded: GenerateContentResponse
        do {
            decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            throw PromptGenerationError.decodeFailure(underlying: error)
        }

        // A prompt-level block (safety/recitation) means no candidate at all;
        // a non-STOP finish yields no usable text. Both are the model's
        // choice, not an outage → emptyContent (as the original server adapter did).
        if decoded.promptFeedback?.blockReason != nil {
            throw PromptGenerationError.emptyContent
        }
        let candidate = decoded.candidates?.first
        let finish = candidate?.finishReason
        // MAX_TOKENS means the generation was cut off at the output-token limit;
        // the partial text can carry an unterminated `<<<ZERRO_ARTIFACT` fence,
        // so it must NOT reach the parser as a clean success
        // (handoff-artifact-fence-leak). No longer folded into `usableFinish`.
        if finish == "MAX_TOKENS" {
            throw PromptGenerationError.truncated
        }
        // A non-STOP finish (SAFETY/RECITATION/PROHIBITED_CONTENT) yields no
        // usable text → emptyContent (the model's choice, server parity).
        let usableFinish = finish == nil || finish == "STOP"
        let text = (candidate?.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        guard usableFinish, !text.isEmpty else {
            throw PromptGenerationError.emptyContent
        }

        // thoughtsTokenCount is billed at the output rate — fold it into
        // outputTokens so the cost log matches the bill (server parity).
        let usage = decoded.usageMetadata
        return PromptGenerationResult(
            prompt: text,
            usage: TokenUsage(
                inputTokens: usage?.promptTokenCount ?? 0,
                outputTokens: (usage?.candidatesTokenCount ?? 0) + (usage?.thoughtsTokenCount ?? 0),
                model: decoded.modelVersion ?? model
            )
        )
    }

    // MARK: - Body encoding

    /// Builds the generateContent body from the timeline. Rendering rules are
    /// byte-identical to the OpenAI impl (one "\n[tag] " text part per frame,
    /// the image part, an optional OCR text part, speech/click lines).
    nonisolated static func encodeBody(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) throws -> Data {
        var parts: [Part] = []
        for item in timeline.items {
            switch item {
            case .frame(_, let imageURL, let ocrText):
                let base64: String
                do {
                    base64 = try Data(contentsOf: imageURL).base64EncodedString()
                } catch {
                    throw PromptGenerationError.network(underlying: error)
                }
                parts.append(Part(text: "\n\(item.timestampTag) "))
                parts.append(Part(
                    inlineData: InlineData(mimeType: "image/jpeg", data: base64),
                    // Per-part media resolution (Gemini 3) — the analog of
                    // OpenAI detail:"high" (as the original server adapter did).
                    mediaResolution: MediaResolution(level: "media_resolution_high")
                ))
                if let ocr = ocrText, !ocr.isEmpty {
                    parts.append(Part(text: "\n\(item.timestampTag) on-screen text: \(ocr)"))
                }
            case .speech(_, _, let text):
                parts.append(Part(text: "\n\(item.timestampTag) \"\(text)\""))
            case .click(_, let label):
                parts.append(Part(text: "\n\(item.timestampTag) clicked \"\(label)\""))
            case .rawText(let text):
                // Verbatim single text block — no tag, no quoting.
                parts.append(Part(text: text))
            }
        }

        let body = GenerateContentRequest(
            systemInstruction: SystemInstruction(parts: [TextPart(text: systemPrompt)]),
            contents: [Content(role: "user", parts: parts)],
            generationConfig: GenerationConfig(
                maxOutputTokens: maxOutputTokens,
                thinkingConfig: ThinkingConfig(thinkingLevel: thinkingLevel)
            )
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw PromptGenerationError.decodeFailure(underlying: error)
        }
    }

    // MARK: - Key validation (Settings pill)

    /// Cheapest authenticated probe: GET /models with the key header. Same
    /// semantics as OpenAIClient.validateKey (401/403 → invalid; transient
    /// trouble → inconclusive, never punitive).
    static func validateKey(_ apiKey: String) async -> OpenAIClient.KeyValidationResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }

        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(trimmed, forHTTPHeaderField: "x-goog-api-key")

        do {
            let (_, raw) = try await OpenAIClient.session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200...299: return .valid
            case 400, 401, 403: return .invalidKey // Gemini rejects bad keys as 400
            default: return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    // MARK: - Wire types — request

    private nonisolated struct GenerateContentRequest: Encodable {
        let systemInstruction: SystemInstruction
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private nonisolated struct SystemInstruction: Encodable {
        let parts: [TextPart]
    }

    private nonisolated struct TextPart: Encodable {
        let text: String
    }

    private nonisolated struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    private nonisolated struct Part: Encodable {
        var text: String?
        var inlineData: InlineData?
        var mediaResolution: MediaResolution?
    }

    private nonisolated struct InlineData: Encodable {
        let mimeType: String
        let data: String
    }

    private nonisolated struct MediaResolution: Encodable {
        let level: String
    }

    private nonisolated struct GenerationConfig: Encodable {
        /// B-04 output cap — see `maxOutputTokens`. Encodes camelCase per the
        /// Gemini API.
        let maxOutputTokens: Int
        let thinkingConfig: ThinkingConfig
    }

    private nonisolated struct ThinkingConfig: Encodable {
        let thinkingLevel: String
    }

    // MARK: - Wire types — response

    private struct GenerateContentResponse: Decodable {
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
        let usageMetadata: UsageMetadata?
        let modelVersion: String?

        struct Candidate: Decodable {
            let content: CandidateContent?
            let finishReason: String?
        }

        struct CandidateContent: Decodable {
            let parts: [ResponsePart]?
        }

        struct ResponsePart: Decodable {
            let text: String?
            let thought: Bool?
        }

        struct PromptFeedback: Decodable {
            let blockReason: String?
        }

        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
        }
    }
}
