//
//  AccountBillingCopyTests.swift
//  ZerroTests
//
//  Pins the Settings copy shown when a BYOK user opens the Zerro Cloud setup
//  pane. The active BYOK entitlement remains unchanged until Cloud activation.
//

import XCTest
@testable import Zerro

final class AccountBillingCopyTests: XCTestCase {
    func testByokTrialCloudSetupExplainsTrialDoesNotSwitch() {
        XCTAssertEqual(
            AccountBillingCopy.cloudSetupDescription(for: .byokTrial(generationsRemaining: 9)),
            "You are currently using the BYOK Trial. Subscribe and activate your key below to switch to Zerro Cloud. A second free trial is not included."
        )
        XCTAssertEqual(
            AccountBillingCopy.backToActiveModeLabel(for: .byokTrial(generationsRemaining: 9)),
            "Back to BYOK Trial"
        )
    }

    func testCompletedByokTrialCloudSetupDoesNotOfferAnotherTrial() {
        XCTAssertEqual(
            AccountBillingCopy.cloudSetupDescription(for: .byokTrialExpired),
            "Your BYOK Trial is complete. Subscribe and activate your key below to switch to Zerro Cloud. A second free trial is not included."
        )
    }

    func testPaidByokCanSetUpCloudWithoutChangingCurrentEntitlement() {
        XCTAssertEqual(
            AccountBillingCopy.cloudSetupDescription(for: .byok),
            "Subscribe and activate your key below to switch from BYOK to Zerro Cloud."
        )
        XCTAssertEqual(AccountBillingCopy.backToActiveModeLabel(for: .byok), "Back to BYOK")
    }

    func testImplementedSettingsCopyContainsNoEmDash() {
        let copy = [
            AccountBillingCopy.cloudSetupDescription(for: .byokTrial(generationsRemaining: 9)),
            AccountBillingCopy.cloudSetupDescription(for: .byokTrialExpired),
            AccountBillingCopy.cloudSetupDescription(for: .byok),
            AccountBillingCopy.backToActiveModeLabel(for: .byokTrial(generationsRemaining: 9)),
            AccountBillingCopy.backToActiveModeLabel(for: .byok),
        ]

        XCTAssertTrue(copy.allSatisfy { !$0.contains("\u{2014}") })
    }
}
