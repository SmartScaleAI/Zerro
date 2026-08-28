//
//  UpdateMajorPolicyTests.swift
//  ZerroTests
//
//  The major-version appcast filter. `SUAppcastItem` isn't constructible in
//  tests, so the Sparkle delegate is a thin adapter and the whole decision
//  is exercised here through the pure `UpdateMajorPolicy.decide` over plain
//  `Candidate`s: every release of the running major is offerable, a future
//  major is never auto-offered, and malformed data fails SAFE (nothing
//  unverifiable is ever offered).
//

import XCTest
@testable import Zerro

final class UpdateMajorPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func candidate(_ version: String, marketing: String?) -> UpdateMajorPolicy.Candidate {
        UpdateMajorPolicy.Candidate(version: version, marketingVersion: marketing)
    }

    // MARK: - major(ofMarketingVersion:)

    func testMajorParsing() {
        XCTAssertEqual(UpdateMajorPolicy.major(ofMarketingVersion: "1.4.33"), 1)
        XCTAssertEqual(UpdateMajorPolicy.major(ofMarketingVersion: "2.0.0"), 2)
        XCTAssertEqual(UpdateMajorPolicy.major(ofMarketingVersion: "10.1"), 10)
        XCTAssertEqual(UpdateMajorPolicy.major(ofMarketingVersion: "3"), 3)
        XCTAssertNil(UpdateMajorPolicy.major(ofMarketingVersion: nil))
        XCTAssertNil(UpdateMajorPolicy.major(ofMarketingVersion: ""))
        XCTAssertNil(UpdateMajorPolicy.major(ofMarketingVersion: "v1.4.33"))
        XCTAssertNil(UpdateMajorPolicy.major(ofMarketingVersion: "beta.2"))
        XCTAssertNil(UpdateMajorPolicy.major(ofMarketingVersion: ".4.33"))
        XCTAssertNil(UpdateMajorPolicy.major(ofMarketingVersion: "-1.0"))
    }

    // MARK: - decide: defer paths

    func testAllItemsOnAllowedMajorDefersToSparkle() {
        let items = [
            candidate("85", marketing: "1.4.20"),
            candidate("87", marketing: "1.4.22"),
        ]
        XCTAssertEqual(UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1), .deferToSparkle)
    }

    func testEmptyAppcastDefersToSparkle() {
        XCTAssertEqual(UpdateMajorPolicy.decide(candidates: [], allowedMajor: 1), .deferToSparkle)
    }

    // MARK: - decide: the major straddle (the core case)

    func testFutureMajorIsFilteredToBestAllowedItem() {
        // A 2.0 release lands in the feed: a 1.x install must be offered the
        // best remaining 1.x build (87), never the 2.x one.
        let items = [
            candidate("85", marketing: "1.4.20"),
            candidate("87", marketing: "1.4.22"),
            candidate("90", marketing: "2.0.0"),
        ]
        XCTAssertEqual(
            UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1),
            .bestAllowed(index: 1)
        )
    }

    func testStraddlePickIsOrderIndependent() {
        // Appcasts aren't guaranteed sorted — the pick must be by version,
        // not position.
        let items = [
            candidate("90", marketing: "2.0.0"),
            candidate("85", marketing: "1.4.20"),
            candidate("87", marketing: "1.4.22"),
        ]
        XCTAssertEqual(
            UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1),
            .bestAllowed(index: 2)
        )
    }

    func testVersionComparisonIsNumericNotLexicographic() {
        // "9" vs "10": lexicographic ordering would pick "9". Sparkle's
        // comparator must rank 10 higher.
        let items = [
            candidate("9", marketing: "1.4.9"),
            candidate("10", marketing: "1.4.10"),
            candidate("11", marketing: "2.0.0"),
        ]
        XCTAssertEqual(
            UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1),
            .bestAllowed(index: 1)
        )
    }

    func testMajorTwoBuildIsOfferedMajorTwoItems() {
        // The boundary is symmetric: a 2.x install offers 2.x and filters 1.x.
        let items = [
            candidate("87", marketing: "1.4.22"),
            candidate("90", marketing: "2.0.0"),
            candidate("92", marketing: "2.0.2"),
        ]
        XCTAssertEqual(
            UpdateMajorPolicy.decide(candidates: items, allowedMajor: 2),
            .bestAllowed(index: 2)
        )
    }

    // MARK: - decide: nothing allowed

    func testOnlyFutureMajorItemsReportsNoUpdate() {
        // Silent filtering: nothing offerable → "you're up to date", never a
        // refusal or upsell dialog.
        let items = [
            candidate("90", marketing: "2.0.0"),
            candidate("91", marketing: "2.0.1"),
        ]
        XCTAssertEqual(UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1), .noUpdate)
    }

    // MARK: - decide: fail-safe on malformed data

    func testItemWithUnparseableMarketingVersionIsNeverOffered() {
        // An item whose major can't be verified must not be offered — the
        // safe failure is skipping it, not auto-installing an unknown major.
        let items = [
            candidate("88", marketing: "not-a-version"),
            candidate("87", marketing: "1.4.22"),
        ]
        XCTAssertEqual(
            UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1),
            .bestAllowed(index: 1)
        )
    }

    func testItemWithMissingMarketingVersionIsNeverOffered() {
        let items = [
            candidate("88", marketing: nil),
            candidate("90", marketing: "2.0.0"),
        ]
        XCTAssertEqual(UpdateMajorPolicy.decide(candidates: items, allowedMajor: 1), .noUpdate)
    }

    func testUnknownInstalledMajorOffersNothing() {
        // If the running install's own major can't be determined, filtering
        // is impossible — offer NOTHING rather than risk a wrong-major
        // auto-install.
        let items = [candidate("87", marketing: "1.4.22")]
        XCTAssertEqual(UpdateMajorPolicy.decide(candidates: items, allowedMajor: nil), .noUpdate)
    }

    // MARK: - installedMajor

    func testInstalledMajorReadsTheHostBundle() {
        // The test host is the real Zerro.app, whose marketing version is a
        // 1.x.x string — the parsed major must be 1.
        XCTAssertEqual(UpdateMajorPolicy.installedMajor(), 1)
    }
}
