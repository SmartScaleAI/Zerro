//
//  TranscriptionCopyGuardTests.swift
//  ZerroTests
//
//  Phase 7 (Local Whisper) — a grep-style guard on user-facing failure copy.
//  Since on-device whisper.cpp landed, OpenAI is OPTIONAL for transcription (a
//  Claude/Gemini user + the on-device model transcribes with no OpenAI key). No
//  `RecordingFailureReason` copy may reassert the old "OpenAI is REQUIRED for
//  transcription" claim. Iterates ALL cases (via `CaseIterable`) so a future
//  reason with stale wording is caught too.
//

import XCTest
@testable import Zerro

final class TranscriptionCopyGuardTests: XCTestCase {

    /// Phrases that assert OpenAI is required for transcription — none may appear
    /// in any reason's user-facing strings.
    private static let forbiddenPhrases = [
        "required for transcription",
        "openai key is required",
        "always runs on openai",
        "transcription (whisper) always runs on openai",
        "needs an openai key too",
    ]

    func testNoFailureCopyClaimsOpenAIRequiredForTranscription() {
        for reason in RecordingFailureReason.allCases {
            // Every user-facing projection of the reason.
            let surfaces = [reason.userMessage, reason.detail, reason.headline]
            for surface in surfaces {
                let lower = surface.lowercased()
                for phrase in Self.forbiddenPhrases {
                    XCTAssertFalse(
                        lower.contains(phrase),
                        "\(reason) copy must not assert OpenAI is required for transcription — found \u{201C}\(phrase)\u{201D} in: \(surface)"
                    )
                }
            }
        }
    }

    /// Positive lock on the rewritten `.apiKeyMissing` copy: it now offers BOTH
    /// paths (on-device model OR OpenAI) rather than asserting OpenAI is required.
    /// Keeps the guard from passing on empty/weakened copy.
    func testApiKeyMissingCopyOffersOnDeviceAndOpenAIPaths() {
        let detail = RecordingFailureReason.apiKeyMissing.detail.lowercased()
        XCTAssertTrue(detail.contains("on-device"), "apiKeyMissing detail should name the on-device transcription path")
        XCTAssertTrue(detail.contains("openai"), "apiKeyMissing detail should still name OpenAI as AN option")

        let message = RecordingFailureReason.apiKeyMissing.userMessage.lowercased()
        XCTAssertTrue(
            message.contains("on-device") || message.contains("transcribe"),
            "apiKeyMissing userMessage should reflect the transcription options, not an OpenAI mandate"
        )
    }

    /// The Phase-6 `.localModelUnavailable` copy already frames OpenAI as an
    /// OPTION (\u{201C}or switch to OpenAI cloud\u{201D}); assert it stays that way.
    func testLocalModelUnavailableFramesOpenAIAsOptional() {
        let detail = RecordingFailureReason.localModelUnavailable.detail.lowercased()
        XCTAssertTrue(detail.contains("on-device"))
        XCTAssertTrue(detail.contains("openai"))
        XCTAssertFalse(detail.contains("required"), "the on-device option must not be framed as requiring OpenAI")
    }
}
