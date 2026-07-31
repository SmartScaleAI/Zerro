//
//  PaywallCopyTests.swift
//  ZerroTests
//
//  Covers the dynamic paywall copy matrix (Step 1 of the menu-bar "Upgrade"
//  entry-point work): the headline + subheadline are derived from WHY the
//  window opened (`EntitlementStore.PaywallTrigger`) plus the current
//  `EntitlementState`, instead of always saying "You've used your free
//  generations". `PaywallCopy.resolve` is a pure function, so these pin the
//  trigger + state → copy mapping directly.
//

import XCTest
@testable import Zerro

final class PaywallCopyTests: XCTestCase {

    private func headline(_ trigger: EntitlementStore.PaywallTrigger?, _ state: EntitlementState) -> String {
        PaywallCopy.resolve(trigger: trigger, state: state).headline
    }

    // MARK: - The four primary contexts (decision §1 matrix)

    func testBlockedExpiredKeepsOriginalHeadline() {
        XCTAssertEqual(headline(.blocked, .expired), PaywallCopy.blocked.headline)
        XCTAssertEqual(PaywallCopy.blocked.headline, "You\u{2019}ve used your free generations")
    }

    func testVoluntaryUpgradeOnTrial() {
        XCTAssertEqual(headline(.voluntaryUpgrade, .trial(creditsRemaining: 5)), "Upgrade your plan")
    }

    func testTopupOnManaged() {
        let state = EntitlementState.managed(creditsRemaining: 2, resetDate: .distantFuture)
        XCTAssertEqual(headline(.topup, state), "Add Credits")
    }

    func testManageOnByok() {
        XCTAssertEqual(headline(.manage, .byok), "Manage your plan")
    }

    func testManageOnHealthyManaged() {
        let state = EntitlementState.managed(creditsRemaining: 250, resetDate: .distantFuture)
        XCTAssertEqual(headline(.manage, state), "Manage your plan")
    }

    func testByokTrialCompletionHasDedicatedCopy() {
        XCTAssertEqual(
            headline(.byokTrialExhausted, .byokTrialExpired),
            "Your own-key trial is complete"
        )
        XCTAssertEqual(
            headline(nil, .byokTrialExpired),
            PaywallCopy.byokTrialComplete.headline
        )
    }

    // MARK: - Pre-flight block triggers map onto the same copy

    func testOutOfCreditsMapsToTopup() {
        let state = EntitlementState.managed(creditsRemaining: 0, resetDate: .distantFuture)
        XCTAssertEqual(headline(.outOfCredits, state), PaywallCopy.topup.headline)
    }

    func testSubscriptionInactiveMapsToManage() {
        let state = EntitlementState.managed(creditsRemaining: 50, resetDate: .distantFuture)
        XCTAssertEqual(headline(.subscriptionInactive, state), PaywallCopy.manage.headline)
    }

    func testApiKeyMissingMapsToManage() {
        XCTAssertEqual(headline(.apiKeyMissing, .byok), PaywallCopy.manage.headline)
    }

    // MARK: - Expired is always the gated copy, even with a stale trigger

    func testExpiredOverridesStaleTrigger() {
        // A leftover `topup`/`manage`/`voluntaryUpgrade` trigger must never make
        // the gated `.expired` wall read as anything but blocked.
        XCTAssertEqual(headline(.topup, .expired), PaywallCopy.blocked.headline)
        XCTAssertEqual(headline(.manage, .expired), PaywallCopy.blocked.headline)
        XCTAssertEqual(headline(.voluntaryUpgrade, .expired), PaywallCopy.blocked.headline)
    }

    // MARK: - Nil trigger falls back to a sensible copy for the state

    func testNilTriggerFallbackByState() {
        XCTAssertEqual(headline(nil, .trial(creditsRemaining: 3)), PaywallCopy.upgrade.headline)
        XCTAssertEqual(headline(nil, .expired), PaywallCopy.blocked.headline)
        XCTAssertEqual(headline(nil, .byok), PaywallCopy.manage.headline)
        XCTAssertEqual(
            headline(nil, .managed(creditsRemaining: 100, resetDate: .distantFuture)),
            PaywallCopy.manage.headline
        )
    }

    // MARK: - Every context has a non-empty subheadline

    func testSubheadlinesNonEmpty() {
        for copy in [PaywallCopy.blocked, .byokTrialComplete, .upgrade, .topup, .manage] {
            XCTAssertFalse(copy.subheadline.isEmpty)
            XCTAssertFalse(copy.headline.isEmpty)
        }
    }
}
