//
//  CreditDisplayTests.swift
//  ZerroTests
//
//  Phase 6 (multi-model 6B) — the credit-UX helpers behind the picker's
//  "~N left", the low-balance threshold (one source of truth for both the
//  generation-flow prompt and the billing card), the §1.5 strings, and the
//  post-generation toast.
//

import XCTest
@testable import Zerro

@MainActor
final class CreditDisplayTests: XCTestCase {

    // MARK: - "~N left"

    func testEstimatedLeftIsFloorDivision() {
        XCTAssertEqual(CreditDisplay.estimatedLeft(balance: 248, creditPrice: 4), 62)
        XCTAssertEqual(CreditDisplay.estimatedLeft(balance: 248, creditPrice: 10), 24)
        XCTAssertEqual(CreditDisplay.estimatedLeft(balance: 9, creditPrice: 10), 0)
        XCTAssertEqual(CreditDisplay.estimatedLeft(balance: 0, creditPrice: 4), 0)
    }

    func testEstimatedLeftNeverNegativeOrDivByZero() {
        XCTAssertEqual(CreditDisplay.estimatedLeft(balance: -5, creditPrice: 4), 0)
        XCTAssertEqual(CreditDisplay.estimatedLeft(balance: 100, creditPrice: 0), 0)
    }

    // MARK: - Low-balance threshold (6B.4 / 6F.4)

