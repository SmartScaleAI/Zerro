//
//  OpenAIStatusMappingTests.swift
//  ZerroTests
//
//  J-02 — HTTP-status → typed-error mapping for BOTH OpenAI BYOK adapters.
//  Pins that 403 maps to .auth exactly like 401: OpenAI returns 403 for
//  rejected keys and permission/region denials, which previously fell
//  through to the generic .server branch and dead-ended in a misleading
//  transient-outage message. Also pins the untouched branches: 2xx → nil
//  (success), 429 → rateLimited, 5xx/other → server(status). The sibling
//  Gemini/Anthropic adapters already fold 403 into their inline auth
//  branch, so they don't share the gap (and stay inline/untested here).
//

import XCTest
@testable import Zerro

final class OpenAIStatusMappingTests: XCTestCase {

    // MARK: Transcription (Whisper)

    func testTranscription401And403MapToAuth() throws {
        for status in [401, 403] {
            let error = try XCTUnwrap(OpenAITranscriptionService.error(forStatus: status))
            guard case .auth = error else {
                return XCTFail("\(status) must map to .auth, got \(error)")
            }
        }
    }

    func testTranscription403IsNotServer() throws {
        // The J-02 regression shape: 403 used to fall through to .server.
        let error = try XCTUnwrap(OpenAITranscriptionService.error(forStatus: 403))
        if case .server = error {
            XCTFail("403 fell through to .server — the rejected-key gap is back")
        }
    }

    func testTranscriptionNonAuthNon2xxStaysServer() throws {
        for status in [500, 503, 404] {
            let error = try XCTUnwrap(OpenAITranscriptionService.error(forStatus: status))
            guard case .server(let carried) = error else {
                return XCTFail("\(status) must map to .server, got \(error)")
            }
            XCTAssertEqual(carried, status, "the typed error carries the status code (and nothing else)")
        }
    }

    func testTranscriptionSuccessAndRateLimitBranchesUnchanged() throws {
        XCTAssertNil(OpenAITranscriptionService.error(forStatus: 200))
        XCTAssertNil(OpenAITranscriptionService.error(forStatus: 204))
        let error = try XCTUnwrap(OpenAITranscriptionService.error(forStatus: 429))
        guard case .rateLimited = error else {
            return XCTFail("429 must map to .rateLimited, got \(error)")
        }
    }

    // MARK: Prompt generation (Chat Completions)

    func testPromptGeneration401And403MapToAuth() throws {
        for status in [401, 403] {
            let error = try XCTUnwrap(OpenAIPromptGenerationService.error(forStatus: status))
            guard case .auth = error else {
                return XCTFail("\(status) must map to .auth, got \(error)")
            }
        }
    }

    func testPromptGeneration403IsNotServer() throws {
        let error = try XCTUnwrap(OpenAIPromptGenerationService.error(forStatus: 403))
        if case .server = error {
            XCTFail("403 fell through to .server — the rejected-key gap is back")
        }
    }

    func testPromptGenerationNonAuthNon2xxStaysServer() throws {
        for status in [500, 503, 404] {
            let error = try XCTUnwrap(OpenAIPromptGenerationService.error(forStatus: status))
            guard case .server(let carried) = error else {
                return XCTFail("\(status) must map to .server, got \(error)")
            }
            XCTAssertEqual(carried, status, "the typed error carries the status code (and nothing else)")
        }
    }

    func testPromptGenerationSuccessAndRateLimitBranchesUnchanged() throws {
        XCTAssertNil(OpenAIPromptGenerationService.error(forStatus: 200))
        XCTAssertNil(OpenAIPromptGenerationService.error(forStatus: 204))
        let error = try XCTUnwrap(OpenAIPromptGenerationService.error(forStatus: 429))
        guard case .rateLimited = error else {
            return XCTFail("429 must map to .rateLimited, got \(error)")
        }
    }
}
