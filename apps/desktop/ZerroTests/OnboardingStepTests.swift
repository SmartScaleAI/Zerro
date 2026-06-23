//
//  OnboardingStepTests.swift
//  ZerroTests
//
//  Guards the onboarding step ORDERING + stable identifiers — the flow has
//  no other tests asserting count/order, yet several things depend on it:
//    • `advance()`/`goBack()` are `rawValue ± 1`, so an out-of-order insert
//      silently skips or repeats a screen.
//    • `analyticsName` is the funnel event id and the per-step dedupe key, so
//      it must stay constant across releases (it's deliberately decoupled from
//      `rawValue`, which shifts when steps are inserted).
//    • The step dots and the `total_steps` funnel property are
//      `allCases.count`-driven, so the count is a shipped contract.
//
//  Specifically pins the Dev Mode step (educational, shown to all users)
//  between Microphone and All Set.
//

import XCTest
@testable import Zerro

final class OnboardingStepTests: XCTestCase {

    /// Dev Mode sits immediately between Microphone and All Set.
    func testDevModeOrdering() {
        XCTAssertEqual(
            OnboardingStep.devMode.rawValue,
            OnboardingStep.microphone.rawValue + 1,
            "Dev Mode must come immediately after Microphone"
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

    /// Total step count is a shipped contract (drives the dots + funnel
    /// `total_steps`). Welcome → Consent → Email → Screen → Mic → Dev → Ready.
    func testStepCount() {
        XCTAssertEqual(OnboardingStep.allCases.count, 7)
    }
}
