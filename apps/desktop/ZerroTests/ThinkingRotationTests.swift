//
//  ThinkingRotationTests.swift
//  ZerroTests
//
//  The generation-stage pill cycles witty "thinking" sayings instead of a
//  static label. `AppState.nextContinuation(avoiding:)` is the picker that
//  keeps the rotation from showing the same phrase twice in a row. These
//  tests pin its invariants:
//    • it never returns the phrase it was told to avoid;
//    • every non-nil result is a real member of the continuation pool;
//    • avoiding nil never blocks a pick (the first rotation step works).
//

import XCTest
@testable import Zerro

@MainActor
final class ThinkingRotationTests: XCTestCase {

    private let pool = ProcessingPipeline.thinkingContinuations
    private let iterations = 1_000

    // MARK: - Never repeats the avoided phrase

    func testNeverReturnsAvoidedPhrase() {
        for phrase in pool {
            for _ in 0..<iterations {
                let next = AppState.nextContinuation(avoiding: phrase)
                XCTAssertNotEqual(next, phrase, "rotation returned the phrase it was told to avoid: \(phrase)")
            }
        }
    }

    // MARK: - Always a valid pool member

    func testResultIsAlwaysFromPool() {
        for phrase in pool {
            for _ in 0..<iterations {
                guard let next = AppState.nextContinuation(avoiding: phrase) else {
                    XCTFail("rotation returned nil for a non-empty pool")
                    return
                }
                XCTAssertTrue(pool.contains(next), "rotation returned a phrase outside the pool: \(next)")
            }
        }
    }

    // MARK: - Avoiding nil never blocks a pick

    func testAvoidingNilReturnsValidMember() {
        for _ in 0..<iterations {
            guard let next = AppState.nextContinuation(avoiding: nil) else {
                XCTFail("rotation returned nil when avoiding nil")
                return
            }
            XCTAssertTrue(pool.contains(next), "rotation returned a phrase outside the pool: \(next)")
        }
    }
}
