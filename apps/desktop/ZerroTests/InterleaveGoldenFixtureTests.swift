//
//  InterleaveGoldenFixtureTests.swift
//  ZerroTests
//
//  J-07 — the Swift half of the shared interleave golden fixture. The
//  interleave wire-rendering is implemented three times (Interleaver +
//  the BYOK encodeBody renderers here, interleave.ts on the server,
//  buildTimeline in Scripts/eval-models.mjs) and kept aligned only by
//  KEEP IN SYNC comments. This test and the server's interleave_test.ts
//  both assert the SAME fixture (Scripts/artifact-eval/interleave-golden
//  .json, read via #filePath like PromptV2MirrorTests), so a format
//  drift on either side fails a suite instead of shipping.
//
//  The fixture pins: frame < click < speech tie-break at an equal start
//  second, the `on-screen text:` block riding right after its frame,
//  the empty-label click drop, M:SS truncation (not rounding), and the
//  em-dash (U+2013) speech range tag.
//

import CoreMedia
import XCTest
@testable import Zerro

final class InterleaveGoldenFixtureTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture: Decodable {
        struct Frame: Decodable {
            let timestamp: Double
            let ocrText: String?
        }
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        struct Click: Decodable {
            let timestamp: Double
            let label: String
        }
        /// A provider-neutral wire block: exactly one of `text` / `image`.
        struct Block: Decodable {
            let text: String?
            let image: Bool?
        }
        let frames: [Frame]
        let segments: [Segment]
        let clicks: [Click]
        let expectedBlocks: [Block]
        let expectedDebugLines: [String]
    }

    /// `ZerroTests/…` → `apps/desktop/` → `Scripts/artifact-eval/…` (same
    /// repo-relative pattern as PromptV2MirrorTests).
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/artifact-eval/interleave-golden.json")

    private func loadFixture() throws -> Fixture {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// The fixture's expected wire sequence in the neutral string form the
    /// per-provider assertions below reduce their decoded bodies to.
    private func expectedRendering(_ fixture: Fixture) -> [String] {
        fixture.expectedBlocks.map { block in
            if block.image == true { return "{image}" }
            return "text:\(block.text ?? "")"
        }
    }

    // MARK: - Timeline construction

    /// A tiny stand-in JPEG on disk so encodeBody's per-frame read succeeds;
    /// the image BYTES are irrelevant to the fixture (only block kind +
    /// position are asserted — the base64 payload differs per provider by
    /// design).
    private var frameFileURL: URL!

    override func setUpWithError() throws {
        frameFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interleave-golden-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]).write(to: frameFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: frameFileURL)
    }

    private func makeTimeline(_ fixture: Fixture) -> InterleavedTimeline {
        let frames = fixture.frames.enumerated().map { index, frame in
            ExtractedFrame(
                url: frameFileURL,
                timestamp: CMTime(seconds: frame.timestamp, preferredTimescale: 600),
                index: index,
                ocrText: frame.ocrText,
                lines: []
            )
        }
        let segments = fixture.segments.map {
            TranscriptSegment(start: $0.start, end: $0.end, text: $0.text)
        }
        let clicks = fixture.clicks.map {
            ResolvedClick(seconds: $0.timestamp, label: $0.label)
        }
        return Interleaver.merge(
            frames: frames,
            transcript: Transcript(
                segments: segments,
                fullText: segments.map(\.text).joined(separator: " ")
            ),
            clicks: clicks
        )
    }

    // MARK: - Interleaver ordering + debug mirror

    func testMergeMatchesTheGoldenDebugLines() throws {
        let fixture = try loadFixture()
        let timeline = makeTimeline(fixture)
        XCTAssertEqual(
            timeline.debugDescription,
            fixture.expectedDebugLines.joined(separator: "\n"),
            "Interleaver.merge/debugDescription drifted from the shared golden fixture"
        )
    }

    // MARK: - Per-provider wire rendering

    /// Decodes an encoded request body and reduces the user-content array to
    /// the neutral `text:…` / `{image}` form via `extractBlock`.
    private func rendering(
        ofBody body: Data,
        userContent: (NSDictionary) throws -> [NSDictionary],
        extractBlock: (NSDictionary) -> String?
    ) throws -> [String] {
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? NSDictionary
        )
        return try userContent(json).compactMap { block in
            let rendered = extractBlock(block)
            XCTAssertNotNil(rendered, "unrecognized content block shape: \(block)")
            return rendered
        }
    }

    func testOpenAIEncodeBodyMatchesTheGoldenBlocks() throws {
        let fixture = try loadFixture()
        let body = try OpenAIPromptGenerationService.encodeBody(
            timeline: makeTimeline(fixture),
            systemPrompt: "system"
        )
        let rendered = try rendering(ofBody: body) { json in
            let messages = try XCTUnwrap(json["messages"] as? [NSDictionary])
            let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
            return try XCTUnwrap(user["content"] as? [NSDictionary])
        } extractBlock: { block in
            switch block["type"] as? String {
            case "text": return (block["text"] as? String).map { "text:\($0)" }
            case "image_url": return "{image}"
            default: return nil
            }
        }
        XCTAssertEqual(rendered, expectedRendering(fixture))
    }

    func testAnthropicEncodeBodyMatchesTheGoldenBlocks() throws {
        let fixture = try loadFixture()
        let body = try AnthropicPromptGenerationService.encodeBody(
            timeline: makeTimeline(fixture),
            systemPrompt: "system",
            model: "claude-sonnet-4-6"
        )
        let rendered = try rendering(ofBody: body) { json in
            let messages = try XCTUnwrap(json["messages"] as? [NSDictionary])
            let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
            return try XCTUnwrap(user["content"] as? [NSDictionary])
        } extractBlock: { block in
            switch block["type"] as? String {
            case "text": return (block["text"] as? String).map { "text:\($0)" }
            case "image": return "{image}"
            default: return nil
            }
        }
        XCTAssertEqual(rendered, expectedRendering(fixture))
    }

    func testGeminiEncodeBodyMatchesTheGoldenBlocks() throws {
        let fixture = try loadFixture()
        let body = try GeminiPromptGenerationService.encodeBody(
            timeline: makeTimeline(fixture),
            systemPrompt: "system"
        )
        let rendered = try rendering(ofBody: body) { json in
            let contents = try XCTUnwrap(json["contents"] as? [NSDictionary])
            let user = try XCTUnwrap(contents.first { $0["role"] as? String == "user" })
            return try XCTUnwrap(user["parts"] as? [NSDictionary])
        } extractBlock: { part in
            if part["inlineData"] != nil { return "{image}" }
            return (part["text"] as? String).map { "text:\($0)" }
        }
        XCTAssertEqual(rendered, expectedRendering(fixture))
    }
}
