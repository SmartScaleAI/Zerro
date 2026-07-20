//
//  OnboardingStepTests.swift
//  ZerroTests
//
//  Guards the onboarding step ORDERING + stable identifiers — the flow has
//  no other tests asserting count/order, yet several things depend on it:
//    • `advance()` is `rawValue + 1`, so an out-of-order insert
//      silently skips or repeats a screen.
//    • `analyticsName` is the funnel event id and the per-step dedupe key, so
//      it must stay constant across releases (it's deliberately decoupled from
//      `rawValue`, which shifts when steps are inserted).
//    • The step dots and the `total_steps` funnel property are
//      `allCases.count`-driven, so the count is a shipped contract.
//
//  Specifically pins the Dev Mode step (educational, shown to all users)
//  between the merged Permissions step and All Set.
//

import XCTest
@testable import Zerro

final class OnboardingStepTests: XCTestCase {

    /// Dev Mode sits immediately between Permissions and All Set.
    func testDevModeOrdering() {
        XCTAssertEqual(
            OnboardingStep.devMode.rawValue,
            OnboardingStep.permissions.rawValue + 1,
            "Dev Mode must come immediately after Permissions"
        )
        XCTAssertEqual(
            OnboardingStep.allSet.rawValue,
            OnboardingStep.devMode.rawValue + 1,
            "All Set must come immediately after Dev Mode"
        )
    }

    /// Stable analytics id — must never change once shipped.
    func testDevModeAnalyticsName() {
        XCTAssertEqual(OnboardingStep.devMode.analyticsName, "dev_mode")
    }

    /// Stable analytics id for the merged Screen Recording + Microphone step.
    func testPermissionsAnalyticsName() {
        XCTAssertEqual(OnboardingStep.permissions.analyticsName, "permissions")
    }

    /// Total step count is a shipped contract (drives the dots + funnel
    /// `total_steps`). Welcome → Consent → Email → Permissions → Dev → Ready.
    func testStepCount() {
        XCTAssertEqual(OnboardingStep.allCases.count, 6)
    }
}
