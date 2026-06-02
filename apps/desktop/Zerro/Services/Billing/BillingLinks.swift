//
//  BillingLinks.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase C — the external LemonSqueezy URLs the billing UI links out to:
//  the hosted BYOK checkout (paywall "Get a license") and the customer
//  portal ("Manage devices" / "Manage subscription"). Pulled into one place
//  so the two surfaces (PaywallView, BillingSection) share a single source
//  of truth.
//
//  These are intentionally PLACEHOLDERS until the LemonSqueezy account is out
//  of review — grep `TODO:` to find the two strings to fill in. Each is read
//  through `url`, which returns `nil` for an unfilled placeholder so the UI
//  can disable/soften the affordance instead of opening a dead link or
//  crashing on a force-unwrap.
//

import Foundation

enum BillingLinks {

    /// The LemonSqueezy hosted checkout for the one-time BYOK license.
    /// Opening this in the default browser (NSWorkspace) is the v1 buy flow —
    /// the LS overlay JS is awkward to host in a native app.
    // checkout link for the BYOK product once the account is approved.
    static let byokCheckoutURLString = "https://store.getzerro.app/checkout/buy/1e36ae90-2f72-4dcf-9f30-6d763b10cac1"

    /// The LemonSqueezy customer portal where a buyer manages their license /
    /// devices (used by the at-activation-limit hint and the Settings "Manage"
    /// row).
    // URL once the account is approved.
    static let customerPortalURLString = "https://app.lemonsqueezy.com/my-orders"

    /// The checkout URL, or `nil` if still a placeholder. `nil` until the
    /// `TODO:` above is filled in (the placeholder isn't a valid absolute URL,
    /// so `URL(string:)` already rejects it — the prefix guard is belt-and-
    /// suspenders against a half-filled value).
    static var byokCheckoutURL: URL? { resolvedURL(byokCheckoutURLString) }

    /// The customer-portal URL, or `nil` if still a placeholder.
    static var customerPortalURL: URL? { resolvedURL(customerPortalURLString) }

    private static func resolvedURL(_ raw: String) -> URL? {
        guard !raw.hasPrefix("TODO"), let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url
    }
}
