//
//  CreditDisplay.swift
//  Zerro
//
//  Phase 6 (multi-model 6B/6F) — pure helpers for every credit-UX string and
//  threshold, so the picker, the menu-bar nudges, the post-generation toast,
//  and (6F) the Settings usage meter all read ONE source of truth instead of
//  re-deriving the math in each view.
//
//  TERMINOLOGY (§1.5): the user-facing unit is CREDITS, never a flat
//  "generations" count — a generation's cost varies by model. "Generations"
//  may appear only as the secondary translation helper produced here
//  (`translationLine`), never as the headline number.
//
//  Pure functions over plain values — no stores, no networking — so the whole
//  surface is unit-testable without UI.
//

import Foundation

enum CreditDisplay {

    // MARK: - Per-model "~N left"

    /// How many generations the balance buys on a given model (the picker
    /// row's "~N left"). Floor division; never negative.
    static func estimatedLeft(balance: Int, creditPrice: Int) -> Int {
        guard creditPrice > 0 else { return 0 }
        return max(0, balance / creditPrice)
    }

    // MARK: - Low-balance threshold (6B.4 / 6F.4 — the ONE source of truth)

    /// True when the balance can't cover the SELECTED model's next generation.
    /// Drives both the generation-flow top-up prompt and the billing-card
    /// escalation — deliberately not "exactly zero": a 3-credit balance with
    /// Opus (10) selected is already blocked.
    static func isLowBalance(balance: Int, selectedModelPrice: Int) -> Bool {
        balance < selectedModelPrice
    }

    // MARK: - Headline + helper strings

    /// "248 credits" / "1 credit" — the §1.5 primary number.
    static func creditsHeadline(_ balance: Int) -> String {
        balance == 1 ? "1 credit" : "\(balance) credits"
    }

    /// The SECONDARY translation helper, e.g. "≈ 62 with Flash · 24 with
    /// Opus" — explains what credits buy without becoming the headline unit.
    /// Anchored to the recommended model and the priciest enabled one (the
    /// legibility extremes). `nil` when the balance can't cover even one
    /// cheapest-model generation (the low/out states carry their own copy).
    static func translationLine(balance: Int) -> String? {
        guard
            let anchor = ModelRegistry.enabled.first(where: \.recommended),
            let priciest = ModelRegistry.enabled.max(by: { $0.creditPrice < $1.creditPrice }),
            anchor.id != priciest.id
        else { return nil }
        let anchorLeft = estimatedLeft(balance: balance, creditPrice: anchor.creditPrice)
        let priciestLeft = estimatedLeft(balance: balance, creditPrice: priciest.creditPrice)
        guard anchorLeft > 0 else { return nil }
        return "\u{2248} \(anchorLeft) with \(anchor.shortName) \u{00B7} \(priciestLeft) with \(priciest.shortName)"
    }

    // MARK: - Usage meter (6F)

    /// The meter headline: "248 of 300 credits". `combined` is the full
    /// spendable balance (plan + top-up, F4) and CAN exceed `planLimit` for a
    /// top-up holder — that's expected; the breakdown line explains it.
    static func meterHeadline(combined: Int, planLimit: Int) -> String {
        "\(combined) of \(planLimit) credits"
    }

    /// Fraction of the PLAN allowance still unspent, for the meter bar
    /// (6F.1: the bar tracks plan consumption — the thing that resets —
    /// never the combined balance, which over-reports for top-up holders).
    /// Clamped to 0...1.
    static func planFractionRemaining(planUsed: Int, planLimit: Int) -> Double {
        guard planLimit > 0 else { return 0 }
        return min(1, max(0, Double(planLimit - planUsed) / Double(planLimit)))
    }

    /// Fraction of the TRIAL grant still unspent, for the trial meter bar
    /// (E4: `remaining` over the persisted grant total from
    /// `trial_credits_limit`). Clamped to 0...1.
    static func trialFractionRemaining(remaining: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(remaining) / Double(limit)))
    }

    /// The post-generation toast: "−4 credits · 96 left" (D2 — `charged` is
    /// the server's exact `credits_charged`, incl. the circuit-breaker case;
    /// never derived from the price table). A replayed/uncharged result
    /// (charged == 0) reads "No charge · 96 left" rather than "−0 credits".
    static func chargeLine(charged: Int, remaining: Int) -> String {
        let charge = charged == 0
            ? "No charge"
            : (charged == 1 ? "\u{2212}1 credit" : "\u{2212}\(charged) credits")
        return "\(charge) \u{00B7} \(remaining) left"
    }
}
