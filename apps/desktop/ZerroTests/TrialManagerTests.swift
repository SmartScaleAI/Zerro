//
//  TrialManagerTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/1/26.
//
//  Unit coverage for the local trial clock. `TrialManager` is two Keychain
//  reads plus arithmetic, so these are deterministic value-in/value-out
//  assertions: a FAKE keychain slot (in-memory) and an INJECTED clock (a
//  mutable `Date`) stand in for the real Keychain and wall clock. Nothing
//  here touches the real Keychain.
//
//  Covered:
//    • first launch establishes the start date (and the ceiling)
//    • a second call — and a separate manager over the same slots — never
//      resets it (idempotent; reinstall persistence)
//    • the full whole-day countdown and the exact day boundary: one second
//      under, exactly at, and one second over trialLengthDays × 86 400
//    • rollback: a ceiling ahead of `now` keeps elapsed from shrinking
//    • far-forward `now` expires the trial and STAYS expired after rollback
//    • malformed stored data fails OPEN and is never overwritten
//    • genuine Keychain read failure fails OPEN (full trial, not expired)
//      and never initializes over a possibly-present value
//    • the production slots use the device-only protection class
//    • the in-memory preview factory works over its own fake slots
//

import XCTest
@testable import Zerro

@MainActor
final class TrialManagerTests: XCTestCase {

    // MARK: - Fixture

    private let day: TimeInterval = 86_400
    private let length = TrialManager.trialLengthDays
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

    // MARK: - Trial length

