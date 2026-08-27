//
//  BillingLicenseModelScopingTests.swift
//  ZerroTests
//
//  The Settings license row's field model. One product, one row: the model
//  pre-fills the on-file key and shows "Verified" when a license is stored,
//  tracks the entitlement as it changes, and treats the E-01 declined-replace
//  as a quiet no-op (no error pill; the on-file license is restored).
//

import XCTest
@testable import Zerro

@MainActor
final class BillingLicenseModelScopingTests: XCTestCase {

    private func makeModel(storedKey: String?) -> BillingLicenseModel {
        BillingLicenseModel(keychain: InMemoryKeychainSlot(storedKey))
    }

    // MARK: - init adopts the on-file key

    func testKeyOnFileFillsRowAsLicensed() {
        let model = makeModel(storedKey: "LICENSE-KEY")
        XCTAssertEqual(model.licenseKey, "LICENSE-KEY")
        XCTAssertEqual(model.phase, .licensed)
    }

    func testNoKeyOnFileStaysUnverified() {
        let model = makeModel(storedKey: nil)
        XCTAssertEqual(model.licenseKey, "")
        XCTAssertEqual(model.phase, .unverified)
    }

    // MARK: - syncToEntitlement tracks the licensed state

    func testSyncLicensesRowOnByokState() {
        let model = makeModel(storedKey: "LICENSE-KEY")
        model.syncToEntitlement(licensed: true)
        XCTAssertEqual(model.phase, .licensed)
    }

    func testSyncClearsRowWhenEntitlementLeavesLicensed() {
        // A licensed row must clear when the license stops being the active
        // entitlement (revoked, deactivated elsewhere, or a dev-forced state).
        let model = makeModel(storedKey: "LICENSE-KEY")
        XCTAssertEqual(model.phase, .licensed)
        model.syncToEntitlement(licensed: false)
        XCTAssertEqual(model.phase, .unverified)
        XCTAssertEqual(model.licenseKey, "")
    }

    func testSyncDoesNotLightUpWithoutALicense() {
        let model = makeModel(storedKey: nil)
        model.syncToEntitlement(licensed: false)
        XCTAssertEqual(model.phase, .unverified)
    }

    // MARK: - E-01: declining the replace prompt is a quiet no-op (manual-paste path)

    func testActivateDifferentKeyDeclinedRestoresLicensedRowWithNoError() async {
        // The Settings manual-paste path (E-01 Property 2 covers BOTH entry
        // points): with a DIFFERENT license already on file, declining the
        // "replace your current license?" prompt must NOT show a .failed error
        // pill — it restores the row to the still-active on-file license.
        let keySlot = InMemoryKeychainSlot("OLD-KEY")
        let licenseService = LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: InMemoryKeychainSlot("old-instance"),
            lastValidatedSlot: InMemoryKeychainSlot(),
            licensedProductIDSlot: InMemoryKeychainSlot("7"),
            licensedMajorSlot: InMemoryKeychainSlot("1"),
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: OfflineLicenseTransport(),
            instanceNameProvider: { "TestMac" },
            confirmReplace: { false }
        )
        let store = EntitlementStore(enforcementMode: .official, licenseService: licenseService)
        XCTAssertEqual(store.state, .byok) // precondition: already paid on OLD-KEY

        let model = makeModel(storedKey: "OLD-KEY")
        model.licenseKey = "NEW-KEY" // the user types a different key, then declines

        await model.performActivation(using: store)

        XCTAssertEqual(model.phase, .licensed, "declining must NOT surface a .failed error pill")
        XCTAssertEqual(model.licenseKey, "OLD-KEY", "the rejected key is dropped; the on-file key is restored")
        XCTAssertEqual(store.state, .byok, "the entitlement is unchanged")
        XCTAssertEqual(keySlot.readResult(), .found("OLD-KEY"))
    }
}
