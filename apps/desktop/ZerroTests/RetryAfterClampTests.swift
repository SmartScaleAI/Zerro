//
//  RetryAfterClampTests.swift
//  ZerroTests
//
//  J-04 — the pre-retry `Retry-After` sleep in OpenAIClient.performWithRetry
//  is bounded so a provider sending `Retry-After: 3600` can't wedge the pill
//  in "generating" for an hour (ties into the H pill-stall work). Pins the
//  clamp's edges: huge → maxRetryAfterSeconds, small → passthrough, absent →
//  the 2-second default, negative → 0 (a malformed value must never reach
//  the UInt64 nanosecond conversion). All three BYOK providers route 429s
//  through performWithRetry, so this single bound covers them all.
//

import XCTest
@testable import Zerro

final class RetryAfterClampTests: XCTestCase {

    func testHugeRetryAfterClampsToMax() {
        XCTAssertEqual(
            OpenAIClient.boundedRetryDelay(3600),
            OpenAIClient.maxRetryAfterSeconds,
            "an hour-long Retry-After must be capped, not honored"
        )
        XCTAssertEqual(
            OpenAIClient.boundedRetryDelay(.greatestFiniteMagnitude),
            OpenAIClient.maxRetryAfterSeconds
        )
    }

    func testSmallRetryAfterPassesThroughUnchanged() {
        XCTAssertEqual(OpenAIClient.boundedRetryDelay(5), 5)
        XCTAssertEqual(OpenAIClient.boundedRetryDelay(0), 0)
        XCTAssertEqual(OpenAIClient.boundedRetryDelay(OpenAIClient.maxRetryAfterSeconds),
                       OpenAIClient.maxRetryAfterSeconds)
    }

    func testMissingRetryAfterUsesDefault() {
        XCTAssertEqual(
            OpenAIClient.boundedRetryDelay(nil),
            OpenAIClient.defaultRetryAfterSeconds
        )
        XCTAssertEqual(OpenAIClient.defaultRetryAfterSeconds, 2.0,
                       "the long-standing 2-second fallback stays as-is")
    }

    func testNegativeRetryAfterClampsToZero() {
        // TimeInterval("-5") parses — the clamp is what keeps it from the
        // UInt64 nanosecond conversion.
        XCTAssertEqual(OpenAIClient.boundedRetryDelay(-5), 0)
    }

    func testMaxIsSmallEnoughToNotWedgeThePill() {
        XCTAssertLessThanOrEqual(OpenAIClient.maxRetryAfterSeconds, 30)
    }
}
