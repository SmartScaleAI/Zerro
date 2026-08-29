//
//  CommunityLicensingPolicyTests.swift
//  ZerroTests
//
//  Community access vs. paid-license status. A community build is
//  UNRESTRICTED (pinned `.byok`, `canGenerate` true) but never LICENSED:
//  `enforcesLicensing` / `hasActiveLicense` / `isPaidEntitled` stay false,
//  and normal launch, refresh, and background re-validation never read
//  license or trial storage or contact Lemon Squeezy. Official builds keep
//  the existing license behavior, proven against the same doubles.
//

import XCTest
@testable import Zerro

/// A `KeychainSlot` that records every access, so a test can prove a code
/// path NEVER touched a slot.
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
    func write(_ value: String) { writes += 1; self.value = value }
    func delete() { deletes += 1; value = nil }

    var wasNeverTouched: Bool { reads == 0 && writes == 0 && deletes == 0 }
}

/// A `LicenseTransport` that records every request and answers with a valid,
/// approved-product validation — so an official build's re-validation is
/// observable and a community build's silence is provable.
private final class SpyLicenseTransport: LicenseTransport {
    private(set) var requests: [String] = []

    func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
        requests.append(path)
        return (Data(#"{ "valid": true, "license_key": { "status": "active" }, "meta": { "product_id": 7 } }"#.utf8), 200)
    }
}

@MainActor
final class CommunityLicensingPolicyTests: XCTestCase {

    /// Every license + trial slot as a spy, plus a spy transport. The license
    /// on file is a COMPLETE compatible record with a stale validation stamp,
    /// so an official build both grants `.byok` and re-validates at launch.
    private struct Doubles {
        let key = SpyKeychainSlot("KEY")
        let instance = SpyKeychainSlot("instance")
        let lastValidated = SpyKeychainSlot(
            String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        )
        let product = SpyKeychainSlot("7")
        let major = SpyKeychainSlot("1")
        let trialStart = SpyKeychainSlot()
        let trialMaxSeen = SpyKeychainSlot()
        let transport = SpyLicenseTransport()

        var licenseSlots: [SpyKeychainSlot] { [key, instance, lastValidated, product, major] }
        var trialSlots: [SpyKeychainSlot] { [trialStart, trialMaxSeen] }

        func store(_ mode: EntitlementEnforcementMode) -> EntitlementStore {
            let license = LicenseService(
                licenseKeySlot: key,
                instanceIDSlot: instance,
                lastValidatedSlot: lastValidated,
                licensedProductIDSlot: product,
                licensedMajorSlot: major,
                policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
                transport: transport
            )
            let clock = TrialManager(startDateSlot: trialStart, maxDateSeenSlot: trialMaxSeen, clock: { Date() })
            return EntitlementStore(enforcementMode: mode, licenseService: license, trialManager: clock)
        }
    }

    // MARK: - Community: unrestricted, never licensed

    func testCommunityWithNoLicenseIsUnrestrictedButNotLicensed() {
        let store = EntitlementStore(
            enforcementMode: .community,
            licenseService: LicenseService(
                licenseKeySlot: InMemoryKeychainSlot(),
                instanceIDSlot: InMemoryKeychainSlot(),
                lastValidatedSlot: InMemoryKeychainSlot(),
                licensedProductIDSlot: InMemoryKeychainSlot(),
                licensedMajorSlot: InMemoryKeychainSlot(),
                policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
                transport: OfflineLicenseTransport()
            )
        )
        XCTAssertTrue(store.canGenerate, "community is never entitlement-blocked")
        XCTAssertEqual(store.state, .byok, "community pins the always-entitled state")
        XCTAssertFalse(store.enforcesLicensing)
        XCTAssertFalse(store.hasActiveLicense, "unrestricted is not the same as licensed")
        XCTAssertFalse(store.isPaidEntitled)
        XCTAssertFalse(store.hasLicenseOnFile)
        XCTAssertFalse(store.hasIncompatibleLicense)
        XCTAssertNil(store.incompatibleLicensedMajor)
        XCTAssertFalse(store.isActiveLicenseKey("ANY-KEY"))
    }

    func testCommunityWithALicenseOnFileStillReportsNotLicensed() {
        // Even a complete compatible record on disk doesn't make a community
        // build "paid" — it is never read.
        let doubles = Doubles()
        let store = doubles.store(.community)
        XCTAssertTrue(store.canGenerate)
        XCTAssertFalse(store.hasActiveLicense)
        XCTAssertFalse(store.isPaidEntitled)
        XCTAssertFalse(store.isActiveLicenseKey("KEY"))
    }

    func testCommunityInitRefreshAndRevalidationTouchNoStorageOrTransport() async {
        let doubles = Doubles()
        let store = doubles.store(.community)

        _ = store.canGenerate
        _ = store.state
        _ = store.isPaidEntitled
        _ = store.hasActiveLicense
        _ = store.hasLicenseOnFile
        _ = store.hasIncompatibleLicense
        _ = store.isActiveLicenseKey("KEY")
        store.refresh()
        await store.revalidateLicenseIfNeeded()

        for slot in doubles.licenseSlots {
            XCTAssertTrue(slot.wasNeverTouched, "community must never read/write a license slot")
        }
        for slot in doubles.trialSlots {
            XCTAssertTrue(slot.wasNeverTouched, "community must never read/write a trial slot")
        }
        XCTAssertTrue(doubles.transport.requests.isEmpty, "community must never contact Lemon Squeezy")
    }

    // MARK: - Official: the existing license behavior is intact

    func testOfficialLicensedBuildIsLicensedAndRevalidates() async {
        let doubles = Doubles()
        let store = doubles.store(.official)

        XCTAssertTrue(store.enforcesLicensing)
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.hasActiveLicense)
        XCTAssertTrue(store.isPaidEntitled)
        XCTAssertTrue(store.hasLicenseOnFile)
        XCTAssertTrue(store.isActiveLicenseKey("KEY"))
        XCTAssertFalse(doubles.licenseSlots.allSatisfy(\.wasNeverTouched), "official mode reads the license record")

        await store.revalidateLicenseIfNeeded()
        XCTAssertEqual(doubles.transport.requests, [LicenseService.validatePath],
                       "a stale stamp on an official build re-validates online")
        XCTAssertEqual(store.state, .byok)
    }

    func testOfficialUnlicensedBuildRunsTheTrialClock() {
        let doubles = Doubles()
        // No license on file: blank the license slots (still spies).
        doubles.key.delete(); doubles.instance.delete(); doubles.product.delete(); doubles.major.delete()
        let store = doubles.store(.official)

        guard case .localTrial = store.state else {
            return XCTFail("expected an active local trial, got \(store.state)")
        }
        XCTAssertTrue(store.canGenerate)
        XCTAssertFalse(store.hasActiveLicense)
        XCTAssertFalse(store.isPaidEntitled)
        XCTAssertFalse(doubles.trialSlots.allSatisfy(\.wasNeverTouched), "official mode starts + reads the trial clock")
    }
}
