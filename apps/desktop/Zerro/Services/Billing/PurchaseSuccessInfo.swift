//
//  PurchaseSuccessInfo.swift
//  Zerro
//
//  The one-shot "you're all set" confirmation rendered after a purchase lands —
//  shared by BOTH activation entry points (the `zerro://checkout-complete` deep
//  link AND the manual paste-a-key field) plus the Managed top-up path. Set on
//  `EntitlementStore.purchaseSuccess`; `PaywallView` swaps the buy/manage matrix
//  for the success screen while it's non-nil, and clears it when the user taps
//  the confirmation's button.
//
//  Data only (no AppKit, no view) so the derivation + the detail copy are pure,
//  unit-testable functions.
//

import Foundation

/// What to show on the success confirmation. The managed/byok cases are derived
/// from the entitlement `state` at set-time; `.topup` carries the credit delta a
/// top-up added (computed by diffing the balance across the entitlement refresh).
enum PurchaseSuccessInfo: Equatable {
    /// A Managed subscription is now active. `credits`/`resetDate` are the
    /// display values from the just-refreshed `.managed` state.
    case managed(credits: Int, resetDate: Date)
    /// A one-time BYOK license is now active. The user still needs to add their
    /// own provider API key in Settings before generating (BYOK funds locally).
    case byok
    /// A Managed top-up landed: `added` credits were granted, `total` is the new
    /// balance.
    case topup(added: Int, total: Int)

    /// Derives the confirmation to show from a just-activated entitlement state.
    /// Managed/byok map straight across; trial/expired return `nil` — there's no
    /// purchase to confirm (the activation paths only call this after a success,
    /// so a `nil` here is a defensive fall-through to plain dismissal).
    static func fromActivatedState(_ state: EntitlementState) -> PurchaseSuccessInfo? {
        switch state {
        case .managed(let credits, let resetDate):
            return .managed(credits: credits, resetDate: resetDate)
        case .byok:
            return .byok
        case .trial, .expired, .byokTrial, .byokTrialExpired:
            return nil
        }
    }

    /// Builds a top-up confirmation from the credit balance before/after the
    /// entitlement refresh, or `nil` when it can't be computed — either balance
    /// was unknown (a non-credit state, or a read that didn't land) or it didn't
    /// actually increase (nothing meaningful to confirm; fall back to a silent
    /// return). Named `topupDelta` to avoid clashing with the `.topup` case.
    static func topupDelta(before: Int?, after: Int?) -> PurchaseSuccessInfo? {
        guard let before, let after, after > before else { return nil }
        return .topup(added: after - before, total: after)
    }

    /// The analytics `plan` value for `purchase_success_shown`.
    var analyticsPlan: String {
        switch self {
        case .managed: return "managed"
        case .byok:    return "byok"
        case .topup:   return "topup"
        }
    }

    /// The plan-specific detail line shown under the "You're all set" headline.
    /// Lives here (not in the view) so the exact copy is unit-tested directly.
    /// `formatDate` renders the Managed reset date — injected so tests stay
    /// locale-independent.
    func detailLine(formatDate: (Date) -> String) -> String {
        switch self {
        case .managed(let credits, let resetDate):
            return "Managed is active. \(credits) credits available, resets \(formatDate(resetDate))."
        case .byok:
            return "Bring-your-own-key is active. Add your provider API key in Settings to start generating."
        case .topup(let added, let total):
            return "Added \(added) credits. \(total) total."
        }
    }
}
