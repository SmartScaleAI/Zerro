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
//  Phase C wiring (BYOK):
//    • "Get a license"        → opens the LemonSqueezy hosted checkout in the
//                               default browser (NSWorkspace). URL is a
//                               `// TODO:` placeholder until the LS account is
//                               approved (see `BillingLinks`).
//    • "Enter existing license" → reveals a license-key field + Activate
//                               button → `EntitlementStore.activate(...)`,
//                               with activating / activated / error states
//                               mirroring APIAuthSection's verification pill.
//                               On success the paywall dismisses (the gate now
//                               passes; `.byok` already grants `canGenerate`).
//    • At-activation-limit    → clear message + a "Manage devices" link to the
//                               LS customer portal. Full in-app deactivate-
//                               another-device is DEFERRED (the service method
//                               is wired for Settings' "Deactivate this
//                               device" today).
//  Managed Starter / Pro stay INERT — `// DEFERRED Phase E`. Prices are `$X`
//  placeholders (see `Price`).
//

import AppKit
import os
import SwiftUI

struct PaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements
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
                Text("Your free trial has ended")
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
            // own OpenAI key. Interactive in Phase C (buy or activate).
            BYOKOptionCard(
                onActivated: { dismissWindow(id: PaywallScene.windowID) }
            )

            // Managed Starter — Zerro-hosted credits, smaller monthly allotment.
            PaywallOptionCard(
                title: "Starter",
                subtitle: "We handle the AI. A monthly pool of credits, no API key to manage.",
                price: Price.starter,
                primaryLabel: "Subscribe to Starter",
                primaryAction: {
                    // DEFERRED Phase E: LemonSqueezy subscription checkout
                    Log.ui.notice("paywall: 'Subscribe to Starter' tapped (Phase E no-op)")
                }
            )

            // Managed Pro — Zerro-hosted credits, larger monthly allotment.
            PaywallOptionCard(
                title: "Pro",
                subtitle: "Everything in Starter with a larger monthly credit pool for heavy use.",
                price: Price.pro,
                primaryLabel: "Subscribe to Pro",
                primaryAction: {
                    // DEFERRED Phase E: LemonSqueezy subscription checkout
                    Log.ui.notice("paywall: 'Subscribe to Pro' tapped (Phase E no-op)")
                }
            )
        }
    }
}

// MARK: - Price placeholders

/// Placeholder price strings. Real numbers aren't locked yet, so these stay
/// as `$X` / `$X/mo` literals — grep `TODO: set prices` to find the one place
/// to update once pricing is decided.
private enum Price {
    // TODO: set prices
    static let byok = "$X"
    // TODO: set prices
    static let starter = "$X/mo"
    // TODO: set prices
    static let pro = "$X/mo"
}

// MARK: - BYOK activation model

/// Drives the paywall's "Enter existing license" flow. Mirrors
/// `APIKeyFieldModel`'s shape: a small `@Observable` field model with an
/// explicit phase the pill renders against.
@MainActor
@Observable
final class BYOKActivationModel {
    /// The activation lifecycle the UI renders. `failed` carries the
    /// user-facing copy plus whether to offer the "Manage devices" portal
    /// link (only meaningful for the at-activation-limit case).
    enum Phase: Equatable {
        case idle
        case activating
        case activated
        case failed(message: String, showManageDevices: Bool)
    }

    /// License keys aren't as sensitive as API keys, so the field is shown in
    /// plain text with a paste affordance — friendlier than a masked field.
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
    /// typed copy.
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

// MARK: - BYOK option card

/// The BYOK purchase card: a buy affordance and an inline "activate an
/// existing license" flow. Self-contained so the activation field state lives
/// with the card rather than leaking into `PaywallView`.
private struct BYOKOptionCard: View {
    @Environment(EntitlementStore.self) private var entitlements
    /// Called when activation succeeds — the paywall dismisses.
    let onActivated: () -> Void

    @State private var model = BYOKActivationModel()
    @State private var isEnteringLicense = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bring your own key")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.sm)
                Text(Price.byokDisplay)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text("Pay once. Use your own OpenAI API key — no monthly fee.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingPrimaryButton("Get a license", action: openCheckout)
                .padding(.top, VFSpacing.xs)

            if isEnteringLicense {
                activationField
            } else {
                OnboardingSecondaryButton("Enter existing license") {
                    isEnteringLicense = true
                    fieldFocused = true
                }
            }
        }
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

    // MARK: Activation field

    @ViewBuilder
    private var activationField: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                TextField("License key", text: $model.licenseKey)
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

    // MARK: Actions

    private func runActivation() {
        model.activate(using: entitlements, onSuccess: onActivated)
    }

    private func openCheckout() {
        guard let url = BillingLinks.byokCheckoutURL else {
            // Placeholder not yet filled (LS account in review). Log loudly
            // rather than opening a dead link.
            Log.billing.notice("paywall: BYOK checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening BYOK checkout in browser")
        NSWorkspace.shared.open(url)
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

// MARK: - Price display helper

private extension Price {
    /// The BYOK price as shown on the card. Kept beside the other price
    /// placeholders so pricing is updated in one file.
    static var byokDisplay: String { byok }
}

// MARK: - Option card

/// One inert purchase option (Starter / Pro): title, one-line value, a price
/// chip, and a primary action. Built from the shared onboarding button styles
/// so it matches the rest of the app's chrome.
private struct PaywallOptionCard: View {
    let title: String
    let subtitle: String
    let price: String
    let primaryLabel: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.sm)
                Text(price)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingPrimaryButton(primaryLabel, action: primaryAction)
                .padding(.top, VFSpacing.xs)
        }
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

// MARK: - Previews

#Preview("Paywall") {
    // In-memory dependencies so the preview never touches the real Keychain
    // or network. Both factories are non-DEBUG (so this compiles in every
    // config, like all `#Preview` bodies).
    PaywallView()
        .environment(EntitlementStore(trialManager: .inMemory(), licenseService: .inMemory()))
}
