//
//  BillingSection.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase C — Billing & License section of the single-pane Settings layout.
//  Mirrors `APIAuthSection`'s structure (a shared `@Observable` field model,
//  masked/plain field + verification pill, secondary/destructive buttons).
//  Rows:
//    1. Current plan   — reads `EntitlementStore.state` and renders the live
//                        standing (Trial — N days left / Licensed / Expired /
//                        Managed), with a status pill.
//    2. License key    — plain field pre-filled from the Keychain if a license
//                        is on file; Activate / Re-activate → the shared
//                        `EntitlementStore.activate(...)`. When licensed, a
//                        "Deactivate this device" button frees the LemonSqueezy
//                        slot (→ `EntitlementStore.deactivateThisDevice()`).
//    3. Manage / buy   — links out to the LemonSqueezy hosted checkout (when
//                        unlicensed) and the customer portal (`BillingLinks`,
//                        `// TODO:` placeholders until the account is approved).
//    4. (DEBUG) Force re-validate — bypasses the throttle to exercise the
//                        refund/revoke + fail-open paths.
//
//  Copy is non-punitive; prices remain `$X` placeholders.
//

import AppKit
import os
import SwiftUI

struct BillingSection: View {
    @Environment(EntitlementStore.self) private var entitlements
    @State private var model = BillingLicenseModel()

    var body: some View {
        SettingsSection("Billing & License") {
            CurrentPlanRow()
            // Phase F: persistent "verify your email to start your free trial"
            // affordance for trial users who haven't verified yet (existing
            // users from before the required onboarding step, or anyone who took
            // the infra-failure fallback). Opens the standalone verification
            // window. Hidden once verified (or on any non-trial state).
            if entitlements.needsTrialEmailVerification {
                SettingsRowDivider()
                TrialVerifyRow()
            }
            // Phase E: a quiet, non-blocking past-due nudge (§9.1) — only while
            // the Managed subscription is in LemonSqueezy's dunning window.
            // Generation still works on remaining credits; this is visibility.
            if entitlements.managedSnapshot?.isPastDue == true {
                SettingsRowDivider()
                PastDueRow()
            }
            SettingsRowDivider()
            LicenseKeyRow(model: model)
            SettingsRowDivider()
            ManageRow()
            #if DEBUG
            SettingsRowDivider()
            DevRevalidateRow()
            #endif
        }
        // Keep the field model's "licensed" disposition in lockstep with the
        // entitlement if it changes elsewhere (a launch revalidation that
        // revoked the license, or the dev panel forcing a state).
        .onChange(of: entitlements.state) { _, _ in model.syncToEntitlement(entitlements.state) }
    }
}

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

    @ObservationIgnored private let keychain = KeychainStore.byokLicenseKey

    init() {
        let stored = keychain.read() ?? ""
        licenseKey = stored
        // A key already in the Keychain came from a prior successful
        // activation — render `.licensed` so the pill doesn't ask the user to
        // re-activate on every Settings open.
        phase = stored.isEmpty ? .unverified : .licensed
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

    /// Reconciles the field disposition with the authoritative entitlement
    /// state (called on `.onChange`). Doesn't clobber an in-flight request.
    func syncToEntitlement(_ state: EntitlementState) {
        guard phase != .working else { return }
        // Both `.byok` and `.managed` are backed by an activated license key on
        // file, so both render `.licensed`.
        let isLicensed: Bool = { if case .managed = state { return true }; return state == .byok }()
        if isLicensed {
            phase = .licensed
            // Re-fill from the Keychain in case activation happened elsewhere.
            if trimmedKey.isEmpty, let stored = keychain.read() { licenseKey = stored }
        } else if phase == .licensed {
            // The entitlement dropped out of `.byok` (revoked / deactivated) —
            // reflect that the stored key is no longer active.
            phase = .unverified
            licenseKey = ""
        }
    }

    /// Activate (or re-activate) the typed key through the shared store.
    func activate(using entitlements: EntitlementStore) {
        let key = trimmedKey
        guard !key.isEmpty else {
            phase = .failed("Enter your license key.")
            return
        }
        phase = .working
        Task { @MainActor in
            do {
                try await entitlements.activate(licenseKey: key)
                phase = .licensed
            } catch let error as LicenseError {
                phase = .failed(error.userFacingMessage)
            } catch {
                phase = .failed("Activation failed — please try again.")
            }
        }
    }

    /// Deactivate this device (frees the LemonSqueezy slot + clears the local
    /// license), dropping the entitlement back to the trial/expired clock.
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
                phase = .failed("Couldn\u{2019}t deactivate — please try again.")
            }
        }
    }
}

// MARK: - Current plan row

