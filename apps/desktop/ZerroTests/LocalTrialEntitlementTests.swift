//
//  LocalTrialEntitlementTests.swift
//  ZerroTests
//
//  The local trial clock integrated through `EntitlementStore`, in both
//  enforcement modes:
//
//  Community mode must be completely inert toward the clock — never a read,
//  never a write, never an entitlement consequence (pinned `.byok`,
//  generation allowed) even over an expired clock.
//
//  Official mode derives `.localTrial(daysRemaining:)` / `.localTrialExpired`
//  from the clock whenever no license outranks it: a fresh install starts at
//  the full length, `refresh()` re-evaluates across the exact expiry
//  boundary, an active trial grants while still requiring a provider-key
//  setup via the preflight check, an expired trial blocks, a valid license
//  outranks an expired
//  clock, and clearing the license (the deactivation path) drops back to
//  whatever the clock currently says.
//

import XCTest
@testable import Zerro

/// A `KeychainSlot` that records every access, so tests can prove a code
/// path NEVER touched the trial clock's storage (community mode).
private final class SpyKeychainSlot: KeychainSlot {
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var deletes = 0
    private var value: String?

    init(_ initialValue: String? = nil) { self.value = initialValue }

    func readResult() -> KeychainReadResult {
        reads += 1
        if let value { return .found(value) }
        return .absent
    }

    func write(_ value: String) {
        writes += 1
        self.value = value
    }

    func delete() {
        deletes += 1
        value = nil
    }

    var wasNeverTouched: Bool { reads == 0 && writes == 0 && deletes == 0 }
}

