//
//  UpdateWindowPolicyTests.swift
//  ZerroTests
//
//  E7 / Appendix F — the BYOK update-window appcast filter. `SUAppcastItem`
//  isn't constructible in tests, so the Sparkle delegate is a thin adapter
//  and the whole decision is exercised here through the pure
//  `UpdateWindowPolicy.decide` over plain `Candidate`s: a fake appcast with
//  items straddling the window, plus every fail-open path (no window, not
//  BYOK, missing/garbage persisted date, undated item).
//

import XCTest
@testable import Zerro

final class UpdateWindowPolicyTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed "purchase" instant and its window end, so the straddle
    /// fixtures read as offsets from the boundary.
    private let windowEnd = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(daysFromWindowEnd days: Double, version: String) -> UpdateWindowPolicy.Candidate {
        UpdateWindowPolicy.Candidate(
            date: windowEnd.addingTimeInterval(days * 24 * 60 * 60),
            version: version
        )
    }

    // MARK: - decide: fail-open / defer paths

    func testNilWindowEndDefersToSparkle() {
        // No enforceable window (not BYOK, or no persisted start) → never
        // interfere with Sparkle's own pick.
        let items = [candidate(daysFromWindowEnd: 10, version: "90")]
        XCTAssertEqual(UpdateWindowPolicy.decide(candidates: items, windowEnd: nil), .deferToSparkle)
    }

    func testAllItemsInWindowDefersToSparkle() {
        let items = [
            candidate(daysFromWindowEnd: -300, version: "85"),
            candidate(daysFromWindowEnd: -30, version: "87"),
        ]
        XCTAssertEqual(UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd), .deferToSparkle)
    }

    func testEmptyAppcastDefersToSparkle() {
        XCTAssertEqual(UpdateWindowPolicy.decide(candidates: [], windowEnd: windowEnd), .deferToSparkle)
    }

    // MARK: - decide: the straddle (the core E7 case)

    func testStraddlingAppcastPicksBestInWindowItem() {
        // Items published before AND after the window end: the newest build
        // (90) is out of window, so the user is offered the best in-window
        // one (87) — older in-window builds stay reachable, the lapsed one
        // never appears.
        let items = [
            candidate(daysFromWindowEnd: -300, version: "85"),
            candidate(daysFromWindowEnd: -30, version: "87"),
            candidate(daysFromWindowEnd: 10, version: "90"),
        ]
        XCTAssertEqual(
            UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd),
            .bestInWindow(index: 1)
        )
    }

    func testStraddlePickIsOrderIndependent() {
        // Appcasts aren't guaranteed sorted — the pick must be by version,
        // not position.
        let items = [
            candidate(daysFromWindowEnd: 10, version: "90"),
            candidate(daysFromWindowEnd: -300, version: "85"),
            candidate(daysFromWindowEnd: -30, version: "87"),
        ]
        XCTAssertEqual(
            UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd),
            .bestInWindow(index: 2)
        )
    }

    func testVersionComparisonIsNumericNotLexicographic() {
        // "9" vs "10": lexicographic ordering would pick "9". Sparkle's
        // comparator must rank 10 higher.
        let items = [
            candidate(daysFromWindowEnd: -60, version: "9"),
            candidate(daysFromWindowEnd: -30, version: "10"),
            candidate(daysFromWindowEnd: 10, version: "11"),
        ]
        XCTAssertEqual(
            UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd),
            .bestInWindow(index: 1)
        )
    }

    func testItemExactlyAtWindowEndIsInWindow() {
        // Boundary: pubDate == window end counts as in-window (≤).
        let items = [
            UpdateWindowPolicy.Candidate(date: windowEnd, version: "88"),
            candidate(daysFromWindowEnd: 10, version: "90"),
        ]
        XCTAssertEqual(
            UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd),
            .bestInWindow(index: 0)
        )
    }

    func testUndatedItemFailsOpenAsInWindow() {
        // A malformed feed item with no <pubDate> can't be window-checked —
        // per-item fail-open, so it stays offerable.
        let items = [
            UpdateWindowPolicy.Candidate(date: nil, version: "88"),
            candidate(daysFromWindowEnd: 10, version: "90"),
        ]
        XCTAssertEqual(
            UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd),
            .bestInWindow(index: 0)
        )
    }

    // MARK: - decide: everything out of window

    func testAllItemsOutOfWindowReportsNoUpdate() {
        // Silent filtering (F.0): nothing publishable → "you're up to date",
        // never a refusal dialog.
        let items = [
            candidate(daysFromWindowEnd: 10, version: "90"),
            candidate(daysFromWindowEnd: 40, version: "91"),
        ]
        XCTAssertEqual(UpdateWindowPolicy.decide(candidates: items, windowEnd: windowEnd), .noUpdate)
    }

    // MARK: - currentWindowEnd: BYOK-only scoping + fail-open reads

    private let createdAtEpoch = "1768478400" // 2026-01-15T12:00:00Z

    func testWindowOnlyEnforcedForExplicitByokKind() {
        let createdAt = InMemoryKeychainSlot(createdAtEpoch)

        // Explicit BYOK → enforced window = created_at + 1 year.
        let byokEnd = UpdateWindowPolicy.currentWindowEnd(
            kindSlot: InMemoryKeychainSlot(LicenseProductKind.byok.rawValue),
            createdAtSlot: createdAt
        )
        XCTAssertEqual(
            byokEnd,
            LicenseService.updateWindowEnd(createdAt: Date(timeIntervalSince1970: 1_768_478_400))
        )

        // Managed subscribers must NEVER be filtered, even with a date on file.
        XCTAssertNil(UpdateWindowPolicy.currentWindowEnd(
            kindSlot: InMemoryKeychainSlot(LicenseProductKind.managed.rawValue),
            createdAtSlot: createdAt
        ))

        // Unresolved kind (absent slot) → fail-open, no filtering.
        XCTAssertNil(UpdateWindowPolicy.currentWindowEnd(
            kindSlot: InMemoryKeychainSlot(nil),
            createdAtSlot: createdAt
        ))
    }

    func testMissingOrGarbageCreatedAtFailsOpen() {
        let byokKind = InMemoryKeychainSlot(LicenseProductKind.byok.rawValue)

        // No persisted window start (pre-E7 license) → nil → updates flow.
        XCTAssertNil(UpdateWindowPolicy.currentWindowEnd(
            kindSlot: byokKind,
            createdAtSlot: InMemoryKeychainSlot(nil)
        ))

        // Unparseable slot content → nil, never a throw or a block.
        XCTAssertNil(UpdateWindowPolicy.currentWindowEnd(
            kindSlot: byokKind,
            createdAtSlot: InMemoryKeychainSlot("garbage")
        ))

        // A genuine Keychain read failure → nil (fail-open).
        let failing = InMemoryKeychainSlot(createdAtEpoch)
        failing.simulateReadFailure = true
        XCTAssertNil(UpdateWindowPolicy.currentWindowEnd(
            kindSlot: byokKind,
            createdAtSlot: failing
        ))
    }
}
