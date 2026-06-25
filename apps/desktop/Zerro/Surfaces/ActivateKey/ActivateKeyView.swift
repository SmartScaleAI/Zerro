//
//  ActivateKeyView.swift
//  Zerro
//
//  The dedicated post-purchase "Activate your key" window's content. Opened ONLY
//  by the checkout-return deep link (`AppDelegate.openActivateKey`) when the
//  `zerro://checkout-complete` link carries an issued key; it never auto-presents
//  at launch (the Window scene uses `.defaultLaunchBehavior(.suppressed)`).
//
//  A clean single-purpose surface: heading + one instruction line + the key
//  field + Activate, in place of the full paywall's wide two-column sell. It
//  REUSES the paywall's activation engine wholesale — `PaywallActivationModel`
//  drives the field through `EntitlementStore.activate`, so the activation logic
//  and the E-01 protections are untouched:
//    • The deep link only PREFILLS the field (read + cleared from
//      `entitlements.prefillLicenseKey` on appear, just like `ActivateLicenseCard`)
//      — the user must tap Activate; nothing activates on its own.
//    • The "replace your current license?" confirm gate stays in `LicenseService`;
//      declining it (`LicenseError.replaceCancelled`) is a quiet no-op here, same
//      as the paywall.
//
//  Visually consistent with the paywall + onboarding: the same
//  `OnboardingStepLayout`, logo tile, primary button, monospaced key field, and
//  `SettingsStatusPill` chrome, so the surfaces read as one app.
//

import SwiftUI

struct ActivateKeyView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(EntitlementStore.self) private var entitlements

    /// Window width. A compact single-purpose surface (the full paywall is the
    /// wide two-column sell; this is just the key field) — sized like the other
    /// content-sized single-column windows (the trial email-capture window).
    /// `.windowResizability(.contentSize)` makes this frame the window size.
    private static let windowWidth: CGFloat = 460

    /// Reuses the paywall's activation engine — same field model, same
    /// `EntitlementStore.activate` path, same E-01 handling — so activation logic
    /// is never reimplemented here.
    @State private var model = PaywallActivationModel()
    @FocusState private var fieldFocused: Bool

    /// Medium-style date for the Managed reset line (e.g. "Jul 1, 2026").
    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        // Once an activation lands, the window shows the "you're all set"
        // confirmation (driven by the one-shot `purchaseSuccess`) instead of the
        // key field — mirroring the paywall's success swap.
        Group {
            if let success = entitlements.purchaseSuccess {
                successPanel(success)
            } else {
                activatePanel
            }
        }
        .frame(width: Self.windowWidth)
        .background(Color.vfCardBackground)
        // Checkout-return deep link: a buyer lands here with the issued key
        // already in the field + focused. `onAppear` covers a freshly-opened
        // window; the `onChange` handlers cover the flags flipping while the
        // window is already on screen (the deep link re-routes to the existing
        // window rather than re-firing onAppear).
        .onAppear(perform: adoptPrefillAndFocus)
        .onChange(of: entitlements.prefillLicenseKey) { _, key in
            if key != nil { adoptPrefillAndFocus() }
        }
        .onChange(of: entitlements.focusActivationFieldOnOpen) { _, requested in
            if requested { adoptPrefillAndFocus() }
        }
    }

    // MARK: - Activate panel

    private var activatePanel: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Activate your key")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Paste your license or subscription key below and click Activate.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            activationField
        }
        .frame(minHeight: 440)
    }

    @ViewBuilder
    private var activationField: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                TextField("License or subscription key", text: $model.licenseKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .focused($fieldFocused)
                    // Editing after a terminal phase demotes back to idle so a
                    // stale success/error pill doesn't linger while retyping.
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

            // Disabled only while a request is in flight; the model itself guards
            // the empty-key case with a typed error.
            OnboardingPrimaryButton("Activate", isEnabled: !isActivating, action: runActivation)

            if case .failed(let message, _) = model.phase {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfWarningAmber)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Success panel

    private func successPanel(_ info: PurchaseSuccessInfo) -> some View {
        OnboardingStepLayout {
            ActivateKeySuccessBadge()
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
            OnboardingPrimaryButton("Done") { finishAndClose() }
        }
        .frame(minHeight: 440)
    }

    // MARK: - Actions

    /// Runs activation through the SHARED `PaywallActivationModel` +
    /// `EntitlementStore.activate` — the exact path the paywall uses. The model
    /// owns the phase transitions, the gated `purchase_activated` funnel event,
    /// and the quiet `replaceCancelled` no-op (E-01); on success we surface the
    /// confirmation.
    private func runActivation() {
        model.activate(using: entitlements) { showActivationSuccess() }
    }

    /// Activation succeeded: derive the confirmation from the now-paid state and
    /// route through `purchaseSuccess` so the success panel shows (matching
    /// `PaywallView.showActivationSuccess`). The `method` tracks how the key
    /// arrived — `deeplink` when the checkout-return link prefilled it, otherwise
    /// `manual_paste` — so the funnel attribution stays accurate.
    private func showActivationSuccess() {
        guard let info = PurchaseSuccessInfo.fromActivatedState(entitlements.state) else {
            finishAndClose()
            return
        }
        entitlements.purchaseSuccess = info
        let method = model.origin == .deeplink ? "deeplink" : "manual_paste"
        Analytics.capture("purchase_success_shown", ["method": method, "plan": info.analyticsPlan])
    }

    /// Clear the one-shot confirmation and close the window.
    private func finishAndClose() {
        entitlements.purchaseSuccess = nil
        dismissWindow(id: ActivateKeyScene.windowID)
    }

    /// Reads + CLEARS the one-shot prefill the checkout-return deep link delivered
    /// into the field and focuses it. PREFILL only — the user must tap Activate
    /// (E-01); nothing auto-activates. Marks the origin `.deeplink` so a
    /// successful confirm still records the purchase funnel event, and demotes the
    /// phase to `.idle` so no stale pill shows over the prefilled key. Also
    /// consumes the `focusActivationFieldOnOpen` one-shot (same handling as
    /// `ActivateLicenseCard`) so it never leaks onto the paywall later.
    private func adoptPrefillAndFocus() {
        if let key = entitlements.prefillLicenseKey {
            entitlements.prefillLicenseKey = nil
            model.licenseKey = key
            model.origin = .deeplink
            model.phase = .idle
        }
        if entitlements.focusActivationFieldOnOpen {
            entitlements.focusActivationFieldOnOpen = false
        }
        // This window's whole purpose is the key field — focus it on appear. The
        // async hop lets the TextField mount before we move focus to it.
        Task { @MainActor in fieldFocused = true }
    }
}

// MARK: - Success badge

/// The success checkmark badge — same footprint as `OnboardingLogoTile` but in
/// success green with a bold checkmark glyph. Local twin of the paywall's
/// (private) `SuccessBadge` so this window stays self-contained.
private struct ActivateKeySuccessBadge: View {
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

#Preview("Activate key") {
    // In-memory dependency so the preview never touches the real Keychain or
    // network. Non-DEBUG factory so it compiles in every config.
    ActivateKeyView()
        .environment(EntitlementStore(licenseService: .inMemory()))
}

#if DEBUG
#Preview("Activate key \u{00B7} Success (byok)") {
    let store = EntitlementStore.preview(.byok)
    store.purchaseSuccess = .byok
    return ActivateKeyView().environment(store)
}
#endif
