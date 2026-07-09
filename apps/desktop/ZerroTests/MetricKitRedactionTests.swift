//
//  MetricKitRedactionTests.swift
//  ZerroTests
//
//  I-04 — MetricKitObserver.redactUserPaths: /Users/<name> home paths must be
//  stripped from the free-text `termination_reason` BEFORE the 150-char
//  truncation (redact-then-truncate), so a path near the cap can't leak a
//  partial username. The DevAgentBinaryResolver .public→.private log change is
//  build-only (log content isn't unit-tested here).
//

import XCTest
@testable import Zerro

final class MetricKitRedactionTests: XCTestCase {

    func testRedactsHomePathKeepingTheTailForDebugging() {
        XCTAssertEqual(
            MetricKitObserver.redactUserPaths("/Users/johnsmith/Library/foo not loaded"),
            "/Users/<redacted>/Library/foo not loaded"
        )
    }

    func testRedactsEveryOccurrence() {
        XCTAssertEqual(
            MetricKitObserver.redactUserPaths("dyld: /Users/jane/a.dylib vs /Users/jane/b.dylib"),
            "dyld: /Users/<redacted>/a.dylib vs /Users/<redacted>/b.dylib"
        )
    }

    func testRedactsAPathThatEndsAtTheUsername() {
        XCTAssertEqual(
            MetricKitObserver.redactUserPaths("working dir was /Users/johnsmith"),
            "working dir was /Users/<redacted>"
        )
    }

    func testTextWithoutAUsersPathIsUnchanged() {
        let text = "EXC_BAD_ACCESS at /usr/lib/libobjc.A.dylib (code 1, subcode 8)"
        XCTAssertEqual(MetricKitObserver.redactUserPaths(text), text)
    }

    func testRedactThenTruncateLeaksNoPartialUsername() {
        // Position /Users/<name> so the USERNAME straddles the 150-char cap:
        // 140 chars of padding + "/Users/" (7) puts the username at chars
        // 148…, so a raw prefix(150) cuts mid-username.
        let username = "johnappleseed"
        let cap = 150
        let padding = String(repeating: "x", count: 140)
        let reason = padding + "/Users/\(username)/Library/Caches/whatever.dylib"

        // Sanity: WITHOUT redaction, truncation would leak a partial username.
        let rawTruncated = String(reason.prefix(cap))
        XCTAssertTrue(rawTruncated.contains("/Users/joh"), "test setup must reproduce the leak")

        // Redact-then-truncate (the crashEvent order): no full or partial
        // username survives in the <=150-char value that would be transmitted.
        let redactedTruncated = String(MetricKitObserver.redactUserPaths(reason).prefix(cap))
        XCTAssertLessThanOrEqual(redactedTruncated.count, cap)
        XCTAssertFalse(redactedTruncated.contains(username))
        XCTAssertFalse(redactedTruncated.contains("joh"), "no partial username fragment either")
        // 140 padding chars leave exactly 10 for the path, so what straddles
        // the cap is the START of the placeholder, never a username character.
        XCTAssertTrue(redactedTruncated.hasSuffix("/Users/<re"), "the placeholder is what straddles the cap instead")
    }
}
