//
//  CreditDisplayTests.swift
//  ZerroTests
//
//  Phase 6 (multi-model 6B) — the credit-UX helpers: the price-agnostic
//  low-balance threshold (one source of truth for both the generation-flow
//  prompt and the billing card), the §1.5 strings, the usage meter, and the
//  post-generation toast. Per-model "~N left" / translation helpers were
//  removed in metered-credits Phase 4 (the app shows no per-model cost).
//

import XCTest
@testable import Zerro

@MainActor
final class CreditDisplayTests: XCTestCase {

    // MARK: - Low-balance threshold (price-agnostic — metered-credits Phase 4)

    func testLowBalanceTripsAtOrBelowThreshold() {
        // LOW_BALANCE_CREDITS = 30: at/below is low, just above is not.
        XCTAssertEqual(CreditDisplay.LOW_BALANCE_CREDITS, 30)
        XCTAssertFalse(CreditDisplay.isLowBalance(balance: 31)) // above → fine
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 30))  // at threshold → low
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 29))  // below → low
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 0))   // empty → low
    }

    // MARK: - §1.5 strings

    func testCreditsHeadlineSingularizes() {
        XCTAssertEqual(CreditDisplay.creditsHeadline(248), "248 credits")
        XCTAssertEqual(CreditDisplay.creditsHeadline(1), "1 credit")
        XCTAssertEqual(CreditDisplay.creditsHeadline(0), "0 credits")
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
            status: .active, creditsRemaining: 100, creditsLimit: 300,
            resetDate: nil, planCreditsUsed: 200, planCreditsLimit: 300, topupCreditsRemaining: 0
        )
        let updated = snapshot.withCreditsRemaining(93)
        XCTAssertEqual(updated.creditsRemaining, 93)
        XCTAssertEqual(updated.planCreditsUsed, 200) // carried, not guessed
        XCTAssertEqual(updated.planCreditsLimit, 300)
    }

    // MARK: - Post-generation toast (D2 — metered charge passthrough)

    func testChargeLineFormatsExactServerCharge() {
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 4, remaining: 96), "\u{2212}4 credits \u{00B7} 96 left")
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 1, remaining: 0), "\u{2212}1 credit \u{00B7} 0 left")
    }

    func testChargeLineRendersExactMeteredValue() {
        // Charging is METERED server-side: the toast must show whatever
        // `credits_charged` the server returns — never a client-side per-model
        // number. A heavy recording (e.g. 24 credits of real cost) renders as-is.
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 24, remaining: 276), "\u{2212}24 credits \u{00B7} 276 left")
        // An arbitrary metered value that matches no old fixed price still
        // renders verbatim — proving there's no price-table coupling.
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 17, remaining: 3), "\u{2212}17 credits \u{00B7} 3 left")
    }

    func testChargeLineZeroChargeReadsNoCharge() {
        // The idempotent uncharged-race replay reports credits_charged = 0 —
        // "−0 credits" would read as a bug.
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 0, remaining: 96), "No charge \u{00B7} 96 left")
    }
}