private struct CurrentPlanRow: View {
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        SettingsRow(
            label: "Current Plan",
            description: planDescription,
            verticalPadding: RowMetrics.verticalPaddingTall
        ) {
            planPill
        }
    }

    private var planDescription: String {
        switch entitlements.state {
        case .trial:
            return "Your free trial is active."
        case .expired:
            return "Your free trial has ended."
        case .byok:
            return "Lifetime license \u{2014} you fund generation with your own OpenAI key."
        case .managed:
            return managedDescription
        }
    }

    /// Managed copy reads the live snapshot (credits + reset). Falls back to a
    /// neutral line before the first `/entitlement` refresh lands.
    private var managedDescription: String {
        guard let snapshot = entitlements.managedSnapshot else {
            return "Managed plan \u{2014} generation runs on Zerro-hosted credits."
        }
        let resetClause = BillingDateFormat.resetClause(snapshot.resetDate)
        if snapshot.isOutOfCredits {
            return "Out of credits this month\(resetClause). Your library stays open."
        }
        let credits = snapshot.creditsRemaining == 1 ? "1 credit left" : "\(snapshot.creditsRemaining) credits left"
        return "\(credits) this month\(resetClause)."
    }

    @ViewBuilder
    private var planPill: some View {
        switch entitlements.state {
        case .trial(let daysRemaining, _):
            PlanPill(
                text: daysRemaining == 1 ? "Trial \u{00B7} 1 day left" : "Trial \u{00B7} \(daysRemaining) days left",
                tint: Color.vfWarningAmber
            )
        case .expired:
            PlanPill(text: "Expired", tint: Color.vfRecordingRed)
        case .byok:
            PlanPill(text: "Licensed", tint: Color.vfSuccessGreen)
        case .managed(let tier, _, _):
            // Past-due tints amber (a soft warning, not a block); active is green.
            let pastDue = entitlements.managedSnapshot?.isPastDue == true
            PlanPill(
                text: pastDue
                    ? "Managed \u{00B7} \(tier.rawValue.capitalized) \u{00B7} Past due"
                    : "Managed \u{00B7} \(tier.rawValue.capitalized)",
                tint: pastDue ? Color.vfWarningAmber : Color.vfSuccessGreen
            )
        }
    }
}

// MARK: - Trial email-verification row (Phase F)

/// Shown only while `EntitlementStore.needsTrialEmailVerification` — a trial user
/// who hasn't claimed their server-funded credits yet. Opens the standalone
/// `TrialEmailCaptureView` window (via the AppDelegate opener, same path the
/// menu-bar banner uses). Non-blocking: BYOK / subscribe still work without it.
private struct TrialVerifyRow: View {
    var body: some View {
        SettingsRow(
            label: "Free Trial Credits",
            description: "Verify your email to start your free trial \u{2014} server-funded generations, no API key needed."
        ) {
            Button("Verify email") {
                AppDelegate.openTrialEmailCapture()
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }
}

// MARK: - Past-due nudge row

/// A quiet, non-blocking "Payment issue — update your card" row (§9.1), shown
/// only while the Managed subscription is `past_due`. Links to the LemonSqueezy
/// customer portal. Generation still works on remaining credits — this is
/// visibility, never a gate.
private struct PastDueRow: View {
    var body: some View {
        SettingsRow(
            label: "Payment Issue",
            description: "A recent payment didn\u{2019}t go through. Update your card to keep your plan \u{2014} you can keep generating on remaining credits in the meantime."
        ) {
            Button("Update card") {
                guard let url = BillingLinks.customerPortalURL else {
                    Log.billing.notice("settings: customer portal URL not configured yet (placeholder)")
                    return
                }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }
}

// MARK: - Date formatting

/// Shared formatting for the credit-reset date, so the menu-bar and Billing
/// surfaces phrase "resets {date}" identically.
enum BillingDateFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "{Month Day}" for a real reset date, or empty for an absent/placeholder
    /// one (`.distantFuture` is the no-snapshot placeholder).
    static func resetDate(_ date: Date?) -> String? {
        guard let date, date != .distantFuture else { return nil }
        return formatter.string(from: date)
    }

    /// " — resets {date}" clause, or "" when there's no real reset date.
    static func resetClause(_ date: Date?) -> String {
        guard let formatted = resetDate(date) else { return "" }
        return " \u{2014} resets \(formatted)"
    }
}

/// A small filled capsule for the current-plan readout. Shares the
/// `SettingsStatusPill` capsule treatment but renders arbitrary text + tint
/// (the standard pill is fixed to the four verification kinds).
private struct PlanPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 36)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.18)))
            .fixedSize(horizontal: true, vertical: true)
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
            description: "Stored in macOS Keychain. Activates online once, then works offline.",
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

    /// `.byok` and `.managed` are both license-backed → the row shows the
    /// licensed affordances (re-activate / deactivate this device).
    private var isLicensed: Bool {
        if case .managed = entitlements.state { return true }
        return entitlements.state == .byok
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
                    .fill(Color.vfPillBackground)
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

// MARK: - Manage / buy row

private struct ManageRow: View {
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        SettingsRow(
            label: label,
            description: description
        ) {
            Button(buttonTitle) { open(buttonURL) }
                .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }

    private var isManaged: Bool {
        if case .managed = entitlements.state { return true }
        return false
    }

    private var label: String {
        if isManaged { return "Manage Subscription" }
        return entitlements.state == .byok ? "Manage License" : "Buy a License"
    }

    private var description: String {
        if isManaged {
            // Note: v1 uses the my-orders portal; a per-subscription signed
            // portal URL from the LS API is the cleaner version (DEFERRED).
            return "Update your card, change plan, or cancel in the LemonSqueezy portal."
        }
        return entitlements.state == .byok
            ? "Manage your devices and order in the LemonSqueezy portal."
            : "Get a lifetime license, then activate it above."
    }

    private var buttonTitle: String {
        if isManaged { return "Manage subscription" }
        return entitlements.state == .byok ? "Manage devices" : "Get a license"
    }

    private var buttonURL: URL? {
        if isManaged { return BillingLinks.customerPortalURL }
        return entitlements.state == .byok ? BillingLinks.customerPortalURL : BillingLinks.byokCheckoutURL
    }

    private func open(_ url: URL?) {
        guard let url else {
            // Placeholder not filled yet (LS account in review).
            Log.billing.notice("settings: billing link not configured yet (placeholder)")
            return
        }
        NSWorkspace.shared.open(url)
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

#Preview("Billing · licensed") {
    BillingSection()
        .environment(EntitlementStore(trialManager: .inMemory(), licenseService: .inMemory(licensed: true)))
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("Billing · trial") {
    BillingSection()
        .environment(EntitlementStore(trialManager: .inMemory(), licenseService: .inMemory()))
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
