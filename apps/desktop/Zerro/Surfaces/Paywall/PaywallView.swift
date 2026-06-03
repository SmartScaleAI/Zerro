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
//  Three buy paths (billing-plan §8):
//    • BYOK — pay once, fund generation with your own OpenAI key. "Get a
//      license" opens the LemonSqueezy hosted checkout (NSWorkspace). Fully
//      LOCAL: recordings never leave the Mac.
//    • Starter / Pro — Zerro-hosted credit subscriptions (Phase E). A
//      monthly/yearly toggle picks the LemonSqueezy subscription checkout for
//      that tier+period. Managed sends the recording to Zerro's server for
//      processing — surfaced honestly in the privacy note below.
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

struct PaywallView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            mainPanel

            #if DEBUG
            // Mirrors OnboardingDevPanel's placement: a DEBUG-only panel
            // pinned below the main card so every entitlement state — and
            // thus every gate branch — can be forced without a real
            // billing backend. See PaywallDevPanel.
            PaywallDevPanel()
                .padding(.horizontal, VFSpacing.xxl)
                .padding(.bottom, VFSpacing.lg)
            #endif
        }
        .frame(width: 580)
        .background(Color.vfCardBackground)
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("You\u{2019}ve used your free generations")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Keep turning a quick screen recording and a sentence of narration into a ready-to-paste prompt. Pick the option that fits how you work.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            optionStack
        }
        .frame(minHeight: 520)
    }

    // MARK: - Options

    private var optionStack: some View {
        VStack(spacing: VFSpacing.md) {
            // BYOK — one-time license, the user funds generation with their
            // own OpenAI key. Fully local.
            BuyOnceCard()

            // Managed Starter — Zerro-hosted credits, smaller monthly allotment.
            // Monthly vs yearly is chosen on the LemonSqueezy checkout page.
            SubscriptionOptionCard(
                tier: .starter,
                title: "Starter",
                subtitle: "We handle the AI. A monthly pool of credits, no API key to manage."
            )

            // Managed Pro — Zerro-hosted credits, larger monthly allotment.
            SubscriptionOptionCard(
                tier: .pro,
                title: "Pro",
                subtitle: "Everything in Starter with a larger monthly credit pool for heavy use."
            )

            // Honest privacy note (§14.5): Managed transits the server; BYOK
            // stays local. Don't let the local-first claim cover Managed.
            ManagedPrivacyNote()

            // One shared activation path for an already-purchased key (BYOK or
            // subscription). On success the paywall dismisses.
            ActivateLicenseCard(
                onActivated: { dismissWindow(id: PaywallScene.windowID) }
            )
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
    static let byok = "$39 one-time"
    static let starterMonthly = "$12/mo"
    static let starterYearly = "$120/yr"
    static let proMonthly = "$29/mo"
    static let proYearly = "$290/yr"

    /// The price label shown on a subscription card (the monthly figure).
    static func subscription(tier: ManagedTier) -> String {
        switch tier {
        case .starter: return starterMonthly
        case .pro:     return proMonthly
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

/// The BYOK purchase card: pay once, fund with your own OpenAI key. Activation
/// of the resulting key happens through the shared `ActivateLicenseCard` below.
private struct BuyOnceCard: View {
    var body: some View {
        OptionCardChrome {
            HStack(alignment: .firstTextBaseline) {
                Text("Bring your own key")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.sm)
                Text(Price.byok)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text("Pay once. Use your own OpenAI API key — no monthly fee. Recordings stay fully on your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingPrimaryButton("Get a license", action: openCheckout)
                .padding(.top, VFSpacing.xs)
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.byokCheckoutURL else {
            Log.billing.notice("paywall: BYOK checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening BYOK checkout in browser")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Subscription (Managed) card

/// One managed subscription option (Starter / Pro). Opens the LemonSqueezy
/// subscription checkout for the tier in the browser (same pattern as BYOK) —
/// monthly vs yearly is chosen on the checkout page. The user activates the
/// issued key afterward via the shared `ActivateLicenseCard`.
private struct SubscriptionOptionCard: View {
    let tier: ManagedTier
    let title: String
    let subtitle: String

    var body: some View {
        OptionCardChrome {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
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

            OnboardingPrimaryButton("Subscribe to \(title)", action: openCheckout)
                .padding(.top, VFSpacing.xs)
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.subscriptionCheckoutURL(tier: tier) else {
            Log.billing.notice("paywall: \(tier.rawValue, privacy: .public) checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening \(tier.rawValue, privacy: .public) subscription checkout")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Privacy note

/// Honest one-liner on where recordings go (§14.5). Understated secondary text.
private struct ManagedPrivacyNote: View {
    var body: some View {
        Text("Starter & Pro send your recording to Zerro\u{2019}s server to generate the prompt. Bring-your-own-key stays fully on your Mac.")
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextTertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
/// paywall option uses, so the cards read as one set.
private struct OptionCardChrome<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: VFSpacing.sm) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .strokeBorder(Color.vfHairline, lineWidth: 1)
        )
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
