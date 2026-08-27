//
//  BillingSection.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  The Zerro license section of the API Keys & License pane
//  (AccountBillingPane), plus the shared field model behind it:
//    1. License key    — the Lemon Squeezy key from the purchase email
//                        (activate / re-activate / deactivate this device).
//    2. Get / manage   — the license checkout, or the customer portal for
//                        device management.
//    3. (DEBUG) Force re-validate.
//

import AppKit
import os
import SwiftUI

// MARK: - Shared model

/// One field model for the license rows, mirroring `APIKeyFieldModel`. Loads
/// any stored key from the Keychain on init so the field is pre-filled, and
/// renders an explicit phase against the shared status pill.
@MainActor
@Observable
final class BillingLicenseModel {
    /// `licensed` is the resting "this key is active" state (entitlement is
    /// `.byok`); `working` covers both activation and deactivation in flight;
    /// `failed` carries user-facing copy.
    enum Phase: Equatable {
        case unverified
        case licensed
        case working
        case failed(String)
    }

    var licenseKey: String
    var phase: Phase

    @ObservationIgnored private let keychain: KeychainSlot

    /// The slot defaults to the production Keychain static; tests inject an
    /// in-memory double.
    init(keychain: KeychainSlot = KeychainStore.byokLicenseKey) {
        self.keychain = keychain
        let stored = keychain.read() ?? ""
        // A key already in the Keychain came from a prior successful activation —
        // render `.licensed` so the pill doesn't ask the user to re-activate on
        // every Settings open.
        if !stored.isEmpty {
            licenseKey = stored
            phase = .licensed
        } else {
            licenseKey = ""
            phase = .unverified
        }
    }

    var trimmedKey: String {
        licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isWorking: Bool { phase == .working }

    /// Editing demotes a resting state back to `.unverified` (unless a request
    /// is in flight) so the pill stops showing a stale disposition.
    func handleEdit() {
        if phase == .working { return }
        if phase != .unverified { phase = .unverified }
    }

    /// Reconciles the field disposition with the authoritative license
    /// status (`EntitlementStore.hasActiveLicense`, called on `.onChange`).
    /// Doesn't clobber an in-flight request.
    func syncToEntitlement(licensed: Bool) {
        guard phase != .working else { return }
        if licensed {
            phase = .licensed
            // Re-fill from the Keychain in case activation happened elsewhere.
            if trimmedKey.isEmpty, let stored = keychain.read() { licenseKey = stored }
        } else if phase == .licensed {
            // This row's product is no longer the active entitlement (revoked /
            // deactivated, or a preview of the other mode) — clear it.
            phase = .unverified
            licenseKey = ""
        }
    }

    /// Activate (or re-activate) the typed key through the shared store.
    func activate(using entitlements: EntitlementStore) {
        Task { @MainActor in await performActivation(using: entitlements) }
    }

    /// Awaitable activation core, split out of `activate` so the phase
    /// transitions — notably the E-01 `.replaceCancelled` → `.unverified`
    /// quiet-no-op — are unit-testable without the fire-and-forget Task.
    func performActivation(using entitlements: EntitlementStore) async {
        let key = trimmedKey
        guard !key.isEmpty else {
            phase = .failed("Enter your license key.")
            return
        }
        phase = .working
        do {
            try await entitlements.activate(licenseKey: key)
            phase = .licensed
        } catch LicenseError.replaceCancelled {
            // The user declined the "replace your current license?" prompt
            // (E-01). Not a failure — restore the row to the unchanged on-file
            // license with NO error pill: drop the rejected key and re-sync to
            // the active entitlement, so this row reflects the license that is
            // still active rather than the key the user backed out of.
            licenseKey = ""
            phase = .unverified
            syncToEntitlement(licensed: entitlements.hasActiveLicense)
        } catch let error as LicenseError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed("Activation failed. Please try again.")
        }
    }

    /// Deactivate this device (frees the LemonSqueezy slot + clears the local
    /// license), dropping the entitlement back to the trial clock.
    func deactivate(using entitlements: EntitlementStore) {
        phase = .working
        Task { @MainActor in
            do {
                try await entitlements.deactivateThisDevice()
                licenseKey = ""
                phase = .unverified
            } catch let error as LicenseError {
                phase = .failed(error.userFacingMessage)
            } catch {
                phase = .failed("Couldn\u{2019}t deactivate. Please try again.")
            }
        }
    }
}

// MARK: - License key row

private struct LicenseKeyRow: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Bindable var model: BillingLicenseModel
    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsRow(
            label: "License Key",
            description: "Your Zerro license key. Stored in macOS Keychain; activates online once, then works offline.",
            verticalPadding: RowMetrics.verticalPaddingTall
        ) {
            VStack(alignment: .trailing, spacing: VFSpacing.sm) {
                HStack(spacing: VFSpacing.sm) {
                    fieldCapsule
                    statusPill
                }

                HStack(spacing: VFSpacing.sm) {
                    if isLicensed {
                        Button("Deactivate this device") { model.deactivate(using: entitlements) }
                            .buttonStyle(SettingsDestructiveButtonStyle())
                            .disabled(model.isWorking)
                    }
                    Button(activateLabel) { model.activate(using: entitlements) }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(model.isWorking)
                }

                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfWarningAmber)
                        .frame(maxWidth: 320, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Licensed affordances (Verified pill, Re-activate / Deactivate) render
    /// only while an actual license is active.
    private var isLicensed: Bool {
        entitlements.hasActiveLicense
    }

    private var activateLabel: String {
        isLicensed ? "Re-activate" : "Activate"
    }

    private var fieldCapsule: some View {
        // License keys aren't as sensitive as API keys — plain text with a
        // paste affordance is friendlier (per the Phase C spec).
        TextField("Paste your license key", text: $model.licenseKey)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.vfTextPrimary)
            .focused($isFocused)
            .onChange(of: model.licenseKey) { _, _ in model.handleEdit() }
            .onSubmit { model.activate(using: entitlements) }
            .frame(width: 220)
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
            .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.phase {
        case .licensed:   SettingsStatusPill(kind: .verified)
        case .working:    SettingsStatusPill(kind: .checking)
        case .failed:     SettingsStatusPill(kind: .invalid)
        case .unverified: SettingsStatusPill(kind: .unverified)
        }
    }
}

