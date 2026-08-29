//
//  MenuBarBillingActionTests.swift
//  ZerroTests
//
//  Covers the single always-present menu-bar billing row: its label,
//  secondary nudge, and paywall trigger are resolved from the live
//  entitlement. `MenuBarBillingAction.resolve` is pure, so these pin the
//  state → (label, trigger) selection directly.
//

import XCTest
@testable import Zerro

final class MenuBarBillingActionTests: XCTestCase {

    private func resolve(_ state: EntitlementState) -> MenuBarBillingAction {
        MenuBarBillingAction.resolve(state: state)
    }

    // MARK: - Local trial / expired both read "Upgrade", different triggers

    func testLocalTrialIsVoluntaryUpgrade() {
        let action = resolve(.localTrial(daysRemaining: 9))
        XCTAssertEqual(action.label, "Upgrade")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .voluntaryUpgrade)
    }

    func testLocalTrialExpiredIsBlockedUpgrade() {
        let action = resolve(.localTrialExpired)
        XCTAssertEqual(action.label, "Upgrade")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .blocked)
    }

    // MARK: - Local trial menu-bar line copy

    func testLocalTrialLineSingularAndPlural() {
        XCTAssertEqual(
            MenuBarPanelView.localTrialLineText(daysRemaining: 1),
            "Free trial \u{00B7} 1 day left"
        )
        XCTAssertEqual(
            MenuBarPanelView.localTrialLineText(daysRemaining: 14),
            "Free trial \u{00B7} 14 days left"
        )
    }

    // MARK: - Licensed manages (nothing to upgrade)

    func testLicensedManages() {
        let action = resolve(.byok)
        XCTAssertEqual(action.label, "Manage License")
        XCTAssertNil(action.secondary)
        XCTAssertEqual(action.trigger, .manage)
    }

    // MARK: - No state ever mentions credits, plans, or subscriptions

    func testNoRowCopyMentionsRetiredConcepts() {
        for state in [EntitlementState.localTrial(daysRemaining: 3), .localTrialExpired, .byok] {
            let action = resolve(state)
            let text = (action.label + " " + (action.secondary ?? "")).lowercased()
            for banned in ["credit", "plan", "subscription", "top up", "cloud"] {
                XCTAssertFalse(text.contains(banned), "\(state): \(text)")
            }
        }
    }
}
