//
//  TopupPacksTests.swift
//  ZerroTests
//
//  The top-up UI is a single "Add Credits" button that opens the one
//  multi-variant "Credit Packs" LemonSqueezy checkout (the customer picks which
//  pack on the LS page; the webhook resolves the variant id → credits). These
//  tests pin the two things the app must get right: the analytics/product tag
//  (`topup`) and that the checkout URL resolves in a DEBUG/test build (the test
//  config), so the button isn't silently disabled.
//

import XCTest
@testable import Zerro

final class TopupPacksTests: XCTestCase {

    func testTopupProductRawValueIsTopup() {
        XCTAssertEqual(BillingLinks.CheckoutProduct.topup.rawValue, "topup")
    }

    func testTopupCheckoutURLResolvesInDebug() {
        // DEBUG/test builds use the test buy-id (a real UUID), so the single
        // Credit Packs checkout resolves non-nil and the "Add Credits" button is
        // enabled. (The LIVE id is still a `TODO-*` placeholder until go-live,
        // which only affects Release builds.)
        XCTAssertNotNil(BillingLinks.topupCheckoutURL)
    }
}