    func testLowBalanceIsModelRelative_notExactlyZero() {
        // 9 credits with Opus (10) selected is already blocked → low.
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 9, selectedModelPrice: 10))
        // The same 9 credits with Flash (4) selected is fine.
        XCTAssertFalse(CreditDisplay.isLowBalance(balance: 9, selectedModelPrice: 4))
        // Exactly affordable is NOT low.
        XCTAssertFalse(CreditDisplay.isLowBalance(balance: 10, selectedModelPrice: 10))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 0, selectedModelPrice: 2))
    }

    // MARK: - §1.5 strings

    func testCreditsHeadlineSingularizes() {
        XCTAssertEqual(CreditDisplay.creditsHeadline(248), "248 credits")
        XCTAssertEqual(CreditDisplay.creditsHeadline(1), "1 credit")
        XCTAssertEqual(CreditDisplay.creditsHeadline(0), "0 credits")
    }

    func testTranslationLineUsesRecommendedAndPriciest() {
        // 248 credits: ≈ 62 with Flash (4) · 22 with GPT-5.5 (11 — priciest).
        XCTAssertEqual(
            CreditDisplay.translationLine(balance: 248),
            "\u{2248} 62 with Flash \u{00B7} 22 with GPT-5.5"
        )
    }

    func testTranslationLineHiddenWhenBalanceBuysNothing() {
        // 3 credits can't cover even the recommended model (4) — the low/out
        // states carry their own copy, so the helper stays quiet.
        XCTAssertNil(CreditDisplay.translationLine(balance: 3))
    }

    // MARK: - Usage meter (6F)

    func testMeterHeadlineShowsCombinedAgainstPlanCap() {
        XCTAssertEqual(CreditDisplay.meterHeadline(combined: 248, planLimit: 300), "248 of 300 credits")
        // A top-up holder's combined balance can EXCEED the plan cap — by
        // design (the bar tracks the plan; the headline matches the picker).
        XCTAssertEqual(CreditDisplay.meterHeadline(combined: 450, planLimit: 300), "450 of 300 credits")
    }

    func testPlanFractionTracksPlanOnly() {
        XCTAssertEqual(CreditDisplay.planFractionRemaining(planUsed: 0, planLimit: 300), 1.0)
        XCTAssertEqual(CreditDisplay.planFractionRemaining(planUsed: 150, planLimit: 300), 0.5)
        XCTAssertEqual(CreditDisplay.planFractionRemaining(planUsed: 300, planLimit: 300), 0.0)
        // Clamped: over-spend bookkeeping or a zero limit never breaks the bar.
        XCTAssertEqual(CreditDisplay.planFractionRemaining(planUsed: 400, planLimit: 300), 0.0)
        XCTAssertEqual(CreditDisplay.planFractionRemaining(planUsed: 0, planLimit: 0), 0.0)
    }

    func testTrialFractionTracksRemainingOverGrantTotal() {
        // E4: remaining / trial_credits_limit drives the trial meter bar.
        XCTAssertEqual(CreditDisplay.trialFractionRemaining(remaining: 40, limit: 40), 1.0)
        XCTAssertEqual(CreditDisplay.trialFractionRemaining(remaining: 20, limit: 40), 0.5)
        XCTAssertEqual(CreditDisplay.trialFractionRemaining(remaining: 0, limit: 40), 0.0)
        // Clamped: a server-grown grant or a zero/absent limit never breaks the bar.
        XCTAssertEqual(CreditDisplay.trialFractionRemaining(remaining: 50, limit: 40), 1.0)
        XCTAssertEqual(CreditDisplay.trialFractionRemaining(remaining: -1, limit: 40), 0.0)
        XCTAssertEqual(CreditDisplay.trialFractionRemaining(remaining: 10, limit: 0), 0.0)
    }

    // MARK: - Snapshot DTO (F4 plan breakdown)

    func testSnapshotDecodesPlanBreakdownFields() throws {
        let json = ManagedFixtures.entitlementJSON(
            creditsRemaining: 450, creditsLimit: 300,
            planCreditsUsed: 50, planCreditsLimit: 300, topupCreditsRemaining: 200
        )
        let dto = try JSONDecoder().decode(EntitlementSnapshotDTO.self, from: Data(json.utf8))
        let snapshot = ManagedEntitlementSnapshot(dto: dto)
        XCTAssertEqual(snapshot.creditsRemaining, 450) // combined (headline)
        XCTAssertEqual(snapshot.planCreditsUsed, 50) // plan-only (meter bar)
        XCTAssertEqual(snapshot.planCreditsLimit, 300)
        XCTAssertEqual(snapshot.topupCreditsRemaining, 200)
    }

    func testSnapshotToleratesLegacyBodyWithoutBreakdown() throws {
        let json = ManagedFixtures.entitlementJSONLegacy(creditsRemaining: 80)
        let dto = try JSONDecoder().decode(EntitlementSnapshotDTO.self, from: Data(json.utf8))
        let snapshot = ManagedEntitlementSnapshot(dto: dto)
        XCTAssertEqual(snapshot.creditsRemaining, 80)
        XCTAssertNil(snapshot.planCreditsUsed) // meter degrades to bar-less
        XCTAssertNil(snapshot.topupCreditsRemaining)
    }

    func testWithCreditsRemainingPreservesPlanBreakdown() {
        let snapshot = ManagedEntitlementSnapshot(
            tier: .pro, status: .active, creditsRemaining: 100, creditsLimit: 300,
            resetDate: nil, planCreditsUsed: 200, planCreditsLimit: 300, topupCreditsRemaining: 0
        )
        let updated = snapshot.withCreditsRemaining(93)
        XCTAssertEqual(updated.creditsRemaining, 93)
        XCTAssertEqual(updated.planCreditsUsed, 200) // carried, not guessed
        XCTAssertEqual(updated.planCreditsLimit, 300)
    }

    // MARK: - Post-generation toast (D2)

    func testChargeLineFormatsExactServerCharge() {
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 4, remaining: 96), "\u{2212}4 credits \u{00B7} 96 left")
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 1, remaining: 0), "\u{2212}1 credit \u{00B7} 0 left")
    }

    func testChargeLineZeroChargeReadsNoCharge() {
        // The idempotent uncharged-race replay reports credits_charged = 0 —
        // "−0 credits" would read as a bug.
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 0, remaining: 96), "No charge \u{00B7} 96 left")
    }
}
