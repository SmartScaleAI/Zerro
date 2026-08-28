//
//  PaywallCopyTests.swift
//  ZerroTests
//
//  Covers the dynamic paywall copy matrix: the headline + subheadline are
//  derived from WHY the window opened (`EntitlementStore.PaywallTrigger`)
//  plus the current `EntitlementState`. `PaywallCopy.resolve` is a pure
//  function, so these pin the trigger + state → copy mapping directly.
//

import XCTest
@testable import Zerro

final class PaywallCopyTests: XCTestCase {

    private func headline(_ trigger: EntitlementStore.PaywallTrigger?, _ state: EntitlementState) -> String {
        PaywallCopy.resolve(trigger: trigger, state: state).headline
    }

    // MARK: - Local trial

    func testActiveLocalTrialGetsUpgradeCopy() {
        // Both entry points — the nil fallback and the menu bar's voluntary-
        // upgrade trigger — land on the local-trial upgrade copy.
        XCTAssertEqual(
            PaywallCopy.resolve(trigger: nil, state: .localTrial(daysRemaining: 8)),
            PaywallCopy.localTrialUpgrade
        )
        XCTAssertEqual(
            PaywallCopy.resolve(trigger: .voluntaryUpgrade, state: .localTrial(daysRemaining: 8)),
            PaywallCopy.localTrialUpgrade
        )
        XCTAssertEqual(PaywallCopy.localTrialUpgrade.headline, "Get a Zerro license")
    }

    func testExpiredLocalTrialIsBlockedWithDedicatedCopy() {
        XCTAssertEqual(
            PaywallCopy.resolve(trigger: nil, state: .localTrialExpired),
            PaywallCopy.localTrialComplete
        )
        XCTAssertEqual(PaywallCopy.localTrialComplete.headline, "Your free trial has ended")
    }

    func testExpiredLocalTrialOverridesStaleTrigger() {
        // Even a stale voluntary-upgrade / manage trigger cannot soften the wall.
        XCTAssertEqual(
            PaywallCopy.resolve(trigger: .voluntaryUpgrade, state: .localTrialExpired),
            PaywallCopy.localTrialComplete
        )
        XCTAssertEqual(
            PaywallCopy.resolve(trigger: .manage, state: .localTrialExpired),
            PaywallCopy.localTrialComplete
        )
    }

    func testBlockedTriggerOnActiveTrialUsesTheWallCopy() {
        XCTAssertEqual(headline(.blocked, .localTrial(daysRemaining: 2)), PaywallCopy.localTrialComplete.headline)
    }

    func testTrialCopyMentionsNoLegacyConcepts() {
        // The local trial has no credits, generations, email verification,
        // accounts, subscriptions, or hosted plan — no paywall copy may
        // mention them.
        for copy in [PaywallCopy.localTrialUpgrade, .localTrialComplete, .manage] {
            let combined = (copy.headline + " " + copy.subheadline + " " + copy.windowTitle).lowercased()
            for banned in ["credit", "generation", "email", "account", "subscription", "zerro cloud", "plan"] {
                XCTAssertFalse(combined.contains(banned), "paywall copy must not mention '\(banned)': \(copy.headline)")
            }
        }
    }

    // MARK: - Licensed

    func testManageOnLicensed() {
        XCTAssertEqual(headline(.manage, .byok), "Manage your license")
        XCTAssertEqual(headline(nil, .byok), PaywallCopy.manage.headline)
    }

    func testApiKeyMissingMapsToManage() {
        XCTAssertEqual(headline(.apiKeyMissing, .byok), PaywallCopy.manage.headline)
    }

    // MARK: - Every context has a non-empty subheadline

    func testSubheadlinesNonEmpty() {
        for copy in [PaywallCopy.localTrialUpgrade, .localTrialComplete, .manage] {
            XCTAssertFalse(copy.subheadline.isEmpty)
            XCTAssertFalse(copy.headline.isEmpty)
            XCTAssertFalse(copy.windowTitle.isEmpty)
        }
    }

    // MARK: - License card feature lines (the $39 story)

    func testLicenseFeatureLinesTellTheFullStory() {
        XCTAssertEqual(PaywallCopy.licenseFeatureLines, [
            "Includes all Zerro 1.x.x updates",
            "Use on up to 2 Macs",
            "Bring your own OpenAI, Anthropic, or Gemini API keys",
            "You pay providers directly for usage",
            "A future major version may be sold separately",
        ])
    }

    func testNoPaywallCopyMentionsTheOldPricingModel() {
        var surfaces = [PaywallCopy.localTrialUpgrade, .localTrialComplete, .manage]
            .flatMap { [$0.headline, $0.subheadline] }
        surfaces.append(contentsOf: PaywallCopy.licenseFeatureLines)
        for text in surfaces {
            let lower = text.lowercased()
            XCTAssertFalse(lower.contains("$69"), "stale price in: \(text)")
            XCTAssertFalse(lower.contains("$49"), "stale price in: \(text)")
            XCTAssertFalse(lower.contains("year of updates"), "stale window copy in: \(text)")
        }
    }

    // MARK: - Incompatible-license notice

    func testIncompatibleLicenseLineNamesTheCoveredMajor() {
        XCTAssertEqual(
            PaywallCopy.incompatibleLicenseLine(licensedMajor: 1, requiredMajor: 2),
            "Your license covers Zerro 1.x. This version requires a Zerro 2 license."
        )
    }

    func testIncompatibleLicenseLineFallsBackWhenMajorUnknownOrSame() {
        XCTAssertEqual(
            PaywallCopy.incompatibleLicenseLine(licensedMajor: nil, requiredMajor: 1),
            "This license key is for a different Zerro product or version."
        )
        XCTAssertEqual(
            PaywallCopy.incompatibleLicenseLine(licensedMajor: 1, requiredMajor: 1),
            "This license key is for a different Zerro product or version."
        )
    }
}
