//
//  MenuBarBillingActionTests.swift
//  ZerroTests
//
//  Covers the consolidated menu-bar billing row (Step 3): a SINGLE always-
//  present "Upgrade" entry whose label, secondary nudge, and paywall trigger
//  are resolved from the live entitlement, replacing the scattered trial-
//  upgrade / top-up / past-due CTAs. `MenuBarBillingAction.resolve` is pure, so
//  these pin the state → (label, trigger) selection directly.
//

import XCTest
@testable import Zerro

final class MenuBarBillingActionTests: XCTestCase {

    private func resolve(
        _ state: EntitlementState,
        isPastDue: Bool = false,
        isLowBalance: Bool = false
    ) -> MenuBarBillingAction {
        MenuBarBillingAction.resolve(state: state, isPastDue: isPastDue, isLowBalance: isLowBalance)
    }

    private func managed(credits: Int = 200) -> EntitlementState {
        .managed(creditsRemaining: credits, resetDate: .distantFuture)
    }

    // MARK: - Trial / Expired both read "Upgrade", different triggers

    func testTrialIsVoluntaryUpgrade() {
        let action = resolve(.trial(creditsRemaining: 9))
        XCTAssertEqual(action.label, "Upgrade")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .voluntaryUpgrade)
    }

    func testExpiredIsBlockedUpgrade() {
        let action = resolve(.expired)
        XCTAssertEqual(action.label, "Upgrade")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .blocked)
    }

    // MARK: - BYOK manages (nothing to upgrade/top up)

    func testByokManages() {
        let action = resolve(.byok)
        XCTAssertEqual(action.label, "Manage Plan")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .manage)
    }

    // MARK: - Managed: healthy / low / past-due

    func testManagedHealthyAddsMoreCredits() {
        // Healthy Managed leads the label with adding credits (where a paid-up
        // user comes to top up), but still routes through the manage portal.
        let action = resolve(managed())
        XCTAssertEqual(action.label, "Add more credits")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .manage)
    }

    func testManagedLowBalanceAddsCredits() {
        let action = resolve(managed(credits: 2), isLowBalance: true)
        XCTAssertEqual(action.label, "Add Credits")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .topup)
    }

    func testManagedPastDueManagesWithNudge() {
        let action = resolve(managed(), isPastDue: true)
        XCTAssertEqual(action.label, "Manage Plan")
        XCTAssertEqual(action.secondary, "Payment issue \u{2014} update your card")
        XCTAssertEqual(action.trigger, .manage)
    }

    func testManagedPastDueTakesPrecedenceOverLowBalance() {
        // A past-due subscription that's also low on credits: the payment issue
        // wins (update card), not the top-up — folding in the old status nudge.
        let action = resolve(managed(credits: 1), isPastDue: true, isLowBalance: true)
        XCTAssertEqual(action.label, "Manage Plan")
        XCTAssertEqual(action.trigger, .manage)
        XCTAssertNotNil(action.secondary)
    }
}
