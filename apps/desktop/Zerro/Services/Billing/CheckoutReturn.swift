//
//  CheckoutReturn.swift
//  Zerro
//
//  The parsed contents of a `zerro://checkout-complete` deep link and the
//  outcome of resolving one. LemonSqueezy's per-product "Redirect URL after
//  purchase" bounces the browser through getzerro.app/checkout-complete, which
//  forwards the issued `license_key` (and a `product` hint) into the custom
//  scheme. The app does NOT activate automatically — anyone can craft such a
//  link (E-01), so the inbound key is routed into the activation UI PREFILLED
//  and the user must explicitly confirm (tap Activate). Both query values are
//  UNTRUSTED external input — anything can land in a URL — so the key is
//  sanity-checked and the product is mapped through a closed enum before we
//  ever touch the network.
//
//  Kept free of AppKit so the parsing is a pure, unit-testable function (see
//  AppDelegate.resolveCheckoutReturn for the side-effecting resolution).
//

import Foundation

/// The parsed `zerro://checkout-complete?...` query. `nil` fields mean the
/// param was absent OR failed validation (a garbage key, an unknown product) —
/// the resolver then falls through to the no-key paywall path rather than
/// POSTing junk to LemonSqueezy.
struct CheckoutReturn: Equatable {
    /// A sanity-checked license key (plausible length + license charset), or
    /// `nil` when absent/malformed.
    let licenseKey: String?

    /// The purchased product, mapped from the `product` hint, or `nil` when
    /// absent/unrecognized. Parsed for logging/diagnostics only — since E-01 the
    /// resolver no longer auto-activates, so it is NOT forwarded to
    /// `EntitlementStore.activate` as an `expectedProduct` hint; the user
    /// activates the prefilled key explicitly and the `/session` probe alone
    /// disambiguates BYOK vs Managed (the manual-paste path never hinted either).
    let productKind: LicenseProductKind?

    /// Parses a checkout-return URL. Returns `nil` for any URL whose host isn't
    /// `checkout-complete` (the caller logs + ignores it).
    static func parse(_ url: URL) -> CheckoutReturn? {
        guard url.host == "checkout-complete" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rawKey = items.first { $0.name == "license_key" }?.value
        let rawProduct = items.first { $0.name == "product" }?.value
        return CheckoutReturn(
            licenseKey: sanitizedKey(rawKey),
            productKind: productKind(from: rawProduct)
        )
    }

    /// Maps the `product` query hint to a `LicenseProductKind`. Unknown/missing
    /// values map to `nil` (the activation then leans entirely on the backend
    /// probe to disambiguate). Closed switch — a new product is an explicit edit.
    static func productKind(from product: String?) -> LicenseProductKind? {
        switch product {
        case "subscription_pro": return .managed
        case "byok": return .byok
        default: return nil
        }
    }

    /// Validates an externally-supplied license key. LemonSqueezy keys are
    /// UUID-shaped (hex + dashes), but to stay tolerant of a future format
    /// change we accept any trimmed, non-empty value of a plausible length whose
    /// characters are the safe license alphabet (hex digits + dash). Anything
    /// outside that — empty, absurdly long, or carrying unexpected characters —
    /// is dropped to `nil` so a hand-edited or corrupt link never reaches the
    /// network. No force-unwraps.
    private static func sanitizedKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(key.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard key.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return key
    }
}

/// The terminal classification of resolving a checkout return — drives both the
/// `purchase_activated` analytics `outcome` and the unit-test assertions. The
/// side effects (bring app forward / dismiss / open paywall) are performed by
/// the resolver; this only records WHICH branch ran.
enum CheckoutOutcome: Equatable {
    /// No key on the link, user already entitled, but no credit increase was
    /// observed (or no credit balance to diff) — credits refreshed silently as
    /// before. No analytics (parity with prior behavior).
    case silentRefresh
    /// No key on the link, user already entitled, AND a credit increase was
    /// observed — showed the top-up confirmation. Analytics
    /// `purchase_success_shown` (`plan: topup`).
    case topupConfirmed
    /// No key on the link, user not entitled — opened the paywall focused on
    /// the activation field (a brand-new buyer must paste). No analytics.
    case openedPaywallNoKey
    /// The link's key already activates this device — treated as success
    /// without re-POSTing (idempotent re-click of a genuine purchase; not
    /// spoofable, since it requires THIS device's exact active key). Shows the
    /// success confirmation. NO `purchase_activated` analytics — the deep link
    /// itself never counts as a purchase outcome (E-01).
    case alreadyActive
    /// The link carried a (different, or first-time) key: it was routed into the
    /// activation UI PREFILLED + focused so the user can explicitly confirm.
    /// Nothing is activated and NO purchase analytics fire here — a hostile or
    /// spoofed `zerro://` link can neither silently activate a key nor pollute
    /// the purchase funnel. The real `purchase_activated` is emitted only when
    /// the user taps Activate (E-01).
    case prefilled
}