/// Shared open-or-log for the LemonSqueezy links (placeholders resolve nil
/// until the products exist — the button no-ops with a log line, never a
/// dead tab).
private func openBillingLink(_ url: URL?) {
    guard let url else {
        Log.billing.notice("settings: billing link not configured yet (placeholder)")
        return
    }
    NSWorkspace.shared.open(url)
}

/// Checkout variant of `openBillingLink` (Tier 4 coverage fix): fires
/// `checkout_opened` and opens the custom-data-decorated URL
/// (ph_distinct_id + product for server-side purchase stitching, Tier 3 §0).
/// Portal/manage opens stay on `openBillingLink` — they are not checkouts.
/// Same nil-placeholder early-return: an unconfigured product fires nothing.
private func openCheckout(_ url: URL?) {
    guard let url else {
        Log.billing.notice("settings: checkout link not configured yet (placeholder)")
        return
    }
    // Tier 3 §0: tag the placement so the monetization funnel can tell the
    // Settings checkouts apart from the paywall's (`placement: "paywall"`).
    Analytics.capture("checkout_opened", ["product": BillingLinks.checkoutProductValue, "placement": "settings"])
    NSWorkspace.shared.open(BillingLinks.checkoutURL(url))
}

// MARK: - License section

/// The license rows (AccountBillingPane composes this below the API-key
/// section). The $39 one-time Zerro license: activation key field +
/// get/manage links. Community builds enforce no licensing, so they show a
/// single explanatory row in place of every activation/manage control.
struct BYOKLicenseSection: View {
    @Environment(EntitlementStore.self) private var entitlements
    @State private var model = BillingLicenseModel()

    var body: some View {
        SettingsSection("License") {
            if entitlements.enforcesLicensing {
                LicenseKeyRow(model: model)
                SettingsRowDivider()
                ByokManageRow()
                #if DEBUG
                SettingsRowDivider()
                DevRevalidateRow()
                #endif
            } else {
                CommunityLicenseRow()
            }
        }
        // Keep the field model's "licensed" disposition in lockstep with the
        // entitlement if it changes elsewhere (a launch revalidation that
        // revoked the license, or the dev panel forcing a state).
        .onChange(of: entitlements.state) { _, _ in model.syncToEntitlement(licensed: entitlements.hasActiveLicense) }
    }
}

/// The Settings-only community licensing notice, shown under API Keys &
/// License in place of the key and manage rows. Community builds never open
/// the Paywall or Activate Key windows, so this copy has no other consumer.
enum CommunityLicenseCopy {
    static let title = "Community build"
    static let message = "Community build \u{2014} no Zerro license is required. Generation runs on your own provider keys."
}

private struct CommunityLicenseRow: View {
    var body: some View {
        SettingsRow(
            label: CommunityLicenseCopy.title,
            description: CommunityLicenseCopy.message,
            verticalPadding: RowMetrics.verticalPaddingTall
        ) {
            EmptyView()
        }
    }
}

private struct ByokManageRow: View {
    @Environment(EntitlementStore.self) private var entitlements

    private var isLicensed: Bool { entitlements.hasActiveLicense }

    var body: some View {
        SettingsRow(
            label: isLicensed ? "Manage License" : "Get a License",
            description: isLicensed
                ? "Manage your devices and order in the Lemon Squeezy portal."
                : "$39 one-time. Includes all Zerro 1.x.x updates. Use on up to 2 Macs. You pay your providers directly for usage."
        ) {
            Button(isLicensed ? "Manage devices" : "Get a license") {
                // Manage devices = portal (not a checkout); Get a license =
                // the license checkout.
                if isLicensed {
                    openBillingLink(BillingLinks.customerPortalURL)
                } else {
                    openCheckout(BillingLinks.licenseCheckoutURL)
                }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }
}

// MARK: - DEBUG: force re-validate

#if DEBUG
private struct DevRevalidateRow: View {
    @Environment(EntitlementStore.self) private var entitlements
    @State private var isRunning = false

    var body: some View {
        SettingsRow(
            label: "Force Re-validate (DEBUG)",
            description: "Re-checks the license now, ignoring the throttle. Drops it if revoked; fails open on a network error."
        ) {
            Button(isRunning ? "Checking\u{2026}" : "Re-validate now") {
                isRunning = true
                Task { @MainActor in
                    await entitlements.devRevalidateLicenseNow()
                    isRunning = false
                }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .disabled(isRunning)
        }
    }
}
#endif

// MARK: - Preview
//
// `EntitlementStore.preview` pins the state via the dev override (DEBUG-only),
// so these previews are `#if DEBUG`-guarded — `#Preview` bodies otherwise
// compile in Release too and would fail on the missing symbol.

#if DEBUG
#Preview("License") {
    BYOKLicenseSection()
        .environment(EntitlementStore.preview(.byok))
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
#endif
