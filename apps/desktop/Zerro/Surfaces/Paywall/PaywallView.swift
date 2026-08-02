//
//  PaywallView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  The paywall window's content. Opened ONLY by the recording-start gate
//  when `EntitlementStore.canGenerate` is false (state `.expired`); it never
//  auto-presents at launch (the Window scene uses
//  `.defaultLaunchBehavior(.suppressed)`).
//
//  Reuses the onboarding window's visual chrome wholesale — the same
//  `OnboardingStepLayout`, logo tile, primary/secondary button styles,
//  `vfPanelBackground`, and spacing tokens — so the two surfaces read as one
//  app. Copy is non-punitive (the trial ended, here's how to keep going).
//
//  Three buy paths (billing-plan §8), laid out to mirror the website's
//  pricing section (apps/web/…/axis/pricing.tsx): the two plans side by
//  side — Managed leading left (the recommended path, accent-highlighted,
//  "Most popular"), BYOK right — with the shared activate row below:
//    • Managed — THE Zerro-hosted credit subscription (Phase E). Monthly vs
//      yearly ($12/mo billed annually) is chosen on the LemonSqueezy
//      checkout page. Sends the recording to Zerro's server for processing —
//      surfaced honestly in the privacy note below.
//    • BYOK — pay once, fund generation with your own provider keys. "Get a
//      license" opens the LemonSqueezy hosted checkout (NSWorkspace). Fully
//      LOCAL: recordings never leave the Mac.
//    • Activate — one shared "enter your key" field (reusing the Phase C
//      `LicenseService.activate` path) handles BOTH a BYOK license and a
//      subscription key: `EntitlementStore.activate` probes the backend to
//      resolve which, then sets `.byok` or `.managed`. On success the paywall
//      dismisses (the gate now passes).
//
//  Checkout URLs + prices are `// TODO:` placeholders until the LS account /
//  products are live (see `BillingLinks` / `Price`); each resolves-to-nil and
//  no-ops cleanly when unset.
//
//  // DEFERRED: auto-pull the subscription license post-checkout (so the user
//  doesn't have to paste a key). v1 reuses the Phase C enter-key path.
//

import AppKit
import os
import SwiftUI

// MARK: - Dynamic paywall copy

/// The headline + subheadline shown at the top of the paywall, derived from
/// WHY the window was opened (`EntitlementStore.paywallTrigger`) and the
/// current entitlement (`EntitlementState`). The window is no longer only the
/// blocked-trial wall — the menu-bar "Upgrade" entry point opens it in a
/// voluntary-upgrade / add-credits / manage context too, so the copy adapts
/// instead of always saying "You've used your free generations".
///
/// Pure + `Equatable` so it's unit-tested directly (trigger + state → copy)
/// without standing up the view.
struct PaywallCopy: Equatable {
    let headline: String
    let subheadline: String
    /// The window title-bar text, shown as "Zerro: <windowTitle>". Tracks
    /// the context so the chrome matches the body (e.g. "Add Credits" when a
    /// Managed user tops up, not the generic "Unlock").
    let windowTitle: String

    /// Resolves the copy. `.expired` is the genuinely-gated state, so it ALWAYS
    /// gets the blocked copy even if a stale trigger survived; otherwise the
    /// explicit trigger wins, and a `nil` trigger falls back to a sensible copy
    /// for the state so the window never shows the wrong context.
    static func resolve(trigger: EntitlementStore.PaywallTrigger?, state: EntitlementState) -> PaywallCopy {
        if case .expired = state { return .blocked }
        if case .byokTrialExpired = state { return .byokTrialComplete }

        switch trigger {
        case .byokTrialExhausted:
            return .byokTrialComplete
        case .blocked:
            return .blocked
        case .voluntaryUpgrade:
            return .upgrade
        case .topup, .outOfCredits:
            return .topup
        case .manage, .subscriptionInactive, .apiKeyMissing:
            return .manage
        case nil:
            switch state {
            case .trial, .byokTrial: return .upgrade
            case .managed, .byok:   return .manage
            case .expired:          return .blocked  // unreachable (handled above)
            case .byokTrialExpired: return .byokTrialComplete
            }
        }
    }

