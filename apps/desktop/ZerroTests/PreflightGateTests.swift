//
//  PreflightGateTests.swift
//  ZerroTests
//
//  The record-start PRE-FLIGHT gate: catch every knowable failure BEFORE the
//  user records, not after a wasted capture. Covers
//  `EntitlementStore.preflightBlock(canGenerateLocally:)`, the single
//  synchronous, local, fail-open decision the `handleHotkey` gate consults
//  between the `canGenerate` gate and presenting the area selector.
//
//  Contract:
//    • Granting state + no self-funding setup → .apiKeyMissing
//    • Granting state + a usable setup        → nil (no false blocks)
//    • Expired trial                          → nil (the `canGenerate` gate's job)
//
//  All dependencies are in-memory; no Keychain, no network.
//

import XCTest
@testable import Zerro

@MainActor
final class PreflightGateTests: XCTestCase {

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

    /// A trial clock over in-memory slots, either freshly started (active)
    /// or elapsed.
    private func makeClock(expired: Bool) -> TrialManager {
        let now = Date()
        let start = expired ? now.addingTimeInterval(-Double(TrialManager.trialLengthDays + 1) * 86_400) : now
        return TrialManager(
            startDateSlot: InMemoryKeychainSlot(String(Int(start.timeIntervalSince1970))),
            maxDateSeenSlot: InMemoryKeychainSlot(),
            clock: { now }
        )
    }

    private func licensedStore() -> EntitlementStore {
        EntitlementStore(enforcementMode: .official, licenseService: makeLicense(present: true))
    }

    private func trialStore(expired: Bool = false) -> EntitlementStore {
        EntitlementStore(
            enforcementMode: .official,
            licenseService: makeLicense(present: false),
            trialManager: makeClock(expired: expired)
        )
    }

    // MARK: - Licensed: missing self-funding setup

    func testLicensedWithoutKeyBlocksApiKeyMissing() {
        let store = licensedStore()
        XCTAssertEqual(store.state, .byok)
        XCTAssertEqual(store.preflightBlock(canGenerateLocally: false), .apiKeyMissing)
    }

    func testLicensedWithKeyDoesNotBlock() {
        let store = licensedStore()
        XCTAssertNil(store.preflightBlock(canGenerateLocally: true))
    }

    // MARK: - Trial

    func testActiveTrialWithoutKeyBlocksApiKeyMissing() {
        // The trial runs on the user's own keys, so a missing setup is caught
        // before a wasted capture — same as a licensed user.
        let store = trialStore()
        guard case .localTrial = store.state else { return XCTFail("expected .localTrial") }
        XCTAssertEqual(store.preflightBlock(canGenerateLocally: false), .apiKeyMissing)
    }

    func testActiveTrialWithKeyDoesNotBlock() {
        let store = trialStore()
        XCTAssertNil(store.preflightBlock(canGenerateLocally: true))
    }

    func testExpiredTrialIsHandledByCanGenerateNotPreflight() {
        // Trial elapsed → `.localTrialExpired`; the `canGenerate` gate (not
        // pre-flight) routes it to the paywall, so pre-flight returns nil.
        let store = trialStore(expired: true)
        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.preflightBlock(canGenerateLocally: false))
    }

    // MARK: - The gate trusts the caller-resolved capability

    func testGateHonorsReportedCapability() {
        // `preflightBlock` is a PURE function of the caller-supplied
        // `canGenerateLocally` — it never re-reads the Keychain/disk itself
        // (that resolution lives in `AppState.canGenerateLocally`). A user the
        // caller reports as self-funding-capable records, full stop.
        let store = licensedStore()
        XCTAssertNil(store.preflightBlock(canGenerateLocally: true))
    }

    // MARK: - Community

    func testCommunityNeverBlocksOnEntitlementButStillPreflightsSetup() {
        let store = EntitlementStore(enforcementMode: .community, licenseService: makeLicense(present: false))
        XCTAssertTrue(store.canGenerate)
        // A missing key is a setup problem, not an entitlement one — the
        // pre-flight still surfaces it so the user is pointed at Settings.
        XCTAssertEqual(store.preflightBlock(canGenerateLocally: false), .apiKeyMissing)
        XCTAssertNil(store.preflightBlock(canGenerateLocally: true))
    }
}
