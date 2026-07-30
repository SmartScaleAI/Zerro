//
//  CreditDisplayTests.swift
//  ZerroTests
//
//  Phase 6 (multi-model 6B) — the credit-UX helpers: the price-agnostic
//  low-balance thresholds (one source of truth for the trial and paid-plan
//  prompts), the §1.5 strings, the usage meter, and the
//  post-generation toast. Per-model "~N left" / translation helpers were
//  removed in metered-credits Phase 4 (the app shows no per-model cost).
//

import XCTest
@testable import Zerro

@MainActor
final class CreditDisplayTests: XCTestCase {

    // MARK: - Low-balance threshold (price-agnostic — metered-credits Phase 4)

    func testTrialLowBalanceTripsAtOrBelowTenCredits() {
        XCTAssertEqual(CreditDisplay.TRIAL_LOW_BALANCE_CREDITS, 10)
        XCTAssertFalse(CreditDisplay.isLowBalance(balance: 30, type: .trial))
        XCTAssertFalse(CreditDisplay.isLowBalance(balance: 11, type: .trial))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 10, type: .trial))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 9, type: .trial))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 0, type: .trial))
    }

    func testPaidLowBalanceTripsAtOrBelowThirtyCredits() {
        XCTAssertEqual(CreditDisplay.PAID_LOW_BALANCE_CREDITS, 30)
        XCTAssertFalse(CreditDisplay.isLowBalance(balance: 31, type: .paid))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 30, type: .paid))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 29, type: .paid))
        XCTAssertTrue(CreditDisplay.isLowBalance(balance: 0, type: .paid))
    }

    // MARK: - §1.5 strings

    func testCreditsHeadlineSingularizes() {
        XCTAssertEqual(CreditDisplay.creditsHeadline(248), "248 credits")
        XCTAssertEqual(CreditDisplay.creditsHeadline(1), "1 credit")
        XCTAssertEqual(CreditDisplay.creditsHeadline(0), "0 credits")
    }

    // MARK: - Usage meter (6F)

    func testCombinedHeadlineGroupsThousandsAndSingularizes() {
        // The headline now shows the COMBINED balance on its own (no "of {cap}"),
        // so a top-up holder reads "1,289 credits" instead of "1,289 of 300".
        XCTAssertEqual(CreditDisplay.combinedHeadline(248), "248 credits")
        // Grouped thousands — the case that motivated the split (a banked
        // top-up balance running well over the monthly cap).
        XCTAssertEqual(CreditDisplay.combinedHeadline(1289), "1,289 credits")
        // §1.5 singular.
        XCTAssertEqual(CreditDisplay.combinedHeadline(1), "1 credit")
        // At or below zero, the shared "Out of Credits" rule (balanceLabel) wins
        // over a literal "0 credits" — the one source of truth.
        XCTAssertEqual(CreditDisplay.combinedHeadline(0), "Out of Credits")
        XCTAssertEqual(CreditDisplay.combinedHeadline(-5), "Out of Credits")
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
        // Singular charge singularizes; a positive balance still reads "N left".
        XCTAssertEqual(CreditDisplay.chargeLine(charged: 1, remaining: 95), "\u{2212}1 credit \u{00B7} 95 left")
    }

    // MARK: - Balance label + out-of-credits charge line (overspend → negative)

    func testBalanceLabelSwapsToOutOfCreditsAtOrBelowZero() {
        // Positive → the §1.5 headline; zero or negative → the shared
        // "Out of Credits" label (a raw negative is never surfaced).
        XCTAssertEqual(CreditDisplay.balanceLabel(96), "96 credits")
        XCTAssertEqual(CreditDisplay.balanceLabel(1), "1 credit")
        XCTAssertEqual(CreditDisplay.balanceLabel(0), "Out of Credits")
        XCTAssertEqual(CreditDisplay.balanceLabel(-6), "Out of Credits")
    }

    func testChargeLineShowsOutOfCreditsWhenBalanceHitsZeroOrNegative() {
        // The one final uncapped generation: the deducted amount stays the
        // server's exact `credits_charged`, but the balance segment reads
        // "Out of Credits" rather than "0 left" or a raw negative.
        XCTAssertEqual(
            CreditDisplay.chargeLine(charged: 30, remaining: 0),
            "\u{2212}30 credits \u{00B7} Out of Credits"
        )
        // A costlier generation that overshot a small balance into the negative.
        XCTAssertEqual(
            CreditDisplay.chargeLine(charged: 10, remaining: -6),
            "\u{2212}10 credits \u{00B7} Out of Credits"
        )
        // Singular charge still singularizes; the balance still swaps.
        XCTAssertEqual(
            CreditDisplay.chargeLine(charged: 1, remaining: -1),
            "\u{2212}1 credit \u{00B7} Out of Credits"
        )
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