    /// Trial exhausted (the original wall). Copy unchanged from v1.
    static let blocked = PaywallCopy(
        headline: "You\u{2019}ve used your free generations",
        subheadline: "Keep turning a quick screen recording and a sentence of narration into a ready-to-paste result. Pick the option that fits how you work.",
        windowTitle: "Unlock"
    )
    static let byokTrialComplete = PaywallCopy(
        headline: "Your own-key trial is complete",
        subheadline: "You finished 10 successful generations with your own provider keys. Get a BYOK license to keep your direct, private setup.",
        windowTitle: "Keep Using Your Keys"
    )
    /// Voluntary upgrade from an active trial — lead with the Managed value,
    /// reassure the trial still works.
    static let upgrade = PaywallCopy(
        headline: "Upgrade your plan",
        subheadline: "Your Zerro Cloud Trial is still active, so upgrade whenever you\u{2019}re ready. Zerro Cloud gives you 300 credits a month across all \(ModelRegistry.selectableCountWord) models, with no API keys required.",
        windowTitle: "Upgrade"
    )
    /// Managed user adding credits — point straight at the top-up packs.
    /// Carries the B-07 metering-floor note (the shared CreditDisplay string)
    /// so the credits-focused paywall states it too.
    static let topup = PaywallCopy(
        headline: "Add Credits",
        subheadline: "Top up now to keep generating, or wait for next month's credits to renew. Credits attach to your subscription instantly and carry over for 12 months. \(CreditDisplay.minimumChargeNote)",
        windowTitle: "Add Credits"
    )
    /// Entitled user managing their plan — de-emphasize the sell.
    static let manage = PaywallCopy(
        headline: "Manage your plan",
        subheadline: "Switch options, activate a key, or manage your devices and billing. Everything for your plan lives here.",
        windowTitle: "Manage Plan"
    )

    /// The Managed plan card's subtitle. Hoisted out of `PaywallView.body` so the
    /// model-count copy guard can assert on it like the other copy constants.
    static let managedCardSubtitle =
        "Zerro handles model access. 300 credits a month across all \(ModelRegistry.selectableCountWord) models, no API key required. $12/mo if you choose yearly billing."
}

