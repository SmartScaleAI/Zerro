//
//  PaywallCTAGatingTests.swift
//  ZerroTests
//
//  E-06: the "Get a license" paywall CTA gates its enabled state on the
//  checkout URL resolving — an unresolved placeholder must disable the
//  button, not leave an enabled-looking CTA that dead-clicks into a log
//  line. These tests pin both halves of that rule:
//    • `BillingLinks.resolvedURL` rejects placeholders to nil (the mechanism
//      that disables a CTA) and accepts a filled-in checkout URL (enabled).
//    • The Debug/Staging test buy-id resolves non-nil, so in this build the
//      CTA is enabled.
//

import XCTest
@testable import Zerro

final class PaywallCTAGatingTests: XCTestCase {

    // MARK: - Placeholder rejection (the disabled case)

    func testPlaceholderURLResolvesNilSoCTADisables() {
        // A bare, never-filled placeholder.
        XCTAssertNil(BillingLinks.resolvedURL("TODO: fill in after LS review"))
        // A half-filled product: the test/live switch builds a full URL even
        // from an unfilled `TODO-*` id — it must still resolve nil.
        XCTAssertNil(BillingLinks.resolvedURL("https://store.getzerro.app/checkout/buy/TODO-live-id"))
        // Not a URL at all.
        XCTAssertNil(BillingLinks.resolvedURL("not a url"))
    }

    func testFilledCheckoutURLResolvesSoCTAEnables() {
        XCTAssertNotNil(BillingLinks.resolvedURL("https://store.getzerro.app/checkout/buy/1e36ae90-2f72-4dcf-9f30-6d763b10cac1"))
    }

    // MARK: - This build's CTAs (the enabled case)

    func testLicenseCheckoutURLResolvesInDebug() {
        // Debug/Staging builds use the test buy-id (a real UUID), so "Get a
        // license" is enabled here.
        XCTAssertNotNil(BillingLinks.licenseCheckoutURL)
    }
}