    func testTrialLengthIsFourteenDays() {
        XCTAssertEqual(TrialManager.trialLengthDays, 14)
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
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: length))
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
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: length - 3))
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
        XCTAssertEqual(second.evaluate(), .active(daysRemaining: length - 5))
    }

    // MARK: - Day-counting / boundary

    func testFullDayCountdownSequence() {
        // Pure math: every whole-day block over the full trial length.
        for elapsedDays in 0..<length {
            XCTAssertEqual(
                TrialManager.status(forElapsed: TimeInterval(elapsedDays) * day),
                .active(daysRemaining: length - elapsedDays),
                "Day \(elapsedDays) must read \(length - elapsedDays) days remaining"
            )
            XCTAssertEqual(
                TrialManager.status(forElapsed: TimeInterval(elapsedDays) * day + (day - 1)),
                .active(daysRemaining: length - elapsedDays),
                "The last second of day \(elapsedDays) still reads \(length - elapsedDays) remaining"
            )
        }
    }

    func testBoundaryOneSecondUnderStillActive() {
        XCTAssertEqual(
            TrialManager.status(forElapsed: TimeInterval(length) * day - 1),
            .active(daysRemaining: 1),
            "One second before the boundary must still read '1 day left', never expired."
        )
    }

    func testBoundaryExactlyAtLengthExpires() {
        XCTAssertEqual(
            TrialManager.status(forElapsed: TimeInterval(length) * day),
            .expired,
            "At exactly trialLengthDays × 86 400s the trial flips straight to expired — no '0 days left' recordable state."
        )
    }

    func testBoundaryOneSecondOverStaysExpired() {
        XCTAssertEqual(TrialManager.status(forElapsed: TimeInterval(length) * day + 1), .expired)
    }

    func testEvaluateAtBoundaryThroughKeychain() {
        // Same boundary, but driven end-to-end through the slots + clock.
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        f.setNow(t0.addingTimeInterval(TimeInterval(length) * day - 1))
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: 1))

        f.setNow(t0.addingTimeInterval(TimeInterval(length) * day))
        XCTAssertEqual(f.manager.evaluate(), .expired)
    }

    // MARK: - Rollback hardening

    func testClockRollbackDoesNotRewindTrial() {
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        // Advance 3 days and evaluate — this pins the ceiling at t0+3d.
        f.setNow(t0.addingTimeInterval(3 * day))
        XCTAssertEqual(f.manager.evaluate(), .active(daysRemaining: length - 3))

        // Now wind the system clock BACK to t0. Elapsed must not shrink:
        // effectiveNow = max(now, maxDateSeen) = t0+3d.
        f.setNow(t0)
        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: length - 3),
            "Winding the clock back must not hand back trial days."
        )
    }

    func testCeilingAheadOfNowIsRespectedFromColdRead() {
        // maxDateSeen already 13 days ahead of the start (e.g. persisted from
        // an earlier session), but `now` is only at the start instant.
        let f = makeManager(now: t0)
        f.start.write(stamp(t0))
        f.maxSeen.write(stamp(t0.addingTimeInterval(TimeInterval(length - 1) * day)))

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: 1),
            "Elapsed is measured against the higher stored ceiling, not the rolled-back now."
        )
    }

    func testFarForwardNowExpiresAndPinsCeiling() {
        let f = makeManager(now: t0)
        f.manager.startTrialIfNeeded()

        // Jump far into the future → expired.
        f.setNow(t0.addingTimeInterval(60 * day))
        XCTAssertEqual(f.manager.evaluate(), .expired)

        // The ceiling is pinned, so even coming back to t0 stays expired.
        XCTAssertEqual(f.maxSeen.readResult(), .found(stamp(t0.addingTimeInterval(60 * day))))
        f.setNow(t0)
        XCTAssertEqual(f.manager.evaluate(), .expired)
    }

    // MARK: - Malformed data

    func testMalformedStartDateFailsOpenAndIsNotOverwritten() {
        let f = makeManager(now: t0)
        f.start.write("not-an-epoch")

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: length),
            "A present-but-unparseable start date is corruption — fail open with the full trial."
        )
        // The corrupted value must not be clobbered by a re-initialization.
        XCTAssertEqual(f.start.readResult(), .found("not-an-epoch"))
    }

    func testMaxDateSeenReadFailureFailsOpenAndIsNotOverwritten() {
        let f = makeManager(now: t0.addingTimeInterval(5 * day))
        f.start.write(stamp(t0)) // 5 days in — would be active(length−5) normally
        f.maxSeen.write(stamp(t0.addingTimeInterval(4 * day)))
        f.maxSeen.simulateReadFailure = true

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: length),
            "A genuine maxDateSeen read failure must fail open with the full trial."
        )
        // The possibly-present ceiling must not be clobbered.
        f.maxSeen.simulateReadFailure = false
        XCTAssertEqual(f.maxSeen.readResult(), .found(stamp(t0.addingTimeInterval(4 * day))))
    }

    func testMalformedMaxDateSeenFailsOpenAndIsNotOverwritten() {
        let f = makeManager(now: t0.addingTimeInterval(5 * day))
        f.start.write(stamp(t0))
        f.maxSeen.write("not-an-epoch")

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: length),
            "A corrupted ceiling is unreadable truth — fail open, don't guess."
        )
        XCTAssertEqual(f.maxSeen.readResult(), .found("not-an-epoch"))
    }

    // MARK: - Fail-open (genuine read failure)

    func testReadFailureFailsOpenWithFullTrial() {
        let f = makeManager(now: t0)
        f.start.write(stamp(t0.addingTimeInterval(-60 * day))) // would be expired if read succeeded
        f.start.simulateReadFailure = true

        XCTAssertEqual(
            f.manager.evaluate(),
            .active(daysRemaining: length),
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

    // MARK: - Production slot configuration

    func testProductionSlotsUseDeviceOnlyProtectionClass() {
        XCTAssertEqual(
            KeychainStore.trialStartDate.accessible as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "The trial clock must not ride backups or Migration Assistant."
        )
        XCTAssertEqual(
            KeychainStore.trialMaxDateSeen.accessible as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(KeychainStore.trialStartDate.account, "trial_start_date")
        XCTAssertEqual(KeychainStore.trialMaxDateSeen.account, "trial_max_date_seen")
    }

    // MARK: - Preview factory

    func testInMemoryFactoryNeverNeedsTheRealKeychain() {
        // The factory builds over its own fresh in-memory slots (its API takes
        // no real slot), so previews/tests can evaluate freely.
        XCTAssertEqual(
            TrialManager.inMemory(startedDaysAgo: 0).evaluate(),
            .active(daysRemaining: length)
        )
        XCTAssertEqual(
            TrialManager.inMemory(startedDaysAgo: 3).evaluate(),
            .active(daysRemaining: length - 3)
        )
        XCTAssertEqual(
            TrialManager.inMemory(startedDaysAgo: length).evaluate(),
            .expired
        )
    }
}
