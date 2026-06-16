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
//  `vfCardBackground`, and spacing tokens — so the two surfaces read as one
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

    /// Resolves the copy. `.expired` is the genuinely-gated state, so it ALWAYS
    /// gets the blocked copy even if a stale trigger survived; otherwise the
    /// explicit trigger wins, and a `nil` trigger falls back to a sensible copy
    /// for the state so the window never shows the wrong context.
    static func resolve(trigger: EntitlementStore.PaywallTrigger?, state: EntitlementState) -> PaywallCopy {
        if case .expired = state { return .blocked }

        switch trigger {
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
            case .trial:            return .upgrade
            case .managed, .byok:   return .manage
            case .expired:          return .blocked  // unreachable (handled above)
            }
        }
    }

    /// Trial exhausted (the original wall). Copy unchanged from v1.
    static let blocked = PaywallCopy(
        headline: "You\u{2019}ve used your free generations",
        subheadline: "Keep turning a quick screen recording and a sentence of narration into a ready-to-paste prompt. Pick the option that fits how you work."
    )
    /// Voluntary upgrade from an active trial — lead with the Managed value,
    /// reassure the trial still works.
    static let upgrade = PaywallCopy(
        headline: "Upgrade your plan",
        subheadline: "Your free trial is still active \u{2014} upgrade whenever you\u{2019}re ready. Managed gives you 300 credits a month across all six models, with no API keys to manage."
    )
    /// Managed user adding credits — point straight at the top-up packs.
    static let topup = PaywallCopy(
        headline: "Add more credits",
        subheadline: "Top up your balance to keep generating this month. Credits attach to your subscription instantly and carry over for 12 months."
    )
    /// Entitled user managing their plan — de-emphasize the sell.
    static let manage = PaywallCopy(
        headline: "Manage your plan",
        subheadline: "Switch options, activate a key, or manage your devices and billing \u{2014} everything for your plan lives here."
    )
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

    private var copy: PaywallCopy {
        let trigger = didCaptureTrigger ? capturedTrigger : entitlements.paywallTrigger
        return PaywallCopy.resolve(trigger: trigger, state: entitlements.state)
    }

    var body: some View {
        mainPanel
            .frame(width: Self.windowWidth)
            .background(Color.vfCardBackground)
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
    ///   • Managed   → top-up packs lead (the only purchasable thing left) +
    ///                 a manage link. No re-sell of a plan they already have.
    ///   • BYOK      → a manage link only (BYOK funds locally; no credits to
    ///                 top up, no plan to upgrade to).
    ///   • Trial/Expired → the plan sell: Managed + BYOK side by side.
    /// The shared activation field is always present.
    private var optionStack: some View {
        VStack(spacing: VFSpacing.md) {
            // Credit packs are Managed-only (decision §6): `.byok` carries no
            // credit balance, and trial/expired buy a plan, not a top-up.
            if case .managed = entitlements.state {
                TopupPacksSection()
            }

            if showsPlanCards {
                // The two plans SIDE BY SIDE (website pricing parity): Managed
                // leads left — the recommended path, accent-highlighted — BYOK
                // right. Shown only to users without a plan yet (trial/expired);
                // an entitled user sees the manage link instead, not a re-sell.
                HStack(alignment: .top, spacing: VFSpacing.md) {
                    // Managed — THE plan (multi-model §1.3): Zerro-hosted
                    // credits, all six models, no API keys to manage. Monthly vs
                    // yearly ($12/mo billed annually) is chosen on the
                    // LemonSqueezy page.
                    SubscriptionOptionCard(
                        tier: .pro,
                        title: "Managed",
                        subtitle: "We handle the AI. 300 credits a month across all six models \u{2014} no API key to manage. $12/mo billed yearly."
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
            // subscription). On success the paywall dismisses.
            ActivateLicenseCard(
                onActivated: { dismissWindow(id: PaywallScene.windowID) }
            )
        }
    }

    /// The plan sell shows only to users who don't have a plan yet.
    private var showsPlanCards: Bool {
        switch entitlements.state {
        case .trial, .expired: return true
        case .byok, .managed:  return false
        }
    }

    /// The manage link shows only to users who already hold a plan.
    private var showsManageLink: Bool {
        switch entitlements.state {
        case .byok, .managed:  return true
        case .trial, .expired: return false
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
    // The retired Starter tier is not sold (it survives server-side as a
    // future cheaper tier only).
    static let byok = "$69 one-time"
    static let managedMonthly = "$15/mo"
    static let managedYearly = "$144/yr"

    /// The price label shown on a subscription card (the monthly figure).
    /// Only `.pro` (the Managed plan) is rendered; `.starter` is unsold.
    static func subscription(tier: ManagedTier) -> String {
        switch tier {
        case .starter: return managedMonthly
        case .pro:     return managedMonthly
        }
    }
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

    /// License/subscription keys aren't as sensitive as API keys, so the field
    /// is shown in plain text with a paste affordance — friendlier than a
    /// masked field.
    var licenseKey: String = ""
    var phase: Phase = .idle

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
    /// `onSuccess` (the paywall dismisses); on a `LicenseError` renders the
    /// typed copy. No product hint — the backend probe in `activate` decides
    /// BYOK vs Managed.
    func activate(using entitlements: EntitlementStore, onSuccess: @escaping () -> Void) {
        let key = trimmedKey
        guard !key.isEmpty else {
            phase = .failed(message: "Enter your license key to continue.", showManageDevices: false)
            return
        }
        phase = .activating
        Task { @MainActor in
            do {
                try await entitlements.activate(licenseKey: key)
                phase = .activated
                onSuccess()
            } catch let error as LicenseError {
                phase = .failed(
                    message: error.userFacingMessage,
                    showManageDevices: error == .atActivationLimit
                )
            } catch {
                phase = .failed(message: "Activation failed — please try again.", showManageDevices: false)
            }
        }
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

            Text("Pay once \u{2014} includes 1 year of updates. Use your own API keys (OpenAI, Gemini, Anthropic) and pay providers directly. Recordings stay fully on your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: VFSpacing.xs)

            OnboardingPrimaryButton("Get a license", action: openCheckout)
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
        NSWorkspace.shared.open(BillingLinks.checkoutURL(url, product: .byok))
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
    let tier: ManagedTier
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
                Text(Price.subscription(tier: tier))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: VFSpacing.xs)

            OnboardingPrimaryButton("Subscribe to \(title)", action: openCheckout)
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.subscriptionCheckoutURL(tier: tier) else {
            Log.billing.notice("paywall: \(tier.rawValue, privacy: .public) checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening \(tier.rawValue, privacy: .public) subscription checkout")
        // Tier 3 analytics: only the Managed (Pro) subscription is sold here.
        Analytics.capture("checkout_opened", [
            "product": BillingLinks.CheckoutProduct.subscriptionPro.rawValue,
            "placement": "paywall"
        ])
        NSWorkspace.shared.open(BillingLinks.checkoutURL(url, product: .subscriptionPro))
    }
}

// MARK: - Privacy note

/// Honest one-liner on where recordings go (§14.5). Understated secondary text.
private struct ManagedPrivacyNote: View {
    var body: some View {
        Text("Managed sends your recording to Zerro\u{2019}s server to generate the prompt. Bring-your-own-key stays fully on your Mac.")
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextTertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Top-up packs (Managed only)

/// The two one-time top-up packs (Boost · 200 · $10, Power · 500 · $22),
/// surfaced in the paywall for a Managed user choosing "Add Credits". These
/// used to live only in the menu-bar panel (`topupPackRow`); the menu-bar
/// consolidation folded that prompt into the single "Upgrade" entry, so the
/// paywall now owns the buy surface. Managed-only by construction — the caller
/// gates on `.managed`, and BYOK/trial never reach it. A pack whose checkout
/// link isn't configured yet resolves to `nil` and its chip is simply absent
/// (the BillingLinks placeholder pattern).
private struct TopupPacksSection: View {
    var body: some View {
        OptionCardChrome(alignment: .leading) {
            Text("Top-up packs")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
            Text("Credits attach to your subscription instantly and carry over for 12 months.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: VFSpacing.sm) {
                TopupChip(
                    label: "Boost \u{00B7} 200 credits \u{00B7} $10",
                    url: BillingLinks.boostTopupCheckoutURL,
                    product: .topupBoost
                )
                TopupChip(
                    label: "Power \u{00B7} 500 credits \u{00B7} $22",
                    url: BillingLinks.powerTopupCheckoutURL,
                    product: .topupPower
                )
            }
            .padding(.top, VFSpacing.xs)
        }
    }
}

/// A single top-up checkout chip. Fires `checkout_opened` (with the `paywall`
/// placement tag, Tier 3 §0) and opens the custom-data-decorated URL. Absent
/// when its checkout link is still a placeholder. Lifted out of the menu-bar
/// panel so the paywall and any remaining caller share one chip.
private struct TopupChip: View {
    let label: String
    let url: URL?
    let product: BillingLinks.CheckoutProduct

    var body: some View {
        if let url {
            Button {
                Analytics.capture("checkout_opened", [
                    "product": product.rawValue,
                    "placement": "paywall"
                ])
                NSWorkspace.shared.open(BillingLinks.checkoutURL(url, product: product))
            } label: {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .padding(.horizontal, VFSpacing.md)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
    /// Called when activation succeeds — the paywall dismisses.
    let onActivated: () -> Void

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
        .onChange(of: entitlements.focusActivationFieldOnOpen) { _, requested in
            if requested { focusActivationIfRequested() }
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
                            .fill(Color.vfPillBackground)
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
        model.activate(using: entitlements, onSuccess: onActivated)
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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: VFSpacing.sm) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .fill(Color.white.opacity(highlighted ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .strokeBorder(
                    highlighted ? Color.vfBrandAccent.opacity(0.55) : Color.vfHairline,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Most-popular badge

/// The Managed card's "Most popular" chip — the same hierarchy cue the
/// website pricing section puts on its highlighted card.
private struct MostPopularBadge: View {
    var body: some View {
        Text("Most popular")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.vfBrandAccent)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(Color.vfBrandAccent.opacity(0.16)))
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
            .managed(tier: .pro, creditsRemaining: 4, resetDate: .now.addingTimeInterval(86_400 * 12)),
            trigger: .topup
        ))
}

#Preview("Paywall \u{00B7} Manage (byok)") {
    PaywallView()
        .environment(paywallPreviewStore(.byok, trigger: .manage))
}
#endif
