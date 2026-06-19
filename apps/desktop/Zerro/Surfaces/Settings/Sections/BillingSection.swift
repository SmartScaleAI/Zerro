//
//  BillingSection.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase C, restructured for multi-model 6E/6F — the MANAGED side of the
//  either/or Account & Billing pane (AccountBillingPane). Presented as a
//  subscription + credits, never a "lifetime license":
//    1. Usage meter    — 6F: combined balance headline, a bar tracking
//                        PLAN-credit consumption (plan_credits_used/_limit —
//                        never the combined balance, which over-reports for
//                        top-up holders, F4), reset date, and the inline
//                        top-up / upgrade prompt (CreditDisplay.isLowBalance,
//                        the same threshold as the menu-bar prompt).
//    2. Current plan   — reads `EntitlementStore.state` and renders the live
//                        standing (Trial · N credits / Expired / Managed) with
//                        a status pill. Plan-state strings render ONLY here —
//                        the BYOK pane never shows them.
//    3. Subscription key — the LemonSqueezy activation key from the purchase
//                        email (the entitlement is still key-delivered under
//                        the hood; it is presented as "your subscription").
//    4. Subscribe / manage — the Managed checkout or the customer portal.
//    5. (DEBUG) Force re-validate.
//
//  This file also hosts `BYOKLicenseSection` (the BYOK pane's license rows) so
//  both reuse the same private field model + key row.
//

import AppKit
import os
import SwiftUI

struct BillingSection: View {
    @Environment(EntitlementStore.self) private var entitlements
    @State private var model = BillingLicenseModel(expectedProduct: .managed)

