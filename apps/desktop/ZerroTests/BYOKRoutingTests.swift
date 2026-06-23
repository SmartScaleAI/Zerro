//
//  BYOKRoutingTests.swift
//  ZerroTests
//
//  Phase 6 (multi-model 6C) — BYOK multi-provider:
//    • effectiveEntry routing (selection honored when its provider has a
//      key; cheapest-available fallback; nil when no chat key) — the same
//      pure function the key-gated picker derives row state from.
//    • The BYOK pricing mirror (cost.ts CHAT_PRICING parity, incl. the
//      Gemini 3.1 Pro input-token tier).
//    • The Gemini / Anthropic wire encodings, decoded back and asserted
//      against the server adapters' documented shapes.
//

import XCTest
@testable import Zerro

@MainActor
final class BYOKRoutingTests: XCTestCase {

    // MARK: - effectiveEntry routing

    func testSelectionHonoredWhenProviderHasKey() {
        let entry = BYOKRouting.effectiveEntry(
            selectedModelID: "claude-opus-4-7",
            availableProviders: [.anthropic]
        )
        XCTAssertEqual(entry?.id, "claude-opus-4-7")
    }

    func testKeylessSelectionFallsBackToCheapestAvailable() {
        // Recommended default (Gemini Flash) selected, but only an OpenAI key
        // on file → cheapest ENABLED OpenAI model, not a failure. With GPT-5.4
        // mini kill-switched, that's GPT-5.5 (the only enabled OpenAI model).
        let entry = BYOKRouting.effectiveEntry(
            selectedModelID: "gemini-3.5-flash",
            availableProviders: [.openai]
        )
        XCTAssertEqual(entry?.id, "gpt-5.5")
    }

    func testFallbackPrefersCheapestAcrossAvailableProviders() {
        let entry = BYOKRouting.effectiveEntry(
            selectedModelID: "claude-sonnet-4-6", // anthropic — no key
            availableProviders: [.openai, .gemini]
        )
        // Cheapest ENABLED model across the available providers. GPT-5.4 mini was
        // the cheapest overall, but it's disabled now, so the next cheapest the
        // user can run is Gemini Flash.
        XCTAssertEqual(entry?.id, "gemini-3.5-flash")
    }

    func testNoChatKeyAtAllReturnsNil() {
        XCTAssertNil(BYOKRouting.effectiveEntry(
            selectedModelID: "gemini-3.5-flash",
            availableProviders: []
        ))
    }

    func testUnknownSelectionFallsBack() {
        let entry = BYOKRouting.effectiveEntry(
            selectedModelID: "gpt-4o", // not a registry model anymore
            availableProviders: [.gemini]
        )
        XCTAssertEqual(entry?.id, "gemini-3.5-flash")
    }

    func testServiceMatchesProvider() {
        let gemini = BYOKRouting.service(for: ModelRegistry.entry(id: "gemini-3.5-flash")!)
        XCTAssertTrue(gemini is GeminiPromptGenerationService)
        let anthropic = BYOKRouting.service(for: ModelRegistry.entry(id: "claude-opus-4-7")!)
        XCTAssertTrue(anthropic is AnthropicPromptGenerationService)
        let openai = BYOKRouting.service(for: ModelRegistry.entry(id: "gpt-5.5")!)
        XCTAssertTrue(openai is OpenAIPromptGenerationService)
        XCTAssertEqual((openai as? OpenAIPromptGenerationService)?.model, "gpt-5.5")
    }

    // MARK: - Pricing mirror (cost.ts parity — literal expectations)

