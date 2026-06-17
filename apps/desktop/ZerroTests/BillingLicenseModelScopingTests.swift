//
//  BillingLicenseModelScopingTests.swift
//  ZerroTests
//
//  Report #11 regression cover — a Managed subscription key and a one-time
//  BYOK license key share the SAME Keychain slot (`byokLicenseKey`) and are
//  told apart only by `licenseProductKind`. The Settings license rows must be
//  product-scoped: a row pre-fills its key, shows "Verified", and shows the
//  Deactivate/Re-activate affordances ONLY when the on-file license belongs to
//  that row's product. These tests pin that `BillingLicenseModel` adopts the
//  stored key for the matching product and stays empty/unverified for the other.
//

import XCTest
@testable import Zerro

@MainActor
final class BillingLicenseModelScopingTests: XCTestCase {

    private func makeModel(
        expectedProduct: LicenseProductKind,
        storedKey: String?,
        onFileKind: LicenseProductKind?
    ) -> BillingLicenseModel {
        BillingLicenseModel(
            expectedProduct: expectedProduct,
            keychain: InMemoryKeychainSlot(storedKey),
            productKindSlot: InMemoryKeychainSlot(onFileKind?.rawValue)
        )
    }

    // MARK: - init adopts the key only for the matching product

    func testManagedKeyOnFileLeavesByokRowEmpty() {
        // A managed key is on file; the BYOK pane's row must NOT adopt it.
        let model = makeModel(expectedProduct: .byok, storedKey: "MANAGED-KEY", onFileKind: .managed)
        XCTAssertEqual(model.licenseKey, "")
        XCTAssertEqual(model.phase, .unverified)
    }

    func testByokKeyOnFileLeavesManagedRowEmpty() {
        // Symmetric: a BYOK key is on file; the Managed pane's row stays empty.
        let model = makeModel(expectedProduct: .managed, storedKey: "BYOK-KEY", onFileKind: .byok)
        XCTAssertEqual(model.licenseKey, "")
        XCTAssertEqual(model.phase, .unverified)
    }

    func testManagedKeyOnFileFillsManagedRow() {
        let model = makeModel(expectedProduct: .managed, storedKey: "MANAGED-KEY", onFileKind: .managed)
        XCTAssertEqual(model.licenseKey, "MANAGED-KEY")
        XCTAssertEqual(model.phase, .licensed)
    }

    func testByokKeyOnFileFillsByokRow() {
        let model = makeModel(expectedProduct: .byok, storedKey: "BYOK-KEY", onFileKind: .byok)
        XCTAssertEqual(model.licenseKey, "BYOK-KEY")
        XCTAssertEqual(model.phase, .licensed)
    }

    func testKeyOnFileWithoutKindStaysUnverified() {
        // Pre-Phase-E key with no resolved product kind: neither row adopts it
        // (the discriminator is absent, so it can't be claimed as "mine").
        let model = makeModel(expectedProduct: .byok, storedKey: "LEGACY-KEY", onFileKind: nil)
        XCTAssertEqual(model.licenseKey, "")
        XCTAssertEqual(model.phase, .unverified)
    }

    func testNoKeyOnFileStaysUnverified() {
        let model = makeModel(expectedProduct: .managed, storedKey: nil, onFileKind: nil)
        XCTAssertEqual(model.licenseKey, "")
        XCTAssertEqual(model.phase, .unverified)
    }

    // MARK: - syncToEntitlement keeps only the matching row licensed

    func testSyncLicensesManagedRowOnlyForManagedState() {
        let model = makeModel(expectedProduct: .managed, storedKey: "MANAGED-KEY", onFileKind: .managed)
        model.syncToEntitlement(.managed(creditsRemaining: 100, resetDate: .distantFuture))
        XCTAssertEqual(model.phase, .licensed)

        // A BYOK-row model must NOT light up on a managed entitlement.
        let byokRow = makeModel(expectedProduct: .byok, storedKey: nil, onFileKind: nil)
        byokRow.syncToEntitlement(.managed(creditsRemaining: 100, resetDate: .distantFuture))
        XCTAssertEqual(byokRow.phase, .unverified)
    }

    func testSyncClearsRowWhenEntitlementLeavesItsProduct() {
        // A managed row that was licensed must clear when the entitlement flips
        // to BYOK (e.g. the user activated a BYOK key while previewing).
        let model = makeModel(expectedProduct: .managed, storedKey: "MANAGED-KEY", onFileKind: .managed)
        XCTAssertEqual(model.phase, .licensed)
        model.syncToEntitlement(.byok)
        XCTAssertEqual(model.phase, .unverified)
        XCTAssertEqual(model.licenseKey, "")
    }
}
