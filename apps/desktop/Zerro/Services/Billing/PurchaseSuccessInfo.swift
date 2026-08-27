//
//  PurchaseSuccessInfo.swift
//  Zerro
//
//  The one-shot "you're all set" confirmation rendered after a purchase lands —
//  shared by BOTH activation entry points (the `zerro://checkout-complete` deep
//  link AND the manual paste-a-key field). Set on
//  `EntitlementStore.purchaseSuccess`; `PaywallView` swaps the buy/manage matrix
//  for the success screen while it's non-nil, and clears it when the user taps
//  the confirmation's button.
//
//  Data only (no AppKit, no view) so the derivation + the detail copy are pure,
//  unit-testable functions.
//

import Foundation

/// What to show on the success confirmation. The store sells one product —
/// the Zerro license — so there is one success shape.
enum PurchaseSuccessInfo: Equatable {
    /// The Zerro license is now active. The user still needs to add their
    /// own provider API key in Settings before generating.
    case license

    /// Derives the confirmation to show from a just-activated entitlement state.
    /// `.byok` (the licensed state) maps to the license confirmation; everything
    /// else returns `nil` — there's no purchase to confirm (the activation paths
    /// only call this after a success, so a `nil` here is a defensive
    /// fall-through to plain dismissal).
    static func fromActivatedState(_ state: EntitlementState) -> PurchaseSuccessInfo? {
        switch state {
        case .byok:
            return .license
        case .localTrial, .localTrialExpired:
            return nil
        }
    }

    /// The analytics `plan` value for `purchase_success_shown`.
    var analyticsPlan: String {
        switch self {
        case .license: return "license"
        }
    }

    /// The detail line shown under the "You're all set" headline. Lives here
    /// (not in the view) so the exact copy is unit-tested directly.
    var detailLine: String {
        switch self {
        case .license:
            return "Your Zerro license is active. Add your provider API key in Settings to start generating."
        }
    }
}