struct PaywallView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(EntitlementStore.self) private var entitlements

    /// Window width. Sized for the two side-by-side plan cards (website
    /// pricing parity) with comfortable padding — each card gets ~350pt.
    /// The Window scene uses `.windowResizability(.contentSize)`, so this
    /// frame IS the window size; nothing else pins it.
    private static let windowWidth: CGFloat = 760

    /// The trigger captured at open time. `paywallTrigger` is read-then-cleared
    /// on appear (so a later open isn't mislabeled), but the dynamic copy needs
    /// the value for the window's whole lifetime — so we snapshot it here. Until
    /// the first capture, `copy` reads the live store directly (no first-render
    /// flash); `onChange` re-captures if a fresh trigger is set while the window
    /// stays mounted (the menu re-opens an already-open window).
    @State private var capturedTrigger: EntitlementStore.PaywallTrigger?
    @State private var didCaptureTrigger = false

    /// Latched true when a checkout-return deep link delivers a key while the
    /// user is already `.managed` (E-01). The Managed surface otherwise shows
    /// only the top-up packs, so without this the prefilled key would be stranded
    /// with no field to enter it. The latch persists for the window's lifetime so
    /// the field stays mounted after `ActivateLicenseCard` consumes the one-shot
    /// prefill flags. Only a Managed subscriber activating a DIFFERENT key (e.g.
    /// a separately-bought BYOK license) reaches it.
    @State private var managedActivatePending = false

    private var copy: PaywallCopy {
        let trigger = didCaptureTrigger ? capturedTrigger : entitlements.paywallTrigger
        return PaywallCopy.resolve(trigger: trigger, state: entitlements.state)
    }

    var body: some View {
        // The purchase-success confirmation takes precedence over the whole
        // PaywallCopy matrix: once an activation/top-up lands, the window shows
        // "you're all set" instead of the headline + plan cards + activate field.
        Group {
            if let success = entitlements.purchaseSuccess {
                PurchaseSuccessView(info: success)
            } else {
                mainPanel
            }
        }
            .frame(width: Self.windowWidth)
            .background(Color.vfPanelBackground)
            // Title-bar text tracks the context (the static Window() label is
            // the generic "Unlock"; this overrides it per trigger so e.g. a
            // top-up reads "Zerro — Add Credits").
            .navigationTitle("Zerro: \(copy.windowTitle)")
            .onAppear {
                // Tier 3 analytics: the gate stashes WHY the paywall opened
                // (`manual` when there's no preflight reason, e.g. an expired
                // trial). Read once, then clear so a later open isn't mislabeled.
                Analytics.capture("paywall_shown", [
                    "trigger": entitlements.paywallTrigger?.rawValue ?? "manual"
                ])
                capturedTrigger = entitlements.paywallTrigger
                didCaptureTrigger = true
                entitlements.paywallTrigger = nil
                latchManagedActivateIfNeeded()
            }
            .onChange(of: entitlements.paywallTrigger) { _, newValue in
                // A fresh open while the window is already on screen (the menu
                // re-routes openWindow to the existing window, so onAppear won't
                // fire again) — re-snapshot so the copy tracks the new context.
                guard let newValue else { return }
                capturedTrigger = newValue
                didCaptureTrigger = true
                entitlements.paywallTrigger = nil
            }
            // A deep-link key arriving while the (Managed) window is already open
            // re-routes here rather than re-firing onAppear — latch then too, so
            // the activate field appears for the Managed user (E-01).
            .onChange(of: entitlements.prefillLicenseKey) { _, key in
                if key != nil { latchManagedActivateIfNeeded() }
            }
    }

    /// Latches `managedActivatePending` when a checkout-return prefill is pending
    /// for a Managed user. Keyed strictly on `prefillLicenseKey` (the deep-link-
    /// with-key path always sets it) — NOT `focusActivationFieldOnOpen`, which the
    /// no-key "brand-new buyer must paste" path also sets and which, if left stale
    /// on the long-lived store, would otherwise surface an empty activate field to
    /// a Managed user. Safe to read the flag here: the Managed branch doesn't
    /// mount `ActivateLicenseCard` until this latch flips, so nothing has consumed
    /// (cleared) it yet.
    private func latchManagedActivateIfNeeded() {
        guard case .managed = entitlements.state, entitlements.prefillLicenseKey != nil else { return }
        managedActivatePending = true
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text(copy.headline)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text(copy.subheadline)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            optionStack
        }
        .frame(minHeight: 600)
    }

    // MARK: - Options

    /// The option stack adapts to the entitlement (the consolidation target):
    ///   • Managed   → the single "Add Credits" card (the one purchasable thing
    ///                 left). No re-sell, no manage link, no activate field — a
    ///                 Managed user already holds the plan and a key — EXCEPT when
    ///                 a checkout-return deep link delivered a different key to
    ///                 activate (E-01), where the activate card is surfaced so the
    ///                 key isn't stranded.
    ///   • BYOK      → a manage link only (BYOK funds locally; no credits to
    ///                 top up, no plan to upgrade to) + the activate field.
    ///   • Trial/Expired → the plan sell: Managed + BYOK side by side + activate.
    @ViewBuilder
    private var optionStack: some View {
        // Managed is its own self-contained surface: the "Add Credits" card (plus,
        // only when a deep-link key is pending, the activate field). Return early
        // so none of the manage/sell affordances below render for this state.
        if case .managed = entitlements.state {
            VStack(spacing: VFSpacing.md) {
                AddCreditsCard()
                if managedActivatePending {
                    ActivateLicenseCard(onActivated: showActivationSuccess)
                }
            }
        } else {
            nonManagedOptions
        }
    }

    /// Everything for the non-Managed states (trial/expired/byok): the plan sell
    /// cards (trial/expired), a manage link (byok), and the shared activate field.
    private var nonManagedOptions: some View {
        VStack(spacing: VFSpacing.md) {
            if showsPlanCards {
                // The two plans SIDE BY SIDE (website pricing parity): Managed
                // leads left — the recommended path, accent-highlighted — BYOK
                // right. Shown only to users without a plan yet (trial/expired);
                // an entitled user sees the manage link instead, not a re-sell.
                HStack(alignment: .top, spacing: VFSpacing.md) {
                    // Managed — THE plan (multi-model §1.3): Zerro-hosted
                    // credits, all five models, no API keys to manage. Monthly vs
                    // yearly ($12/mo billed annually) is chosen on the
                    // LemonSqueezy page.
                    SubscriptionOptionCard(
                        title: "Zerro Cloud",
                        subtitle: PaywallCopy.managedCardSubtitle
                    )

                    // BYOK — $69 one-time license; the user funds generation with
                    // their own provider API keys. Fully local.
                    BuyOnceCard()
                }
                // Size the row to the TALLER card's natural content height rather
                // than a fixed pixel height: both cards still fill it (`fillsHeight`)
                // so they stay EQUAL height with bottom-aligned CTAs, but there's no
                // dead space above the buttons when the copy is short.
                .fixedSize(horizontal: false, vertical: true)

                // Honest privacy note (§14.5): Managed transits the server; BYOK
                // stays local. Don't let the local-first claim cover Managed.
                ManagedPrivacyNote()
            }

            // An entitled user (Managed/BYOK) gets a manage affordance instead of
            // the sell cards — change card / plan / devices in the portal.
            if showsManageLink {
                ManagePlanLink()
            }

            // One shared activation path for an already-purchased key (BYOK or
            // subscription) — whether the user pasted it or the checkout-return
            // deep link prefilled it. On success, show the same "you're all set"
            // confirmation the deep-link path uses — don't bare-dismiss.
            ActivateLicenseCard(
                onActivated: showActivationSuccess
            )
        }
    }

    /// Activation succeeded: derive the confirmation from the now-paid state and
    /// route through `purchaseSuccess` so the success screen shows. Defensively
    /// dismisses if there's somehow no paid state to confirm. The `method` tracks
    /// how the key arrived (`deeplink` when the checkout-return link prefilled the
    /// field, otherwise `manual_paste`) so the funnel attribution stays accurate.
    private func showActivationSuccess(origin: PaywallActivationModel.Origin) {
        guard let info = PurchaseSuccessInfo.fromActivatedState(entitlements.state) else {
            dismissWindow(id: PaywallScene.windowID)
            return
        }
        entitlements.purchaseSuccess = info
        let method = origin == .deeplink ? "deeplink" : "manual_paste"
        Analytics.capture("purchase_success_shown", ["method": method, "plan": info.analyticsPlan])
    }

    /// The plan sell shows only to users who don't have a plan yet.
    private var showsPlanCards: Bool {
        switch entitlements.state {
        case .trial, .expired, .byokTrial, .byokTrialExpired: return true
        case .byok, .managed:  return false
        }
    }

    /// The manage link shows only to users who already hold a plan.
    private var showsManageLink: Bool {
        switch entitlements.state {
        case .byok, .managed:  return true
        case .trial, .expired, .byokTrial, .byokTrialExpired: return false
        }
    }
}

