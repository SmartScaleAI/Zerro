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

    /// B-07: the ONE user-facing statement of the server's metering floor —
    /// charging is metered on real cost but never below 1 credit per
    /// generation (`Math.max(1, …)` in `generate/cost.ts`), so even a
    /// 2-second recording spends a credit. Price-agnostic on purpose: states
    /// the floor only, never a per-model estimate. Shown near the Settings
    /// usage meter and in the paywall top-up copy.
    static let minimumChargeNote = "Every generation uses at least 1 credit."

    /// "248 credits" / "1 credit" — the §1.5 primary number.
    static func creditsHeadline(_ balance: Int) -> String {
        balance == 1 ? "1 credit" : "\(balance) credits"
    }

    /// Grouped-thousands formatter for the larger credit numbers (a banked
    /// top-up balance can run into the thousands). The grouping separator is
    /// pinned to "," so the rendered string is locale-stable — the billing copy
    /// is English-only, and the tests assert the exact "1,289" grouping.
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f
    }()

    /// A bare grouped-thousands number, e.g. "1,289" — for callers that supply
    /// their own unit/suffix (the top-up "{N} left" caption). `combinedHeadline`
    /// builds on the same formatter for the "{N} credits" headline, keeping the
    /// number formatting in this one source of truth.
    static func grouped(_ value: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "1,289 credits" / "1 credit" — the COMBINED spendable balance (plan +
    /// top-up, F4) as the meter headline, with grouped thousands and the §1.5
    /// singular. At or below zero it reads "Out of Credits" via the shared
    /// `balanceLabel` rule (the one source of truth — a raw negative is never
    /// surfaced). Replaces the old "N of {cap} credits" headline, which
    /// over-reported for top-up holders ("1,289 of 300 credits"); the meter now
    /// splits the two pools into separately-scaled bars instead.
    static func combinedHeadline(_ combined: Int) -> String {
        guard combined > 0 else { return balanceLabel(combined) }
        return combined == 1 ? "1 credit" : "\(grouped(combined)) credits"
    }

    /// The balance readout, with the shared "out of credits" rule in ONE place:
    /// `"Out of Credits"` once the balance is at or below zero — the server may
    /// have charged into the negative on the one final uncapped generation, and
    /// every further generation is then blocked until the monthly credits renew
    /// or a top-up is bought — otherwise the §1.5 `creditsHeadline`. Used by the
    /// post-generation charge line and the menu-bar credits line so the two agree
    /// on exactly when "Out of Credits" shows (a raw negative is never surfaced).
    static func balanceLabel(_ balance: Int) -> String {
        balance <= 0 ? "Out of Credits" : creditsHeadline(balance)
    }

    // MARK: - Usage meter (6F)

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
    /// reads "No charge · 96 left" rather than "−0 credits". When the metered
    /// charge took the balance to zero or below — the one final uncapped
    /// generation that goes into the negative — the balance segment reads
    /// "Out of Credits" (the shared `balanceLabel` rule) instead of the raw
    /// "<n> left", e.g. "−30 credits · Out of Credits". The deducted amount is
    /// always the server's exact `credits_charged`.
    static func chargeLine(charged: Int, remaining: Int) -> String {
        let charge = charged == 0
            ? "No charge"
            : (charged == 1 ? "\u{2212}1 credit" : "\u{2212}\(charged) credits")
        let balance = remaining > 0 ? "\(remaining) left" : balanceLabel(remaining)
        return "\(charge) \u{00B7} \(balance)"
    }
}