@MainActor
final class LocalTrialEntitlementTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let length = TrialManager.trialLengthDays
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Builders

    private func makeLicense(present: Bool) -> LicenseService {
        LicenseService(
            licenseKeySlot: InMemoryKeychainSlot(present ? "KEY" : nil),
            instanceIDSlot: InMemoryKeychainSlot(present ? "instance" : nil),
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            licensedProductIDSlot: InMemoryKeychainSlot(present ? "7" : nil),
            licensedMajorSlot: InMemoryKeychainSlot(present ? "1" : nil),
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: OfflineLicenseTransport()
        )
    }

    /// A trial clock over in-memory slots, `startedDaysAgo` days in, with a
    /// controllable `now`.
    private func makeClock(
        startedDaysAgo: Int,
        now: Date? = nil
    ) -> (manager: TrialManager, setNow: (Date) -> Void) {
        let anchor = now ?? t0
        var current = anchor
        let start = InMemoryKeychainSlot(String(Int(anchor.addingTimeInterval(-TimeInterval(startedDaysAgo) * day).timeIntervalSince1970)))
        let maxSeen = InMemoryKeychainSlot()
        let manager = TrialManager(startDateSlot: start, maxDateSeenSlot: maxSeen, clock: { current })
        return (manager, { current = $0 })
    }

    private func makeStore(
        _ mode: EntitlementEnforcementMode,
        licensed: Bool = false,
        trialManager: TrialManager?
    ) -> (store: EntitlementStore, license: LicenseService) {
        let license = makeLicense(present: licensed)
        let store = EntitlementStore(enforcementMode: mode,
            licenseService: license,
            trialManager: trialManager
        )
        return (store, license)
    }

    // MARK: - Community mode: the clock is never touched

    func testCommunityNeverReadsOrWritesTheTrialClock() {
        let start = SpyKeychainSlot()
        let maxSeen = SpyKeychainSlot()
        let clock = TrialManager(startDateSlot: start, maxDateSeenSlot: maxSeen, clock: { self.t0 })

        let (store, _) = makeStore(.community, trialManager: clock)
        _ = store.canGenerate
        _ = store.preflightBlock(canGenerateLocally: false)
        store.refresh()

        XCTAssertTrue(start.wasNeverTouched, "community mode must never touch trialStartDate")
        XCTAssertTrue(maxSeen.wasNeverTouched, "community mode must never touch trialMaxDateSeen")
    }

    func testCommunityStaysEntitledOverAnExpiredClock() {
        let (clock, _) = makeClock(startedDaysAgo: length + 10)
        let (store, _) = makeStore(.community, trialManager: clock)

        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
        store.refresh()
        XCTAssertEqual(store.state, .byok)
    }

    // MARK: - Official mode: fresh install

    func testOfficialFreshInstallStartsFullLocalTrial() {
        // Truly empty slots: init must establish the clock and read the full
        // length back.
        let clock = TrialManager(
            startDateSlot: InMemoryKeychainSlot(),
            maxDateSeenSlot: InMemoryKeychainSlot(),
            clock: { self.t0 }
        )
        let (store, _) = makeStore(.official, trialManager: clock)

        XCTAssertEqual(store.state, .localTrial(daysRemaining: length))
        XCTAssertTrue(store.canGenerate)
    }

    func testOfficialActiveTrialGrantsOnOwnKeys() {
        let (clock, _) = makeClock(startedDaysAgo: 2)
        let (store, _) = makeStore(.official, trialManager: clock)

        XCTAssertEqual(store.state, .localTrial(daysRemaining: length - 2))
        XCTAssertTrue(store.canGenerate)
        XCTAssertTrue(store.state.usesOwnProviderKeys)
    }

    func testOfficialActiveTrialStillRequiresProviderKeySetup() {
        let (clock, _) = makeClock(startedDaysAgo: 0)
        let (store, _) = makeStore(.official, trialManager: clock)

        // Entitled, but with no usable provider-key/transcription setup the
        // preflight check routes the user to fix it before recording.
        XCTAssertEqual(store.preflightBlock(canGenerateLocally: false), .apiKeyMissing)
        XCTAssertNil(store.preflightBlock(canGenerateLocally: true))
    }

    // MARK: - Official mode: expiry

    func testOfficialExpiredTrialBlocks() {
        let (clock, _) = makeClock(startedDaysAgo: length)
        let (store, _) = makeStore(.official, trialManager: clock)

        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    func testRefreshCrossesTheExactExpiryBoundary() {
        let (clock, setNow) = makeClock(startedDaysAgo: 0)
        let (store, _) = makeStore(.official, trialManager: clock)
        XCTAssertEqual(store.state, .localTrial(daysRemaining: length))

        setNow(t0.addingTimeInterval(TimeInterval(length) * day - 1))
        store.refresh()
        XCTAssertEqual(store.state, .localTrial(daysRemaining: 1), "one second before the boundary is still active")

        setNow(t0.addingTimeInterval(TimeInterval(length) * day))
        store.refresh()
        XCTAssertEqual(store.state, .localTrialExpired, "exactly at the boundary expires")
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - Official mode: license precedence

    func testValidLicenseOutranksExpiredTrial() {
        let (clock, _) = makeClock(startedDaysAgo: length + 5)
        let (store, _) = makeStore(.official, licensed: true, trialManager: clock)

        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }

    func testClearingTheLicenseReturnsToTheCurrentTrialState() {
        // Active clock: deactivation drops back to the live countdown.
        let (activeClock, _) = makeClock(startedDaysAgo: 4)
        let (activeStore, activeLicense) = makeStore(.official, licensed: true, trialManager: activeClock)
        XCTAssertEqual(activeStore.state, .byok)

        activeLicense.clearLicense()
        activeStore.refresh()
        XCTAssertEqual(activeStore.state, .localTrial(daysRemaining: length - 4))

        // Expired clock: deactivation lands on the gate, not a fresh trial.
        let (expiredClock, _) = makeClock(startedDaysAgo: length + 1)
        let (expiredStore, expiredLicense) = makeStore(.official, licensed: true, trialManager: expiredClock)
        XCTAssertEqual(expiredStore.state, .byok)

        expiredLicense.clearLicense()
        expiredStore.refresh()
        XCTAssertEqual(expiredStore.state, .localTrialExpired)
    }

    // MARK: - Mode injection stays compile-flag independent

    func testTrialEnforcementInjectsIndependentlyOfBuildFlags() {
        XCTAssertFalse(Build.isOfficialBuild, "test binaries are community-compiled")
        let (expiredClock, _) = makeClock(startedDaysAgo: length + 1)
        XCTAssertFalse(makeStore(.official, trialManager: expiredClock).store.canGenerate)
        let (expiredClock2, _) = makeClock(startedDaysAgo: length + 1)
        XCTAssertTrue(makeStore(.community, trialManager: expiredClock2).store.canGenerate)
    }
}