// MARK: - Price labels

/// DISPLAY-ONLY price labels for the paywall cards. LemonSqueezy is the actual
/// source of truth for what the customer is charged — these strings are just
/// the labels we render, and MUST be kept in sync with the LemonSqueezy product
/// prices by hand (the app never sets the charge). The cards currently show the
/// monthly price; the yearly option is presented on the LemonSqueezy checkout
/// page (no in-app period toggle), and `*Yearly` are kept here as the canonical
/// record of those numbers. One place, no scattered literals.
private enum Price {
    // Multi-model plan §1.3: BYOK is a $69 one-time license with 1 year of
    // updates; the SINGLE Managed plan is $15/mo (or $12/mo billed yearly).
    // KEEP IN SYNC with the LemonSqueezy variant prices — see the release
    // checklist in docs/DEPLOY-RUNBOOK.md §5 (E-05). The Managed card
    // subtitle's "$12/mo if you choose yearly billing" repeats the yearly
    // number in prose and must move with it.
    static let byok = "$69 one-time"
    static let managedMonthly = "$15/mo"
    static let managedYearly = "$144/yr"
}

// MARK: - Activation model

/// Drives the shared "enter your key" flow. Mirrors `APIKeyFieldModel`'s shape:
/// a small `@Observable` field model with an explicit phase the pill renders
/// against. Works for BOTH a BYOK license and a subscription key — the store's
/// `activate` probes the backend to resolve which.
@MainActor
@Observable
final class PaywallActivationModel {
    /// The activation lifecycle the UI renders. `failed` carries the
    /// user-facing copy plus whether to offer the "Manage devices" portal
    /// link (only meaningful for the at-activation-limit case).
    enum Phase: Equatable {
        case idle
        case activating
        case activated
        case failed(message: String, showManageDevices: Bool)
    }

    /// Where the key in the field came from. Drives the `purchase_activated`
    /// funnel analytics: a `.deeplink` key (the checkout-return link PREFILLED
    /// it) emits `purchase_activated` on the user's explicit Activate tap, so the
    /// purchase funnel still records the conversion — but gated on a REAL
    /// user-initiated outcome, never on merely opening a (possibly spoofed)
    /// `zerro://` link (E-01). A `.manualPaste` key fires only the existing
    /// `purchase_success_shown` on success, exactly as before.
    enum Origin: Equatable {
        case manualPaste
        case deeplink
    }

    /// License/subscription keys aren't as sensitive as API keys, so the field
    /// is shown in plain text with a paste affordance — friendlier than a
    /// masked field.
    var licenseKey: String = ""
    var phase: Phase = .idle
    /// Defaults to manual paste; flipped to `.deeplink` when the checkout-return
    /// deep link prefills the field (see `ActivateLicenseCard.adoptPrefillIfPresent`).
    var origin: Origin = .manualPaste

    /// Analytics sink for the `purchase_activated` funnel event. Injectable —
    /// mirroring `AppDelegate.CheckoutReturnEffects.capture` — so unit tests can
    /// observe the gated emission without a live PostHog (`Analytics.capture` is
    /// a no-op until `Analytics.start()` runs). Production forwards to the global.
    @ObservationIgnored
    var capture: (_ event: String, _ properties: [String: Any]) -> Void = { Analytics.capture($0, $1) }

