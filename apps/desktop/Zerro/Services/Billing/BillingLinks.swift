//
//  BillingLinks.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  The external Lemon Squeezy URLs the billing UI links out to: the hosted
//  checkout for THE Zerro license (the single product — $39 one-time,
//  covering every Zerro 1.x.x release) and the customer portal ("Manage
//  devices"). Pulled into one place so the surfaces (PaywallView,
//  BillingSection, onboarding) share a single source of truth.
//
//  Each URL is read through `resolvedURL`, which returns `nil` for an
//  unfilled placeholder so the UI can disable/soften the affordance instead
//  of opening a dead link or crashing on a force-unwrap.
//

import Foundation

enum BillingLinks {

    // MARK: - Checkout custom-data (Tier 3 analytics)

    /// The single product tag sent as `custom_data.product` and used as the
    /// `checkout_opened.product` analytics property. One stable value — the
    /// store sells exactly one thing.
    static let checkoutProductValue = "license"

    /// Returns `base` decorated with the Lemon Squeezy custom-data query
    /// params: the app's anonymous PostHog `distinct_id` — so server-side
    /// purchase analytics stitch to the SAME PostHog person as the app
    /// funnel — plus the product tag. The distinct_id is omitted when
    /// analytics hasn't started; the product is always set. Pure URL
    /// construction (callers fire `checkout_opened` + open the result);
    /// brackets are URL-encoded by `URLComponents`, which Lemon Squeezy
    /// decodes back to `checkout[custom][…]`.
    static func checkoutURL(_ base: URL) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = components.queryItems ?? []
        if let distinctId = Analytics.distinctId {
            items.append(URLQueryItem(name: "checkout[custom][ph_distinct_id]", value: distinctId))
        }
        items.append(URLQueryItem(name: "checkout[custom][product]", value: checkoutProductValue))
        components.queryItems = items
        return components.url ?? base
    }

    // MARK: - Test vs. Live checkout switch
    //
    // Lemon Squeezy test mode and live mode are the SAME store domain
    // (store.getzerro.app) but the product has a DISTINCT buy-id per mode.
    // Debug and Staging builds open the TEST checkout (test card numbers, no
    // real charge) — the same environment split `LicenseEditionPolicy` uses
    // for the approved product, so a purchase made from a build always
    // yields a key that same build accepts. Production Release builds use
    // the live buy-id.
    private static let checkoutBase = "https://store.getzerro.app/checkout/buy/"

    /// Picks the test buy-id in Debug/Staging, the live buy-id in production
    /// Release. Keep the direction in lockstep with
    /// `LicenseEditionPolicy.usesTestEnvironment`.
    private static func checkout(test: String, live: String) -> String {
        #if DEBUG || STAGING
        return checkoutBase + test
        #else
        return checkoutBase + live
        #endif
    }

    /// The Lemon Squeezy hosted checkout for the Zerro license. Opening this
    /// in the default browser (NSWorkspace) is the buy flow — the LS overlay
    /// JS is awkward to host in a native app.
    static let licenseCheckoutURLString = checkout(
        test: "1e36ae90-2f72-4dcf-9f30-6d763b10cac1",
        live: "e31278f5-48b6-4265-8d69-37b8c9628e1f"
    )

    /// The Lemon Squeezy customer portal where a buyer manages their license
    /// and devices (used by the at-activation-limit hint and the Settings
    /// "Manage" row).
    static let customerPortalURLString = "https://app.lemonsqueezy.com/my-orders"

    /// The checkout URL, or `nil` while the buy-id is still a placeholder.
    static var licenseCheckoutURL: URL? { resolvedURL(licenseCheckoutURLString) }

    /// The customer-portal URL, or `nil` if still a placeholder.
    static var customerPortalURL: URL? { resolvedURL(customerPortalURLString) }

    /// `nil` if the URL is still a placeholder. Rejects a bare `TODO` prefix AND
    /// any URL whose path still contains a `TODO-` token (the test/live buy-id
    /// switch builds a full URL even from an unfilled id), so a half-filled
    /// product softens the affordance instead of opening a dead checkout.
    /// Internal (not private) so the paywall CTA-gating tests can pin the
    /// placeholder-resolves-nil rule — the thing that disables the buttons —
    /// directly (E-06).
    static func resolvedURL(_ raw: String) -> URL? {
        guard !raw.hasPrefix("TODO"), !raw.contains("TODO-"),
              let url = URL(string: raw), url.scheme != nil else {
            return nil
        }
        return url
    }
}
