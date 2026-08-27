//
//  EntitlementEnforcementModeTests.swift
//  ZerroTests
//
//  The official-vs-community boundary (Phase 2B). Community builds must be
//  ungated by entitlement state; official mode enforces the license/trial
//  ladder. Both modes are exercised by INJECTION — this test binary is
//  compiled WITHOUT the OFFICIAL_BUILD condition, which is itself part of
//  what these tests pin down.
//

import XCTest
@testable import Zerro

@MainActor
final class EntitlementEnforcementModeTests: XCTestCase {

    // MARK: - Builders (mirroring PreflightGateTests)

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

    /// An elapsed trial clock over in-memory slots — the most adversarial
    /// setup: no license, trial over. Official mode computes
    /// `.localTrialExpired` from this; community mode must not care.
    private func expiredClock() -> TrialManager {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-Double(TrialManager.trialLengthDays + 1) * 86_400)
        return TrialManager(
            startDateSlot: InMemoryKeychainSlot(String(Int(start.timeIntervalSince1970))),
            maxDateSeenSlot: InMemoryKeychainSlot(),
            clock: { now }
        )
    }

    private func store(
        _ mode: EntitlementEnforcementMode,
        licensed: Bool = false,
        trialExpired: Bool = false
    ) -> EntitlementStore {
        EntitlementStore(
            enforcementMode: mode,
            licenseService: makeLicense(present: licensed),
            trialManager: trialExpired ? expiredClock() : nil
        )
    }

    // MARK: - Community: never blocked by entitlement state

    func testCommunityAllowsGenerationDespiteExpiredTrial() {
        let store = store(.community, trialExpired: true)
        XCTAssertTrue(store.canGenerate, "community must never be entitlement-blocked")
        XCTAssertEqual(store.state, .byok, "community pins the always-entitled local state")
    }

    func testCommunityAllowsGenerationWithNoLicenseAndNoTrial() {
        let store = store(.community)
        XCTAssertTrue(store.canGenerate)
    }

    func testCommunityRefreshKeepsEntitledStateDespiteAdversarialSources() {
        let store = store(.community, trialExpired: true)
        store.refresh()
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }

    func testCommunityUnaffectedByKeychainReadFailures() {
        // The official fail-closed license rules never touch community
        // builds: even with every license slot failing its read, a community
        // build stays entitled (it pins `.byok` before any license source is
        // consulted).
        let failingKey = InMemoryKeychainSlot("K")
        let failingInstance = InMemoryKeychainSlot("I")
        failingKey.simulateReadFailure = true
        failingInstance.simulateReadFailure = true
        let license = LicenseService(
            licenseKeySlot: failingKey,
            instanceIDSlot: failingInstance,
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            licensedProductIDSlot: InMemoryKeychainSlot(nil),
            licensedMajorSlot: InMemoryKeychainSlot(nil),
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: OfflineLicenseTransport()
        )
        let store = EntitlementStore(enforcementMode: .community, licenseService: license)
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
        store.refresh()
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }

    func testCommunityStaysEntitledWithALicenseOnFile() {
        // A license record in the Keychain changes nothing for community.
        let store = store(.community, licensed: true)
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }

    // MARK: - Official: the license/trial ladder is enforced

    func testOfficialExpiredTrialBlocks() {
        let store = store(.official, trialExpired: true)
        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    func testOfficialLicenseGrants() {
        let store = store(.official, licensed: true)
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }

    func testOfficialWithoutAClockOrLicenseIsGated() {
        // No clock injected and no license: a missing clock never grants.
        let store = store(.official)
        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - Mode selection is injectable, independent of build config

    func testEnforcementIsInjectableRegardlessOfCompiledConditions() {
        // This test binary is a plain source build: no OFFICIAL_BUILD.
        XCTAssertFalse(Build.isOfficialBuild, "test binaries are community-compiled")
        XCTAssertEqual(EntitlementEnforcementMode.productionDefault, .community)
        // Yet an injected .official store enforces, and an injected .community
        // store does not — the mode is the seam, not the compile flag.
        XCTAssertFalse(store(.official, trialExpired: true).canGenerate)
        XCTAssertTrue(store(.community, trialExpired: true).canGenerate)
    }

    func testProductionDefaultDerivesFromBuildFlag() {
        let expected: EntitlementEnforcementMode = Build.isOfficialBuild ? .official : .community
        XCTAssertEqual(EntitlementEnforcementMode.productionDefault, expected)
    }
}