    var trimmedKey: String {
        licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Editing after a terminal state demotes back to `.idle` so the pill
    /// stops showing a stale error/success while the user retypes.
    func handleEdit() {
        if case .activating = phase { return }
        if phase != .idle { phase = .idle }
    }

    /// Runs activation through the shared `EntitlementStore`. On success calls
    /// `onSuccess` (the paywall shows the confirmation); on a `LicenseError`
    /// renders the typed copy. No product hint — the backend probe in `activate`
    /// decides BYOK vs Managed.
    ///
    /// This is the SINGLE place an activation attempt the user initiated emits
    /// `purchase_activated` (deep-link origin only — see `Origin`). The
    /// checkout-return handler no longer fires it, so a hostile/spoofed link
    /// can't pollute the purchase funnel (E-01).
    func activate(using entitlements: EntitlementStore, onSuccess: @escaping () -> Void) {
        Task { @MainActor in
            if await performActivation(using: entitlements) { onSuccess() }
        }
    }

    /// The awaitable activation core, split out of `activate` so it's directly
    /// unit-testable without the fire-and-forget Task. Owns the phase transitions
    /// and the gated `purchase_activated` emission; returns `true` on success.
    @discardableResult
    func performActivation(using entitlements: EntitlementStore) async -> Bool {
        let key = trimmedKey
        guard !key.isEmpty else {
            phase = .failed(message: "Enter your license key to continue.", showManageDevices: false)
            return false
        }
        phase = .activating
        do {
            try await entitlements.activate(licenseKey: key)
            phase = .activated
            // Resolve the product from the now-paid state (byok/managed); the
            // outcome is real and server-confirmed, so the funnel can record it.
            capturePurchaseOutcome("success", product: PurchaseSuccessInfo.fromActivatedState(entitlements.state)?.analyticsPlan ?? "unknown")
            return true
        } catch LicenseError.replaceCancelled {
            // The user declined the "replace your current license?" prompt
            // (E-01). Not a failure — a quiet no-op. Return to idle, show no
            // error, and emit NOTHING (a spoofed/mistaken key must never look
            // like a real failed purchase in the funnel).
            phase = .idle
            return false
        } catch let error as LicenseError {
            phase = .failed(
                message: error.userFacingMessage,
                showManageDevices: error == .atActivationLimit
            )
            capturePurchaseOutcome("failed", product: "unknown")
            return false
        } catch {
            phase = .failed(message: "Activation failed. Please try again.", showManageDevices: false)
            capturePurchaseOutcome("failed", product: "unknown")
            return false
        }
    }

    /// Emits `purchase_activated` for a deep-link-originated activation attempt
    /// (the funnel's conversion event), gated so it fires ONLY on a real,
    /// user-initiated outcome. A manual paste emits nothing here — it keeps its
    /// existing `purchase_success_shown`-on-success behavior.
    private func capturePurchaseOutcome(_ outcome: String, product: String) {
        guard origin == .deeplink else { return }
        capture("purchase_activated", [
            "product": product,
            "method": "deeplink",
            "outcome": outcome
        ])
    }
}

// MARK: - Buy-once (BYOK) card

/// The BYOK purchase card: pay once, fund with your own provider keys.
/// Activation of the resulting key happens through the shared
/// `ActivateLicenseCard` below. Fills the plan-cards row so it matches the
/// Managed card's height; the Spacer pins the CTA to the bottom edge.
private struct BuyOnceCard: View {
    var body: some View {
        OptionCardChrome(padding: VFSpacing.lg, fillsHeight: true) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bring your own key")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.sm)
                Text(Price.byok)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text("Pay once, and it includes 1 year of updates. Use your own API keys (OpenAI, Gemini, Anthropic) and pay providers directly. Recordings never pass through Zerro\u{2019}s servers; they go straight to your provider.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: VFSpacing.xs)

            // E-06: softens to disabled while the checkout URL is still a
            // placeholder (mirrors the top-up card) — no enabled-looking
            // button that dead-clicks into the placeholder log below.
            OnboardingPrimaryButton(
                "Get a license",
                isEnabled: BillingLinks.byokCheckoutURL != nil,
                action: openCheckout
            )
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.byokCheckoutURL else {
            Log.billing.notice("paywall: BYOK checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening BYOK checkout in browser")
        // Tier 3 analytics: fire `checkout_opened` and open the custom-data-
        // decorated URL (carries ph_distinct_id + product for webhook stitching).
        Analytics.capture("checkout_opened", [
            "product": BillingLinks.CheckoutProduct.byok.rawValue,
            "placement": "paywall"
        ])
        // Resolve the affiliate referral (server-side IP match) before opening so
        // the sale is attributed; nil-safe + time-boxed so it never blocks checkout.
        Task {
            let affRef = await AffiliateAttribution.referralCode()
            let checkout = BillingLinks.checkoutURL(url, product: .byok, affRef: affRef)
            await MainActor.run { NSWorkspace.shared.open(checkout) }
        }
    }
}

// MARK: - Subscription (Managed) card

/// The Managed subscription card — the recommended path, so it carries the
/// website pricing section's hierarchy cues: an accent-highlighted chrome
/// and a "Most popular" badge (pricing.tsx renders the same pair). Opens the
/// LemonSqueezy subscription checkout in the browser (same pattern as BYOK) —
/// monthly vs yearly is chosen on the checkout page. The user activates the
/// issued key afterward via the shared `ActivateLicenseCard`.
private struct SubscriptionOptionCard: View {
    @Environment(EntitlementStore.self) private var entitlements
    let title: String
    let subtitle: String

    var body: some View {
        OptionCardChrome(padding: VFSpacing.lg, fillsHeight: true, highlighted: true) {
            HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                MostPopularBadge()
                Spacer(minLength: VFSpacing.sm)
                Text(Price.managedMonthly)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: VFSpacing.xs)

            // E-06: softens to disabled while the checkout URL is still a
            // placeholder (mirrors the top-up card) — no dead clicks.
            OnboardingPrimaryButton(
                "Subscribe to \(title)",
                isEnabled: BillingLinks.subscriptionCheckoutURL() != nil,
                tint: .vfDevAccent,
                action: openCheckout
            )
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.subscriptionCheckoutURL() else {
            Log.billing.notice("paywall: managed checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening managed subscription checkout")
        // Tier 3 analytics: the single Managed subscription is sold here.
        Analytics.capture("checkout_opened", [
            "product": BillingLinks.CheckoutProduct.subscriptionPro.rawValue,
            "placement": "paywall"
        ])
        // A converting trial user carries their grant id so the webhook links
        // this subscription to that exact trial grant (combined-spend un-stranding).
        // Affiliate referral (server-side IP match) is resolved first so the sale
        // is attributed; nil-safe + time-boxed so it never blocks checkout.
        let grantId = entitlements.trialGrantIdForCheckout
        Task {
            let affRef = await AffiliateAttribution.referralCode()
            let checkout = BillingLinks.checkoutURL(url, product: .subscriptionPro, trialGrantId: grantId, affRef: affRef)
            await MainActor.run { NSWorkspace.shared.open(checkout) }
        }
    }
}

// MARK: - Privacy note

/// Honest one-liner on where recordings go (§14.5). Understated secondary text.
private struct ManagedPrivacyNote: View {
    var body: some View {
        Text("Zerro Cloud sends your recording to Zerro\u{2019}s server, which forwards it to a third-party AI provider (OpenAI, Google, or Anthropic) to generate your prompt. Bring-your-own-key skips our servers and goes straight to that provider on your own key.")
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextTertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Add credits (Managed only)

/// The Managed "Add Credits" surface: a single card that opens the one
/// multi-variant "Credit Packs" checkout. The customer picks WHICH pack
/// (50–10,000 credits, $5–$300) on the LemonSqueezy page, so the app links out
/// once rather than rendering a card per pack. Managed-only by construction —
/// `optionStack` gates on `.managed`, and BYOK/trial never reach it. Fires
/// `checkout_opened` (Tier 3 §0, `paywall` placement) and opens the custom-data-
/// decorated URL; the button softens to disabled when the checkout URL is still
/// a placeholder (`topupCheckoutURL == nil`) rather than opening a dead link.
private struct AddCreditsCard: View {
    var body: some View {
        OptionCardChrome(
            padding: VFSpacing.lg,
            backgroundColor: .vfCardBackground
        ) {
            Text("Choose a pack on the next screen, from 50 to 10,000 credits. Credits are added to your balance and carry over for 12 months.")
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            OnboardingPrimaryButton(
                "Add Credits",
                isEnabled: BillingLinks.topupCheckoutURL != nil,
                action: openCheckout
            )
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.topupCheckoutURL else {
            Log.billing.notice("paywall: top-up checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening top-up checkout")
        Analytics.capture("checkout_opened", [
            "product": BillingLinks.CheckoutProduct.topup.rawValue,
            "placement": "paywall"
        ])
        // Affiliate referral (server-side IP match) resolved first so the sale is
        // attributed; nil-safe + time-boxed so it never blocks checkout.
        Task {
            let affRef = await AffiliateAttribution.referralCode()
            let checkout = BillingLinks.checkoutURL(url, product: .topup, affRef: affRef)
            await MainActor.run { NSWorkspace.shared.open(checkout) }
        }
    }
}

// MARK: - Manage plan link (entitled users)

/// Shown to an entitled user (Managed/BYOK) in place of the sell cards: a quiet
/// link to the LemonSqueezy customer portal to change card / plan / devices or
/// cancel. No-op (with a log) until the portal URL placeholder is filled.
private struct ManagePlanLink: View {
    var body: some View {
        OptionCardChrome(alignment: .leading) {
            OnboardingSecondaryButton("Manage plan & billing") {
                guard let url = BillingLinks.customerPortalURL else {
                    Log.billing.notice("paywall: customer portal URL not configured yet (placeholder)")
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Activate-license card (shared)

/// The shared "already purchased? enter your key" flow. Accepts BOTH a BYOK
/// license and a subscription key — `EntitlementStore.activate` resolves which
/// via a backend probe. Self-contained so the field state lives with the card.
private struct ActivateLicenseCard: View {
    @Environment(EntitlementStore.self) private var entitlements
    /// Called when activation succeeds — the paywall shows the confirmation. The
    /// `Origin` says whether the key was pasted or deep-link-prefilled, so the
    /// success analytics attribute the `method` correctly.
    let onActivated: (PaywallActivationModel.Origin) -> Void

    @State private var model = PaywallActivationModel()
    @State private var isEntering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        OptionCardChrome(alignment: .leading) {
            if isEntering {
                Text("Enter your license or subscription key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                activationField
            } else {
                OnboardingSecondaryButton("Already have a key? Activate it") {
                    isEntering = true
                    fieldFocused = true
                }
            }
        }
        // Checkout-return deep link: a brand-new buyer who must paste their key
        // lands here with the field already open + focused (the store sets the
        // one-shot flag before opening the window). `onAppear` covers a fresh
        // window; `onChange` covers the flag flipping while the window is already
        // on screen (the deep link re-routes to the existing window).
        .onAppear(perform: focusActivationIfRequested)
        .onAppear(perform: adoptPrefillIfPresent)
        .onChange(of: entitlements.focusActivationFieldOnOpen) { _, requested in
            if requested { focusActivationIfRequested() }
        }
        // Checkout-return FAILURE: the deep link set `prefillLicenseKey` to the
        // attempted (rejected) key so the user can see + retry it. Adopt it
        // whether the window was just opened (onAppear) or the flag flipped while
        // it was already on screen (onChange).
        .onChange(of: entitlements.prefillLicenseKey) { _, key in
            if key != nil { adoptPrefillIfPresent() }
        }
    }

    /// Reads + clears the one-shot focus flag, opening straight into the
    /// activation field. The async hop lets the TextField mount before we focus.
    private func focusActivationIfRequested() {
        guard entitlements.focusActivationFieldOnOpen else { return }
        entitlements.focusActivationFieldOnOpen = false
        isEntering = true
        Task { @MainActor in fieldFocused = true }
    }

    /// Reads + clears the one-shot prefill, populating the field with the key the
    /// checkout-return deep link delivered so the user can review it and tap
    /// Activate (E-01 — the link never auto-activates). Marks the origin
    /// `.deeplink` so a successful confirm still records the purchase funnel
    /// event. Demotes the phase to `.idle` so no stale pill shows over it.
    private func adoptPrefillIfPresent() {
        guard let key = entitlements.prefillLicenseKey else { return }
        entitlements.prefillLicenseKey = nil
        isEntering = true
        model.licenseKey = key
        model.origin = .deeplink
        model.phase = .idle
    }

    // MARK: Activation field

    @ViewBuilder
    private var activationField: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                TextField("License or subscription key", text: $model.licenseKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .focused($fieldFocused)
                    .onChange(of: model.licenseKey) { _, _ in model.handleEdit() }
                    .onSubmit(runActivation)
                    .padding(.horizontal, VFSpacing.md)
                    .padding(.vertical, 8)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.vfControlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.vfHairline, lineWidth: 0.5)
                    )

                statusPill
            }

            Button("Activate", action: runActivation)
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(isActivating)

            if case .failed(let message, let showManageDevices) = model.phase {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfWarningAmber)
                    .fixedSize(horizontal: false, vertical: true)

                if showManageDevices {
                    ManageDevicesLink()
                }
            }
        }
        .padding(.top, VFSpacing.xs)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.phase {
        case .idle:       EmptyView()
        case .activating: SettingsStatusPill(kind: .checking)
        case .activated:  SettingsStatusPill(kind: .verified)
        case .failed:     SettingsStatusPill(kind: .invalid)
        }
    }

    private var isActivating: Bool {
        if case .activating = model.phase { return true }
        return false
    }

    private func runActivation() {
        model.activate(using: entitlements) { onActivated(model.origin) }
    }
}

// MARK: - Option card chrome

/// The shared card chrome (background fill + hairline border + padding) every
/// paywall option uses, so the cards read as one set. `fillsHeight` makes the
/// card stretch to its container (the fixed plan-cards row → equal heights);
/// `highlighted` is the website pricing section's recommended-plan treatment
/// (accent border + slightly lifted fill) for the Managed card.
private struct OptionCardChrome<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var padding: CGFloat = VFSpacing.md
    var fillsHeight: Bool = false
    var highlighted: Bool = false
    /// Titled-window cards use the shared raised gray so every option remains
    /// clearly separated from the pure-black window root.
    var backgroundColor: Color = .vfCardBackground
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: VFSpacing.sm) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .padding(padding)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                    .fill(backgroundColor)
                // The recommended Managed card keeps a quiet lift in addition
                // to its green border without reverting to a near-black fill.
                RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.04 : 0))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .strokeBorder(
                    highlighted ? Color.vfDevAccent.opacity(0.55) : Color.vfHairline,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Most-popular badge

/// The Managed card's "Most popular" chip — the same hierarchy cue the website
/// pricing section puts on its highlighted card. Rendered in Dev-Mode green
/// (`vfDevAccent`) to match the green "Subscribe" CTA, so the highlight reads as
/// one cue.
private struct MostPopularBadge: View {
    var body: some View {
        Text("Most popular")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.vfDevAccent)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(Color.vfDevAccent.opacity(0.16)))
            .fixedSize()
    }
}

// MARK: - Manage devices link

/// A small inline link to the LemonSqueezy customer portal, shown when a key
/// is at its activation limit so the user can free a slot. No-op (with a log)
/// until the portal URL placeholder is filled.
private struct ManageDevicesLink: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            Text("Manage devices \u{2197}")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.vfTextPrimary : Color.vfBrandAccent)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func open() {
        guard let url = BillingLinks.customerPortalURL else {
            Log.billing.notice("paywall: customer portal URL not configured yet (placeholder)")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Purchase-success confirmation

/// The shared "you're all set" screen shown after an activation (deep-link OR
/// manual paste) or a Managed top-up. Mirrors the onboarding window chrome
/// (`OnboardingStepLayout` + logo-tile-sized badge) so it reads as one app. The
/// detail copy + analytics plan live on `PurchaseSuccessInfo`; this view only
/// renders them and owns the dismiss / route-to-Settings actions.
private struct PurchaseSuccessView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(EntitlementStore.self) private var entitlements
    let info: PurchaseSuccessInfo

    /// Medium-style date for the Managed reset line (e.g. "Jul 1, 2026").
    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        OnboardingStepLayout {
            SuccessBadge()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("You\u{2019}re all set")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text(info.detailLine(formatDate: Self.resetDateFormatter.string(from:)))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            OnboardingPrimaryButton("Start using Zerro") { finish() }

            // BYOK still needs the user's own provider key before generating —
            // give them a direct route to the Settings API-key section.
            if case .byok = info {
                OnboardingSecondaryButton("Open Settings") { openSettings() }
            }
        }
        .frame(minHeight: 600)
    }

    /// Clear the one-shot confirmation and close the window.
    private func finish() {
        entitlements.purchaseSuccess = nil
        dismissWindow(id: PaywallScene.windowID)
    }

    /// Route to the Settings API-key (Account & Billing) section, then close the
    /// paywall. Clears the confirmation first so the paywall doesn't flash the
    /// success screen if it's reopened later.
    private func openSettings() {
        entitlements.purchaseSuccess = nil
        AppDelegate.openSettings(to: .accountBilling)
        dismissWindow(id: PaywallScene.windowID)
    }
}

/// The success checkmark badge — same footprint as `OnboardingLogoTile` but in
/// success green with a bold checkmark glyph.
private struct SuccessBadge: View {
    var size: CGFloat = 80

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.vfSuccessGreen)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

// MARK: - Previews

#Preview("Paywall") {
    // In-memory dependencies so the preview never touches the real Keychain
    // or network. Both factories are non-DEBUG (so this compiles in every
    // config, like all `#Preview` bodies).
    PaywallView()
        .environment(EntitlementStore(licenseService: .inMemory()))
}

// The four dynamic-copy contexts (Step 1). `EntitlementStore.preview` pins the
// state via the DEBUG dev override, so these are `#if DEBUG`-guarded.
#if DEBUG
@MainActor
private func paywallPreviewStore(
    _ state: EntitlementState,
    trigger: EntitlementStore.PaywallTrigger
) -> EntitlementStore {
    let store = EntitlementStore.preview(state)
    store.paywallTrigger = trigger
    return store
}

#Preview("Paywall \u{00B7} Blocked (expired)") {
    PaywallView()
        .environment(paywallPreviewStore(.expired, trigger: .blocked))
}

#Preview("Paywall \u{00B7} Voluntary upgrade (trial)") {
    PaywallView()
        .environment(paywallPreviewStore(.trial(creditsRemaining: 8), trigger: .voluntaryUpgrade))
}

