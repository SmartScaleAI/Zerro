//
//  CheckoutReturn.swift
//  Zerro
//
//  The parsed contents of a `zerro://checkout-complete` deep link and the
//  outcome of resolving one. Lemon Squeezy's "Redirect URL after purchase"
//  bounces the browser through getzerro.app/checkout-complete, which
//  forwards the issued `license_key` into the custom scheme. The app does
//  NOT activate automatically — anyone can craft such a link (E-01), so the
//  inbound key is routed into the activation UI PREFILLED and the user must
//  explicitly confirm (tap Activate). The query is UNTRUSTED external input
//  — anything can land in a URL — so the key is sanity-checked before it is
//  ever shown, and any other query params (including a `product` hint an
//  older link may carry) are ignored: the store sells one product, and the
//  License API response — not the link — is what identifies a key's product.
//
//  Kept free of AppKit so the parsing is a pure, unit-testable function (see
//  AppDelegate.resolveCheckoutReturn for the side-effecting resolution).
//

import Foundation

/// The parsed `zerro://checkout-complete?...` query. A `nil` key means the
/// param was absent OR failed validation (a garbage key) — the resolver then
/// falls through to the no-key paywall path rather than POSTing junk to
/// Lemon Squeezy.
struct CheckoutReturn: Equatable {
    /// A sanity-checked license key (plausible length + license charset), or
    /// `nil` when absent/malformed.
    let licenseKey: String?

    /// Parses a checkout-return URL. Returns `nil` for any URL whose host isn't
    /// `checkout-complete` (the caller logs + ignores it).
    static func parse(_ url: URL) -> CheckoutReturn? {
        guard url.host == "checkout-complete" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rawKey = items.first { $0.name == "license_key" }?.value
        return CheckoutReturn(licenseKey: sanitizedKey(rawKey))
    }

    /// Validates an externally-supplied license key. Lemon Squeezy keys are
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
    /// A community build received the link and ignored it. A COMPLETE no-op:
    /// the resolver returns before it refreshes the entitlement, reads or
    /// writes any license or trial storage, contacts Lemon Squeezy, captures
    /// analytics, mutates `paywallTrigger` / `focusActivationFieldOnOpen` /
    /// `prefillLicenseKey` / `purchaseSuccess`, or performs any window effect.
    /// Community builds enforce no licensing and never present the Paywall or
    /// Activate Key windows, so there is nothing for the link to do — with or
    /// without a `license_key`.
    case ignoredCommunity
    /// No key on the link, user already entitled — refreshed silently (an
    /// idempotent re-click). No analytics.
    case silentRefresh
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
