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
//  "generations" count — a generation's cost varies by model and is metered on
//  the server. The app shows NO per-model cost estimate; the only per-recording
//  number it surfaces is the actual `credits_charged` the server returns.
//
//  Pure functions over plain values — no stores, no networking — so the whole
//  surface is unit-testable without UI.
//

import Foundation

enum CreditDisplay {

    // MARK: - Low-balance threshold (6B.4 / 6F.4 — the ONE source of truth)

    /// Nudge threshold (credits): at or below this, the menu-bar billing row
    /// and the billing card escalate to the low-balance top-up / upgrade
    /// prompt. A price-agnostic floor (the app no longer knows per-model cost) —
    /// ≈ one heavy recording's worth of credits, so the user is warned before a
    /// recording can fail mid-flight. Tunable.
    static let LOW_BALANCE_CREDITS = 30

    /// True when the spendable balance has dropped to the nudge threshold.
    /// Drives both the generation-flow top-up prompt and the billing-card
    /// escalation. Price-agnostic: charging is metered server-side, so the app
    /// nudges on an absolute balance floor rather than a selected-model price.
    static func isLowBalance(balance: Int) -> Bool {
        balance <= LOW_BALANCE_CREDITS
    }

    // MARK: - Headline + helper strings

    /// "248 credits" / "1 credit" — the §1.5 primary number.
    static func creditsHeadline(_ balance: Int) -> String {
        balance == 1 ? "1 credit" : "\(balance) credits"
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
    /// the server's exact metered `credits_charged`; never derived from any
    /// local per-model number). A replayed/uncharged result (charged == 0)
    /// reads "No charge · 96 left" rather than "−0 credits".
    static func chargeLine(charged: Int, remaining: Int) -> String {
        let charge = charged == 0
            ? "No charge"
            : (charged == 1 ? "\u{2212}1 credit" : "\u{2212}\(charged) credits")
        return "\(charge) \u{00B7} \(remaining) left"
    }
}