    var body: some View {
        SettingsSection("Plan & Credits") {
            // Multi-model 6F: the usage meter leads the card whenever there
            // is a balance to meter (Managed with a snapshot, or a trial with
            // a known grant). Expired/pre-snapshot states skip straight to
            // the plan row.
            if showsUsageMeter {
                UsageMeterRow()
                SettingsRowDivider()
            }
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
            LicenseKeyRow(model: model, context: .subscription)
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

    private var showsUsageMeter: Bool {
        switch entitlements.state {
        case .managed: return entitlements.managedSnapshot != nil
        case .trial(let credits): return credits != nil
        case .byok, .expired: return false
        }
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

    @ObservationIgnored private let keychain: KeychainSlot
    @ObservationIgnored private let productKindSlot: KeychainSlot

    /// Which product THIS row represents. A Managed subscription key and a BYOK
    /// license key share the `byokLicenseKey` slot (both are LemonSqueezy keys
    /// activated through the same path), disambiguated only by
    /// `licenseProductKind`. The model adopts the on-file key — and renders the
    /// licensed affordances — only when that discriminator matches this row's
    /// product, so a managed key never leaks into the BYOK pane (and vice-versa).
    let expectedProduct: LicenseProductKind

    /// Slots default to the production Keychain statics; tests inject in-memory
    /// doubles (mirroring `EntitlementStore`'s `productKindSlot` seam).
    init(
        expectedProduct: LicenseProductKind,
        keychain: KeychainSlot = KeychainStore.byokLicenseKey,
        productKindSlot: KeychainSlot = KeychainStore.licenseProductKind
    ) {
        self.expectedProduct = expectedProduct
        self.keychain = keychain
        self.productKindSlot = productKindSlot
        let onFileKind = LicenseProductKind(rawValue: productKindSlot.read() ?? "")
        let stored = keychain.read() ?? ""
        // A key already in the Keychain came from a prior successful activation —
        // render `.licensed` so the pill doesn't ask the user to re-activate on
        // every Settings open. But only adopt it if it belongs to THIS row's
        // product; otherwise this row stays empty and unverified.
        if !stored.isEmpty, onFileKind == expectedProduct {
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

    /// Reconciles the field disposition with the authoritative entitlement
    /// state (called on `.onChange`). Doesn't clobber an in-flight request.
    func syncToEntitlement(_ state: EntitlementState) {
        guard phase != .working else { return }
        // The entitlement state maps 1:1 to a product — this row goes `.licensed`
        // only when the active entitlement is THIS row's product, so a managed
        // entitlement never marks the BYOK row licensed (and vice-versa).
        let matchesThisRow: Bool = {
            switch expectedProduct {
            case .managed: if case .managed = state { return true }; return false
            case .byok:    return state == .byok
            }
        }()
        if matchesThisRow {
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
        case .trial(let creditsRemaining):
            // §1.5: the unit is CREDITS, never a flat generation count.
            guard let creditsRemaining else { return "Your free trial is active." }
            return creditsRemaining == 1
                ? "1 trial credit left."
                : "\(creditsRemaining) trial credits left."
        case .expired:
            return "You\u{2019}ve used your trial credits \u{2014} subscribe below to keep going."
        case .byok:
            // Shown only transiently (a `.byok` user previewing the Managed
            // pane via the switch link); never the lifetime-license framing.
            return "You\u{2019}re on BYOK \u{2014} subscribe below to switch to Zerro-hosted credits."
        case .managed:
            return managedDescription
        }
    }

    /// Managed copy describes the SUBSCRIPTION (price + allowance); the live
    /// balance lives in the usage meter above, so it isn't duplicated here.
    private var managedDescription: String {
        let limit = entitlements.managedSnapshot.map { $0.planCreditsLimit ?? $0.creditsLimit }
        let allowance = limit.map { "\($0)" } ?? "300"
        return "\(allowance) credits every month. $15/month, or $12/month billed yearly."
    }

    /// The compact trial pill text. Shows the remaining credit balance when
    /// known, or a bare "Trial" before the user has been granted any
    /// (the "Free Trial Credits" verify row sits below for that case).
    private func trialPillText(creditsRemaining: Int?) -> String {
        guard let creditsRemaining else { return "Trial" }
        return creditsRemaining == 1 ? "Trial \u{00B7} 1 left" : "Trial \u{00B7} \(creditsRemaining) left"
    }

    @ViewBuilder
    private var planPill: some View {
        switch entitlements.state {
        case .trial(let creditsRemaining):
            PlanPill(
                text: trialPillText(creditsRemaining: creditsRemaining),
                tint: Color.vfWarningAmber
            )
        case .expired:
            PlanPill(text: "Expired", tint: Color.vfRecordingRed)
        case .byok:
            PlanPill(text: "BYOK", tint: Color.vfSuccessGreen)
        case .managed:
            // Past-due tints amber (a soft warning, not a block); active is green.
            let pastDue = entitlements.managedSnapshot?.isPastDue == true
            PlanPill(
                text: pastDue ? "Managed \u{00B7} Past due" : "Managed",
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
            description: "Verify your email to start your free trial \u{2014} server-funded credits, no API key needed."
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
    /// Which pane is hosting the row — the SAME activation mechanism (the
    /// LemonSqueezy key from the purchase email; the server resolves whether
    /// it's a subscription or a BYOK license), presented in the host pane's
    /// language. Never "lifetime license".
    enum Context {
        case subscription
        case byokLicense
    }

    @Environment(EntitlementStore.self) private var entitlements
    @Bindable var model: BillingLicenseModel
    var context: Context = .subscription
    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsRow(
            label: context == .subscription ? "Subscription Key" : "License Key",
            description: context == .subscription
                ? "From your purchase email \u{2014} activates your subscription on this device. Stored in macOS Keychain."
                : "Your BYOK license key. Stored in macOS Keychain; activates online once, then works offline.",
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

    /// Licensed affordances (Verified pill, Re-activate / Deactivate) belong to
    /// the row whose product matches the active entitlement — so the managed
    /// key's affordances never render in the BYOK pane (and vice-versa).
    private var isLicensed: Bool {
        switch context {
        case .subscription:
            if case .managed = entitlements.state { return true }
            return false
        case .byokLicense:
            return entitlements.state == .byok
        }
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

// MARK: - Subscribe / manage row (Managed pane)

private struct ManageRow: View {
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        SettingsRow(
            label: isManaged ? "Manage Subscription" : "Subscribe",
            description: description
        ) {
            Button(isManaged ? "Manage subscription" : "Subscribe") {
                // Manage = portal (not a checkout); Subscribe = Managed checkout.
                if isManaged {
                    openBillingLink(BillingLinks.customerPortalURL)
                } else {
                    openCheckout(BillingLinks.proCheckoutURL, product: .subscriptionPro,
                                 trialGrantId: entitlements.trialGrantIdForCheckout)
                }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }

    private var isManaged: Bool {
        if case .managed = entitlements.state { return true }
        return false
    }

    private var description: String {
        if isManaged {
            // Note: v1 uses the my-orders portal; a per-subscription signed
            // portal URL from the LS API is the cleaner version (DEFERRED).
            return "Update your card, change plan, or cancel in the LemonSqueezy portal."
        }
        return "$15/month, or $12/month billed yearly \u{2014} 300 credits every month, all six models."
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
/// `checkout_opened{product}` and opens the custom-data-decorated URL
/// (ph_distinct_id + product → webhook stitching, Tier 3 §0). Portal/manage
/// opens stay on `openBillingLink` — they are not checkouts. Same nil-placeholder
/// early-return: an unconfigured product fires nothing.
private func openCheckout(_ url: URL?, product: BillingLinks.CheckoutProduct, trialGrantId: String? = nil) {
    guard let url else {
        Log.billing.notice("settings: checkout link not configured yet (placeholder)")
        return
    }
    // Tier 3 §0: tag the placement so the monetization funnel can tell the
    // Settings checkouts apart from the paywall's (`placement: "paywall"`).
    Analytics.capture("checkout_opened", ["product": product.rawValue, "placement": "settings"])
    // A converting trial user carries their grant id (custom_data) so the webhook
    // links this subscription to that exact trial grant — see BillingLinks.
    NSWorkspace.shared.open(BillingLinks.checkoutURL(url, product: product, trialGrantId: trialGrantId))
}

// MARK: - Usage meter (multi-model 6F)

/// The glanceable usage card at the top of the Managed billing section —
/// Managed/Trial ONLY (the BYOK pane never composes it).
///
/// • Headline: the COMBINED balance (plan + top-up — matches the picker, F4)
///   against the plan cap. A top-up holder's headline can exceed the cap;
///   the breakdown line explains it.
/// • Bar: PLAN-credit consumption only (`plan_credits_used/_limit`) — the
///   thing that resets. Hidden when the backend/cache predates the breakdown
///   fields rather than guessed from the combined number.
/// • Trial: same card against the trial grant. The bar draws against the
///   grant total (`trial_credits_limit`, cached from verify/resume — E4);
///   when that's unknown (older server / pre-update cache) the trial
///   variant degrades to bar-less.
/// • Inline prompt: the SAME low-balance threshold as the generation-flow
///   prompt (CreditDisplay.isLowBalance — a price-agnostic balance floor).
private struct UsageMeterRow: View {
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            switch entitlements.state {
            case .managed:
                if let snapshot = entitlements.managedSnapshot {
                    managedMeter(snapshot)
                }
            case .trial(let credits):
                if let credits {
                    trialMeter(credits)
                }
            case .byok, .expired:
                EmptyView()
            }
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.vertical, RowMetrics.verticalPaddingTall)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Managed

    @ViewBuilder
    private func managedMeter(_ snapshot: ManagedEntitlementSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
            Text(CreditDisplay.meterHeadline(
                combined: snapshot.creditsRemaining,
                planLimit: snapshot.planCreditsLimit ?? snapshot.creditsLimit
            ))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.vfTextPrimary)
            Text("remaining this month")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Spacer(minLength: 0)
            if let reset = BillingDateFormat.resetDate(snapshot.resetDate) {
                Text("Resets \(reset)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
            }
        }

        if let used = snapshot.planCreditsUsed, let limit = snapshot.planCreditsLimit {
            meterBar(fraction: CreditDisplay.planFractionRemaining(planUsed: used, planLimit: limit))
            if let topup = snapshot.topupCreditsRemaining, topup > 0 {
                Text("Plan \(max(0, limit - used)) + top-up \(topup). Top-up credits survive the monthly reset and expire 12 months from purchase.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        topupPrompt(balance: snapshot.creditsRemaining)
    }

    // MARK: Trial

    @ViewBuilder
    private func trialMeter(_ credits: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
            Text(CreditDisplay.creditsHeadline(credits))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
            Text("left in your free trial")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Spacer(minLength: 0)
        }

        if let limit = entitlements.trialCreditsLimit, limit > 0 {
            meterBar(fraction: CreditDisplay.trialFractionRemaining(remaining: credits, limit: limit))
        }

        // Trials can't buy top-ups (plan §1.4) — the inline prompt is the
        // Managed upgrade instead, escalating on the shared low threshold.
        if isLow(balance: credits) {
            HStack(spacing: VFSpacing.sm) {
                Text("Running low \u{2014} upgrade to keep going")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfWarningAmber)
                Button("Upgrade to Managed") {
                    openCheckout(BillingLinks.proCheckoutURL, product: .subscriptionPro,
                                 trialGrantId: entitlements.trialGrantIdForCheckout)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
            }
        }
    }

    // MARK: Shared pieces

    private func meterBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.vfPillBackground)
                Capsule()
                    .fill(Color.vfDevAccent)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }

    private func isLow(balance: Int) -> Bool {
        CreditDisplay.isLowBalance(balance: balance)
    }

    /// 6F.4 — comfortable balance: a quiet packs line; low balance: escalate
    /// in amber. Pack chips whose checkout link isn't configured resolve nil
    /// and drop out (BillingLinks placeholder pattern); with neither link
    /// filled, only the low-state notice renders.
    @ViewBuilder
    private func topupPrompt(balance: Int) -> some View {
        let low = isLow(balance: balance)
        let anyLink = BillingLinks.boostTopupCheckoutURL != nil || BillingLinks.powerTopupCheckoutURL != nil
        if low || anyLink {
            HStack(spacing: VFSpacing.sm) {
                Text(low ? "Running low \u{2014} top up to keep going" : "Need more? Top-up packs:")
                    .font(.system(size: 12))
                    .foregroundStyle(low ? Color.vfWarningAmber : Color.vfTextSecondary)
                if let boost = BillingLinks.boostTopupCheckoutURL {
                    Button("Boost \u{00B7} 200 \u{00B7} $10") { openCheckout(boost, product: .topupBoost) }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
                if let power = BillingLinks.powerTopupCheckoutURL {
                    Button("Power \u{00B7} 500 \u{00B7} $22") { openCheckout(power, product: .topupPower) }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }
        }
    }
}

// MARK: - BYOK license section (hosted here to share the private field model)

/// The BYOK pane's license rows (AccountBillingPane composes this below the
/// API-key section). The $69 one-time BYOK license: activation key field +
/// get/manage links. No plan/credit/meter UI — that's the Managed pane's.
struct BYOKLicenseSection: View {
    @Environment(EntitlementStore.self) private var entitlements
    @State private var model = BillingLicenseModel(expectedProduct: .byok)

    var body: some View {
        SettingsSection("BYOK License") {
            LicenseKeyRow(model: model, context: .byokLicense)
            SettingsRowDivider()
            ByokManageRow()
        }
        .onChange(of: entitlements.state) { _, _ in model.syncToEntitlement(entitlements.state) }
    }
}

private struct ByokManageRow: View {
    @Environment(EntitlementStore.self) private var entitlements

    private var isLicensed: Bool { entitlements.state == .byok }

    var body: some View {
        SettingsRow(
            label: isLicensed ? "Manage License" : "Get a License",
            description: isLicensed
                ? "Manage your devices and order in the LemonSqueezy portal."
                : "$69 one-time \u{2014} includes 1 year of updates. You pay your providers directly for usage."
        ) {
            Button(isLicensed ? "Manage devices" : "Get a license") {
                // Manage devices = portal (not a checkout); Get a license = BYOK checkout.
                if isLicensed {
                    openBillingLink(BillingLinks.customerPortalURL)
                } else {
                    openCheckout(BillingLinks.byokCheckoutURL, product: .byok)
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
#Preview("Plan & Credits · managed") {
    BillingSection()
        .environment(EntitlementStore.preview(
            .managed(creditsRemaining: 248, resetDate: .now.addingTimeInterval(86_400 * 12))
        ))
        .environment(PreferencesStore())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("Plan & Credits · trial") {
    BillingSection()
        .environment(EntitlementStore.preview(.trial(creditsRemaining: 34)))
        .environment(PreferencesStore())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("BYOK License") {
    BYOKLicenseSection()
        .environment(EntitlementStore.preview(.byok))
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
#endif
