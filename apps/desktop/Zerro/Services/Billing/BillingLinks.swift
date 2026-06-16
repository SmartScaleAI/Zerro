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

    // MARK: - Checkout custom-data (Tier 3 analytics)

    /// The purchasable products. Drives both the `checkout_opened.product`
    /// analytics property and the LemonSqueezy `custom_data.product` the webhook
    /// reads back alongside the resolved tier. Raw values match the event spec.
    enum CheckoutProduct: String {
        case subscriptionPro = "subscription_pro"
        case byok = "byok"
        case topupBoost = "topup_boost"
        case topupPower = "topup_power"
    }

    /// Returns `base` decorated with the LemonSqueezy custom-data query params
    /// (Tier 3 §0): the app's anonymous PostHog `distinct_id` — so the webhook's
    /// server-side `subscription_activated`/`_lapsed` stitch to the SAME PostHog
    /// person as the app funnel — plus the product tag. The distinct_id is
    /// omitted when analytics hasn't started; the product is always set. Pure URL
    /// construction (callers fire `checkout_opened` + open the result); brackets
    /// are URL-encoded by `URLComponents`, which LemonSqueezy decodes back to
    /// `checkout[custom][…]`.
    static func checkoutURL(_ base: URL, product: CheckoutProduct) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = components.queryItems ?? []
        if let distinctId = Analytics.distinctId {
            items.append(URLQueryItem(name: "checkout[custom][ph_distinct_id]", value: distinctId))
        }
        items.append(URLQueryItem(name: "checkout[custom][product]", value: product.rawValue))
        components.queryItems = items
        return components.url ?? base
    }

    // MARK: - Test vs. Live checkout switch
    //
    // LemonSqueezy test mode and live mode are the SAME store domain
    // (store.getzerro.app) but each product has a DISTINCT buy-id per mode.
    // DEBUG builds open the TEST checkouts (test card numbers, no real charge),
    // so the full purchase → webhook → credits flow can be exercised locally;
    // Release builds use the live buy-ids. Mirrors the ManagedBackend.baseURL
    // DEBUG/Release convention. To add/rotate a product, edit BOTH the test and
    // live id below — keep them paired.
    private static let checkoutBase = "https://store.getzerro.app/checkout/buy/"

    /// Picks the test buy-id in DEBUG, the live buy-id in Release.
    private static func checkout(test: String, live: String) -> String {
        #if DEBUG
        return checkoutBase + test
        #else
        return checkoutBase + live
        #endif
    }

    /// The LemonSqueezy hosted checkout for the one-time BYOK license.
    /// Opening this in the default browser (NSWorkspace) is the v1 buy flow —
    /// the LS overlay JS is awkward to host in a native app.
    static let byokCheckoutURLString = checkout(
        test: "1e36ae90-2f72-4dcf-9f30-6d763b10cac1",
        live: "e31278f5-48b6-4265-8d69-37b8c9628e1f"
    )

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

    // Single Managed product; monthly vs yearly is chosen ON the LS page, so
    // one checkout link covers both intervals. Starter is not sold at launch —
    // if a Starter tier returns later, give it its own test/live pair here.
    static let proCheckoutURLString = checkout(
        test: "4ab963c6-7e81-473b-b815-ecc163584539",
        live: "889b1ee8-9e71-422f-a714-362a2ca3ff39"
    )

    static var proCheckoutURL: URL? { resolvedURL(proCheckoutURLString) }

    // MARK: - Top-up pack checkouts (multi-model Phase 6 / plan §1.4)
    //
    // The hosted checkout for each ONE-TIME top-up pack: Boost (200 credits,
    // $10) and Power (500 credits, $22). Purchased credits attach to the
    // buyer's subscription server-side (the `order_created` webhook) and
    // expire 12 months from purchase. Same resolve-to-nil pattern: the
    // low-balance prompt hides a pack whose link isn't filled in yet.
    static let boostTopupCheckoutURLString = checkout(
        test: "f3518fc2-6dff-47e1-bffd-3def5a1c05a6",
        live: "4bd1167b-a0d8-49ab-b572-e3704fce63fc"
    )
    static let powerTopupCheckoutURLString = checkout(
        test: "48b7b929-7d0f-4a12-9098-a2ed75aceba5",
        live: "a73f69a9-0e23-470a-bc8d-3b272d0c8df5"
    )

    static var boostTopupCheckoutURL: URL? { resolvedURL(boostTopupCheckoutURLString) }
    static var powerTopupCheckoutURL: URL? { resolvedURL(powerTopupCheckoutURLString) }

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
        case .starter: return proCheckoutURL  // Starter not sold at launch → Managed/Pro checkout
        case .pro:     return proCheckoutURL
        }
    }

    /// `nil` if the URL is still a placeholder. Rejects a bare `TODO` prefix AND
    /// any URL whose path still contains a `TODO-` token (the test/live buy-id
    /// switch builds a full URL even from an unfilled id), so a half-filled
    /// product softens the affordance instead of opening a dead checkout.
    private static func resolvedURL(_ raw: String) -> URL? {
        guard !raw.hasPrefix("TODO"), !raw.contains("TODO-"),
              let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url
    }
}
