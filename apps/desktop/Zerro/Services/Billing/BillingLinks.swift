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
    /// row). Also the v1 "manage subscription" target for Managed users — the
    /// my-orders link reaches the order/subscription. A per-subscription signed
    /// portal URL from the LS API is the cleaner version (// DEFERRED Phase G).
    // URL once the account is approved.
    static let customerPortalURLString = "https://app.lemonsqueezy.com/my-orders"

    // MARK: - Managed subscription checkouts (Phase E)
    //
    // The hosted LemonSqueezy checkout URL for each subscription PRODUCT
    // (Starter / Pro). LemonSqueezy's Share panel gives one checkout link per
    // product — the customer picks monthly vs yearly ON the page — so the app
    // links out per product, not per billing variant. (The four monthly/yearly
    // variant IDs still exist server-side for the webhook's tier mapping; the
    // app never needs them.) Same resolve-to-nil + no-op-if-unset pattern as the
    // BYOK checkout above. Grep `TODO: subscription checkout` to find the two
    // strings to fill once Colin creates the products.

    static let starterCheckoutURLString = "https://store.getzerro.app/checkout/buy/90ffa6e4-5c8a-445a-99d5-80a55ebbffd7"
    static let proCheckoutURLString = "https://store.getzerro.app/checkout/buy/4ab963c6-7e81-473b-b815-ecc163584539"

    static var starterCheckoutURL: URL? { resolvedURL(starterCheckoutURLString) }
    static var proCheckoutURL: URL? { resolvedURL(proCheckoutURLString) }

    /// The checkout URL, or `nil` if still a placeholder. `nil` until the
    /// `TODO:` above is filled in (the placeholder isn't a valid absolute URL,
    /// so `URL(string:)` already rejects it — the prefix guard is belt-and-
    /// suspenders against a half-filled value).
    static var byokCheckoutURL: URL? { resolvedURL(byokCheckoutURLString) }

    /// The customer-portal URL, or `nil` if still a placeholder.
    static var customerPortalURL: URL? { resolvedURL(customerPortalURLString) }

    /// Resolves the subscription checkout URL for a tier, or `nil` if that
    /// product's placeholder isn't filled in yet (the paywall softens/disables
    /// the button rather than opening a dead link). Monthly vs yearly is chosen
    /// on the LemonSqueezy page, not in-app.
    static func subscriptionCheckoutURL(tier: ManagedTier) -> URL? {
        switch tier {
        case .starter: return starterCheckoutURL
        case .pro:     return proCheckoutURL
        }
    }

    private static func resolvedURL(_ raw: String) -> URL? {
        guard !raw.hasPrefix("TODO"), let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url
    }
}
