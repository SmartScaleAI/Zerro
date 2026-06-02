//
//  TrialManagerTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase B — unit coverage for the trial clock. `TrialManager` is two
//  Keychain reads plus arithmetic, so these are deterministic value-in/
//  value-out assertions: a FAKE keychain slot (in-memory) and an INJECTED
//  clock (a mutable `Date`) stand in for the real Keychain and wall clock,
//  exactly the way `ModeSwitchDetectorTests` injects a fixed pattern set.
//  Nothing here touches the real Keychain.
//
//  Covered:
//    • first launch establishes the start date (and the ceiling)
//    • a second call never resets it (idempotent)
//    • the day-boundary: just-under vs just-over 7×86 400
//    • rollback: a ceiling ahead of `now` keeps elapsed from shrinking
//    • far-forward `now` expires the trial
//    • genuine Keychain read failure fails OPEN (full trial, not expired)
//

import XCTest
@testable import Zerro

@MainActor
final class TrialManagerTests: XCTestCase {

    // MARK: - Fixture

    private let day: TimeInterval = 86_400
    /// A fixed anchor instant; tests advance a mutable `now` from here.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a manager over fresh in-memory slots with a controllable clock.
    /// Returns the slots too so tests can inspect/seed them directly.
    private func makeManager(
        now: Date
    ) -> (manager: TrialManager, start: InMemoryKeychainSlot, maxSeen: InMemoryKeychainSlot, setNow: (Date) -> Void) {
        let start = InMemoryKeychainSlot()
        let maxSeen = InMemoryKeychainSlot()
        var current = now
        let manager = TrialManager(
            startDateSlot: start,
            maxDateSeenSlot: maxSeen,
            clock: { current }
        )
        return (manager, start, maxSeen, { current = $0 })
    }

    /// Epoch-seconds string, matching `TrialManager`'s on-disk encoding.
    private func stamp(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    // MARK: - First launch

    func testFirstLaunchEstablishesStartAndCeiling() {
        let f = makeManager(now: t0)
        XCTAssertEqual(f.start.readResult(), .absent)

        f.manager.startTrialIfNeeded()

        XCTAssertEqual(f.start.readResult(), .found(stamp(t0)))
        XCTAssertEqual(f.maxSeen.readResult(), .found(stamp(t0)))
    }

    func testEvaluateOnFreshClockGrantsFullTrial() {
        let f = makeManager(now: t0)
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: TrialManager.trialLengthDays))
    }

    // MARK: - Idempotency (never resets)

    func testSecondStartDoesNotResetStartDate() {
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        // Time passes, then a relaunch calls startTrialIfNeeded again.
        f.setNow(t0.addingTimeInterval(3 * day))
        f.manager.startTrialIfNeeded()

        // Start date is unchanged — the original t0, not the later instant.
        XCTAssertEqual(f.start.readResult(), .found(stamp(t0)))
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: 4)) // 7 - 3
    }

    func testStartIsNotResetAcrossSeparateManagerInstances() {
        // Simulates uninstall/reinstall: the Keychain slots persist, a new
        // manager is constructed over them.
        let start = InMemoryKeychainSlot()
        let maxSeen = InMemoryKeychainSlot()

        var now = t0
        let first = TrialManager(startDateSlot: start, maxDateSeenSlot: maxSeen, clock: { now })
        first.startTrialIfNeeded()

        now = t0.addingTimeInterval(5 * day)
        let second = TrialManager(startDateSlot: start, maxDateSeenSlot: maxSeen, clock: { now })
        second.startTrialIfNeeded() // must be a no-op

        XCTAssertEqual(start.readResult(), .found(stamp(t0)))
        XCTAssertEqual(second.evaluate(), .active(daysRemaining: 2)) // 7 - 5, not reset to 7
    }

    // MARK: - Day-counting / boundary

    func testDayCountdownSequence() {
        // Pure math: no Keychain involved.
        XCTAssertEqual(TrialManager.status(forElapsed: 0), .active(daysRemaining: 7))
        XCTAssertEqual(TrialManager.status(forElapsed: day - 1), .active(daysRemaining: 7))
        XCTAssertEqual(TrialManager.status(forElapsed: day), .active(daysRemaining: 6))
        XCTAssertEqual(TrialManager.status(forElapsed: 6 * day), .active(daysRemaining: 1))
    }

    func testBoundaryJustUnderSevenDaysStillActive() {
        XCTAssertEqual(
            TrialManager.status(forElapsed: 7 * day - 1),
            .active(daysRemaining: 1),
            "One second before the 7-day mark must still read '1 day left', never expired."
        )
    }

    func testBoundaryExactlySevenDaysExpires() {
        XCTAssertEqual(
            TrialManager.status(forElapsed: 7 * day),
            .expired,
            "At exactly 7×86 400s the trial flips straight to expired — no '0 days left' recordable state."
        )
    }

    func testBoundaryJustOverSevenDaysExpires() {
        XCTAssertEqual(TrialManager.status(forElapsed: 7 * day + 1), .expired)
    }

    func testEvaluateAtBoundaryThroughKeychain() {
        // Same boundary, but driven end-to-end through the slots + clock.
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        f.setNow(t0.addingTimeInterval(7 * day - 1))
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: 1))

        f.setNow(t0.addingTimeInterval(7 * day))
        XCTAssertEqual(f.manager.evaluate(), .expired)
    }

    // MARK: - Rollback hardening

    func testClockRollbackDoesNotRewindTrial() {
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        // Advance 3 days and evaluate — this pins the ceiling at t0+3d.
        f.setNow(t0.addingTimeInterval(3 * day))
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: 4))

        // Now wind the system clock BACK to t0. Elapsed must not shrink:
        // effectiveNow = max(now, maxDateSeen) = t0+3d, still 4 days left.
        f.setNow(t0)
        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: 4),
            "Winding the clock back must not hand back trial days."
        )
    }

    func testCeilingAheadOfNowIsRespectedFromColdRead() {
        // maxDateSeen already 6 days ahead of the start (e.g. persisted from
        // an earlier session), but `now` is only at the start instant.
        let f = makeManager(now: t0)
        f.start.write(stamp(t0))
        f.maxSeen.write(stamp(t0.addingTimeInterval(6 * day)))

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: 1),
            "Elapsed is measured against the higher ceiling (6 days), not the rolled-back now."
        )
    }

    func testFarForwardNowExpiresAndPinsCeiling() {
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        // Jump far into the future → expired.
        f.setNow(t0.addingTimeInterval(30 * day))
        XCTAssertEqual(f.manager.evaluate(), .expired)

        // The ceiling is pinned at t0+30d, so even coming back to t0 stays expired.
        XCTAssertEqual(f.maxSeen.readResult(), .found(stamp(t0.addingTimeInterval(30 * day))))
        f.setNow(t0)
        XCTAssertEqual(f.manager.evaluate(), .expired)
    }

    // MARK: - Fail-open

    func testReadFailureFailsOpenWithFullTrial() {
        let f = makeManager(now: t0)
        f.start.write(stamp(t0.addingTimeInterval(-30 * day))) // would be expired if read succeeded
        f.start.simulateReadFailure = true

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: TrialManager.trialLengthDays),
            "A genuine Keychain read failure must grant the trial, never expire."
        )
    }

    func testStartIsNotInitializedOnReadFailure() {
        let f = makeManager(now: t0)
        f.start.simulateReadFailure = true

        // Must not write over a possibly-present-but-unreadable value.
        f.manager.startTrialIfNeeded()
        f.start.simulateReadFailure = false
        XCTAssertEqual(f.start.readResult(), .absent)
    }
}
