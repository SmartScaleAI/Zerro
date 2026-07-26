//
//  DevAgentAuthErrorDetectorTests.swift
//  ZerroTests
//
//  Pins the `.sessionExpired` classification (`DevAgentAuthErrorDetector`):
//  the expired/invalid-login 401 must be recognized structured-first (the
//  provider's `authentication_error` code, then a 401 status + auth marker,
//  message phrases only as the floor) — and, just as load-bearing, unrelated
//  failures must NOT be reclassified, so a build error or a stray "401" in
//  output keeps the raw-error card.
//

import XCTest
@testable import Zerro

final class DevAgentAuthErrorDetectorTests: XCTestCase {

    // MARK: Detected — the real-world shapes

    func testDetectsClaudeCodeExpiredOAuthResultText() {
        // The exact text that prompted this, as Claude Code's terminal `result`.
        XCTAssertTrue(DevAgentAuthErrorDetector.isSessionExpired(
            "Failed to authenticate. API Error: 401 OAuth access token has expired. "
            + "Re-authenticate to continue."
        ))
    }

    func testDetectsEmbeddedProviderErrorCode() {
        // Claude Code often echoes the raw Anthropic 401 body — its
        // `authentication_error` type is the machine-readable signal (rule 1),
        // independent of any prose around it.
        XCTAssertTrue(DevAgentAuthErrorDetector.isSessionExpired(
            #"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth access token has expired."}}"#
        ))
    }

    func testDetects401Unauthorized() {
        // The generic CLI shape (Codex/Cursor): a 401 status + "Unauthorized".
        XCTAssertTrue(DevAgentAuthErrorDetector.isSessionExpired(
            "stream error: unexpected status 401 Unauthorized"
        ))
    }

    func testDetectsRunLoginInstructionWithoutStatusLine() {
        // A build that omits the status line but prints the CLI's own re-auth
        // instruction (rule 3, the floor).
        XCTAssertTrue(DevAgentAuthErrorDetector.isSessionExpired(
            "Invalid API key \u{00B7} Please run /login"
        ))
    }

    // MARK: Not detected — must stay the generic failure card

    func testIgnoresEmptyDetail() {
        XCTAssertFalse(DevAgentAuthErrorDetector.isSessionExpired(""))
    }

    func testIgnoresBuildFailure() {
        XCTAssertFalse(DevAgentAuthErrorDetector.isSessionExpired(
            "npm ERR! code ELIFECYCLE — build failed with exit code 1"
        ))
    }

    func testIgnoresMaxTokensError() {
        // "token" appears but there's no 401/auth signal — the max-output cap is
        // a generation failure, not a login problem.
        XCTAssertFalse(DevAgentAuthErrorDetector.isSessionExpired(
            "error_max_turns: the run hit the max output token limit"
        ))
    }

    func testIgnoresStray401WithoutAuthMarker() {
        // A bare 401 in unrelated output (rule 2 needs status AND marker).
        XCTAssertFalse(DevAgentAuthErrorDetector.isSessionExpired(
            "test FAILED: expected item count 401 but found 400"
        ))
    }

    func testIgnores401InsideALongerNumber() {
        // The status match is a standalone token — 40100 / 14012 must not trip it.
        XCTAssertFalse(DevAgentAuthErrorDetector.isSessionExpired(
            "request id 140123 unauthorized region fallback"
        ))
    }

    func testIgnoresPermissionDenied() {
        // The common edits-only denial stays on its existing path.
        XCTAssertFalse(DevAgentAuthErrorDetector.isSessionExpired(
            "Permission denied (Bash: git fetch origin main)"
        ))
    }
}