#Preview("Paywall \u{00B7} Add credits (managed)") {
    PaywallView()
        .environment(paywallPreviewStore(
            .managed(creditsRemaining: 4, resetDate: .now.addingTimeInterval(86_400 * 12)),
            trigger: .topup
        ))
}

#Preview("Paywall \u{00B7} Manage (byok)") {
    PaywallView()
        .environment(paywallPreviewStore(.byok, trigger: .manage))
}

// The three purchase-success confirmation variants (Step 5). Each pins the
// matching entitlement state, then sets the one-shot `purchaseSuccess` so the
// view renders the success screen instead of the buy/manage matrix.
private let previewResetDate = Date().addingTimeInterval(60 * 60 * 24 * 30)

#Preview("Paywall \u{00B7} Success (managed)") {
    let store = EntitlementStore.preview(.managed(creditsRemaining: 300, resetDate: previewResetDate))
    store.purchaseSuccess = .managed(credits: 300, resetDate: previewResetDate)
    return PaywallView().environment(store)
}

#Preview("Paywall \u{00B7} Success (byok)") {
    let store = EntitlementStore.preview(.byok)
    store.purchaseSuccess = .byok
    return PaywallView().environment(store)
}

#Preview("Paywall \u{00B7} Success (top-up)") {
    let store = EntitlementStore.preview(.managed(creditsRemaining: 220, resetDate: previewResetDate))
    store.purchaseSuccess = .topup(added: 100, total: 220)
    return PaywallView().environment(store)
}
#endif