    func testPricingMirrorsServerTable() throws {
        // 1000 in / 1000 out on each model, against the cost.ts rates.
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 1_000, model: "x")
        func cost(_ id: String) -> Double? { BYOKCostEstimator.chatCostUSD(modelID: id, usage: usage) }
        XCTAssertEqual(try XCTUnwrap(cost("gpt-5.4-mini")), (0.75 + 4.5) / 1_000, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(cost("gpt-5.5")), (5.0 + 30.0) / 1_000, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(cost("gemini-3.5-flash")), (1.5 + 9.0) / 1_000, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(cost("claude-sonnet-4-6")), (3.0 + 15.0) / 1_000, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(cost("claude-opus-4-7")), (5.0 + 25.0) / 1_000, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(cost("gpt-4o")), (2.5 + 10.0) / 1_000, accuracy: 1e-12) // legacy
        XCTAssertNil(cost("some-unknown-model")) // unpriced, never guessed
    }

    func testGeminiProTierRaisesBothRatesAboveThreshold() throws {
        // Below the 200k-input tier: base rates.
        let below = TokenUsage(inputTokens: 100_000, outputTokens: 1_000, model: "x")
        XCTAssertEqual(
            try XCTUnwrap(BYOKCostEstimator.chatCostUSD(modelID: "gemini-3.1-pro-preview", usage: below)),
            100_000.0 / 1_000_000 * 2.0 + 1_000.0 / 1_000_000 * 12.0,
            accuracy: 1e-12
        )
        // Above: BOTH input and output price at the higher rate.
        let above = TokenUsage(inputTokens: 250_000, outputTokens: 1_000, model: "x")
        XCTAssertEqual(
            try XCTUnwrap(BYOKCostEstimator.chatCostUSD(modelID: "gemini-3.1-pro-preview", usage: above)),
            250_000.0 / 1_000_000 * 4.0 + 1_000.0 / 1_000_000 * 18.0,
            accuracy: 1e-12
        )
    }

    // MARK: - Wire encodings

    /// A 2-item timeline: one frame (with OCR) + one speech segment, the
    /// JPEG bytes written to a temp file like the real pipeline's frames.
    private func makeTimeline() throws -> (InterleavedTimeline, expectedBase64: String) {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] // JPEG magic, enough for encoding
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byok-test-\(UUID().uuidString).jpg")
        try Data(bytes).write(to: url)
        let timeline = InterleavedTimeline(items: [
            .frame(timestamp: 0, imageURL: url, ocrText: "Sign in"),
            .speech(start: 0, end: 8, text: "okay so this is the login page"),
            .click(timestamp: 9, label: "Save"),
        ])
        return (timeline, Data(bytes).base64EncodedString())
    }

    func testGeminiBodyMatchesServerAdapterShape() throws {
        let (timeline, base64) = try makeTimeline()
        let data = try GeminiPromptGenerationService.encodeBody(
            timeline: timeline, systemPrompt: "SYSTEM"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // systemInstruction rides as parts, never a content message.
        let system = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        let sysParts = try XCTUnwrap(system["parts"] as? [[String: Any]])
        XCTAssertEqual(sysParts.first?["text"] as? String, "SYSTEM")

        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        // frame → tag text, image, OCR text; speech; click = 5 parts.
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0]["text"] as? String, "\n[0:00] ")
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inline["data"] as? String, base64) // raw base64, no data: URL
        let resolution = try XCTUnwrap(parts[1]["mediaResolution"] as? [String: Any])
        XCTAssertEqual(resolution["level"] as? String, "media_resolution_high")
        XCTAssertEqual(parts[2]["text"] as? String, "\n[0:00] on-screen text: Sign in")
        XCTAssertEqual(parts[3]["text"] as? String, "\n[0:00\u{2013}0:08] \"okay so this is the login page\"")
        XCTAssertEqual(parts[4]["text"] as? String, "\n[0:09] clicked \"Save\"")

        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingLevel"] as? String, "low")
    }

    func testAnthropicBodyMatchesServerAdapterShape() throws {
        let (timeline, base64) = try makeTimeline()
        let data = try AnthropicPromptGenerationService.encodeBody(
            timeline: timeline, systemPrompt: "SYSTEM", model: "claude-opus-4-7"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "claude-opus-4-7")
        XCTAssertEqual(json["max_tokens"] as? Int, 16384) // REQUIRED by the Messages API (raised from 8192 to stop ~2-min truncation)
        XCTAssertEqual(json["system"] as? String, "SYSTEM") // top-level, never a message
        // NO sampling params, NO thinking field (Opus 4.7 400s on them).
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["thinking"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 5)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, base64)
        XCTAssertEqual(content[2]["text"] as? String, "\n[0:00] on-screen text: Sign in")
    }

    func testOpenAIBodyCarriesSelectedModel() throws {
        let (timeline, _) = try makeTimeline()
        let data = try OpenAIPromptGenerationService.encodeBody(
            timeline: timeline, systemPrompt: "SYSTEM", model: "gpt-5.4-mini"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.4-mini")
    }
}
