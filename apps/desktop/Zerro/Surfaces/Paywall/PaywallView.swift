//
//  PaywallView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  The paywall window's content. Opened ONLY by the recording-start gate
//  when `EntitlementStore.canGenerate` is false (expired trial); it never
//  auto-presents at launch (the Window scene uses
//  `.defaultLaunchBehavior(.suppressed)`).
//
//  Reuses the onboarding window's visual chrome wholesale — the same
//  `OnboardingStepLayout`, logo tile, primary/secondary button styles,
//  `vfPanelBackground`, and spacing tokens — so the two surfaces read as one
//  app. Copy is non-punitive (the trial ended, here's how to keep going).
//
//  One product, two affordances:
//    • Buy — the Zerro license ($39 one-time, covers every Zerro 1.x.x
//      release, two Macs). "Get a license" opens the Lemon Squeezy hosted
//      checkout (NSWorkspace). Generation is funded by the user's own
//      provider API keys; recordings never pass through Zerro's servers.
//    • Activate — the shared "enter your key" field (the
//      `LicenseService.activate` path). On success the paywall shows the
//      confirmation (the gate now passes).
//
//  A license that is on file but does not cover THIS build (wrong product,
//  or a different Zerro major) gets a specific notice above the pitch
//  instead of silently re-selling.
//

import AppKit
import os
import SwiftUI

// MARK: - Dynamic paywall copy

/// The headline + subheadline shown at the top of the paywall, derived from
/// WHY the window was opened (`EntitlementStore.paywallTrigger`) and the
/// current entitlement (`EntitlementState`). The window is no longer only the
/// blocked-trial wall — the menu-bar "Upgrade" entry point opens it in a
/// voluntary-upgrade / manage context too, so the copy adapts
/// instead of always showing the blocked-wall headline.
///
/// Pure + `Equatable` so it's unit-tested directly (trigger + state → copy)
/// without standing up the view.
struct PaywallCopy: Equatable {
    let headline: String
    let subheadline: String
    /// The window title-bar text, shown as "Zerro: <windowTitle>". Tracks
    /// the context so the chrome matches the body (e.g. "Manage License" for
    /// a licensed user, not the generic "Unlock").
    let windowTitle: String

    /// Resolves the copy. `.localTrialExpired` is the genuinely-gated state,
    /// so it ALWAYS gets the blocked copy even if a stale trigger survived;
    /// otherwise the explicit trigger wins, and a `nil` trigger falls back to
    /// a sensible copy for the state so the window never shows the wrong
    /// context.
    static func resolve(trigger: EntitlementStore.PaywallTrigger?, state: EntitlementState) -> PaywallCopy {
        if case .localTrialExpired = state { return .localTrialComplete }

        switch trigger {
        case .blocked:
            return .localTrialComplete
        case .voluntaryUpgrade:
            return .localTrialUpgrade
        case .manage, .apiKeyMissing:
            return .manage
        case nil:
            switch state {
            case .localTrial:        return .localTrialUpgrade
            case .byok:              return .manage
            case .localTrialExpired: return .localTrialComplete  // unreachable (handled above)
            }
        }
    }

    /// Voluntary upgrade from an ACTIVE local trial — reassure that the
    /// trial keeps working and frame the license as continuing on the user's
    /// own provider keys. Deliberately no mention of credits, generations,
    /// email, accounts, or subscriptions: the local trial has none of those.
    static let localTrialUpgrade = PaywallCopy(
        headline: "Get a Zerro license",
        subheadline: "Your free trial is still active, so buy whenever you\u{2019}re ready. A license keeps Zerro working on your own provider keys after the trial ends.",
        windowTitle: "Upgrade"
    )
    /// The local free trial has ended — the blocked purchase surface for
    /// official builds. Deliberately no mention of credits, generations,
    /// email, or accounts: the local trial has none of those.
    static let localTrialComplete = PaywallCopy(
        headline: "Your free trial has ended",
        subheadline: "Keep turning a quick screen recording and a sentence of narration into a ready-to-paste result on your own provider keys.",
        windowTitle: "Unlock"
    )
    /// A licensed user managing their license — de-emphasize the sell.
    static let manage = PaywallCopy(
        headline: "Manage your license",
        subheadline: "Activate a key, or manage your devices and billing. Everything for your license lives here.",
        windowTitle: "Manage License"
    )

    /// The license card's feature lines — the whole purchase story, one line
    /// per fact. Hoisted so the copy tests can pin the exact wording.
    static let licenseFeatureLines: [String] = [
        "Includes all Zerro \(LicenseEditionPolicy.current.requiredMajor).x.x updates",
        "Use on up to 2 Macs",
        "Bring your own OpenAI, Anthropic, or Gemini API keys",
        "You pay providers directly for usage",
        "A future major version may be sold separately",
    ]

    /// The notice for a license that is on file but doesn't cover THIS build.
    /// Names the covered major when the cached record knows it (the
    /// wrong-major case); otherwise falls back to the generic wrong-product
    /// line — the same copy activation uses.
    static func incompatibleLicenseLine(licensedMajor: Int?, requiredMajor: Int) -> String {
        if let licensedMajor, licensedMajor != requiredMajor {
            return "Your license covers Zerro \(licensedMajor).x. This version requires a Zerro \(requiredMajor) license."
        }
        return "This license key is for a different Zerro product or version."
    }
}

struct PaywallView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(EntitlementStore.self) private var entitlements

    /// Window width. Sized for the license card with comfortable padding.
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
        // The purchase-success confirmation takes precedence over the whole
        // PaywallCopy matrix: once an activation lands, the window shows
        // "you're all set" instead of the headline + license card + activate field.
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
            // licensed user reads "Zerro: Manage License").
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

    /// The option stack adapts to the entitlement:
    ///   • Licensed  → a manage link (change devices/billing in the portal) +
    ///                 the activate field. No re-sell.
    ///   • Trial / expired trial → the license card + activate.
    /// This window is an official-build surface only; community builds never
    /// open it (see `AppDelegate.openPaywall`).
    private var optionStack: some View {
        VStack(spacing: VFSpacing.md) {
            // A present-but-incompatible license (wrong product, or a
            // different Zerro major) gets the specific notice ABOVE the
            // pitch, so the user understands why they're seeing a purchase
            // surface at all.
            if entitlements.hasIncompatibleLicense {
                IncompatibleLicenseNotice(
                    licensedMajor: entitlements.incompatibleLicensedMajor
                )
            }

            if showsPlanCards {
                // The single license card. Shown only to users without a
                // license yet (trial/expired); a licensed user sees the
                // manage link instead, not a re-sell.
                LicenseCard()

                // Honest privacy note (§14.5): generation runs on the user's
                // own keys and never transits Zerro's servers.
                PrivacyNote()
            }

            // A licensed user gets a manage affordance instead of the sell
            // card — change devices / billing in the portal.
            if showsManageLink {
                ManagePlanLink()
            }

            // One shared activation path for an already-purchased key —
            // whether the user pasted it or the checkout-return
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

    /// The license sell shows only to users who don't hold one yet.
    private var showsPlanCards: Bool {
        !entitlements.hasActiveLicense
    }

    /// The manage link shows only to users who already hold the license.
    private var showsManageLink: Bool {
        entitlements.hasActiveLicense
    }
}

// MARK: - Price labels

/// DISPLAY-ONLY price label for the license card. Lemon Squeezy is the
/// actual source of truth for what the customer is charged — this string is
/// just the label we render, and MUST be kept in sync with the Lemon Squeezy
/// product price by hand (the app never sets the charge). One place, no
/// scattered literals.
private enum Price {
    // The Zerro license is $39 one-time. KEEP IN SYNC with the Lemon Squeezy
    // product price by hand — the app never sets the charge.
    static let license = "$39 one-time"
}

// MARK: - Activation model

/// Drives the shared "enter your key" flow. Mirrors `APIKeyFieldModel`'s shape:
/// a small `@Observable` field model with an explicit phase the pill renders
/// against. Activates the one product we sell — the Zerro license — through
/// `EntitlementStore.activate`, which verifies the key's product identity.
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

    /// License keys aren't as sensitive as API keys, so the field is shown in
    /// plain text with a paste affordance — friendlier than a masked field.
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
    /// renders the typed copy (including the wrong-product refusal).
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
            // The outcome is real and server-confirmed, so the funnel can
            // record it.
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

// MARK: - License card

/// The purchase card for the one product we sell: the Zerro license. Pay
/// once, covered for every release of this major version, fund generation
/// with your own provider keys. Activation of the resulting key happens
/// through the shared `ActivateLicenseCard` below.
private struct LicenseCard: View {
    var body: some View {
        OptionCardChrome(padding: VFSpacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zerro license")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.sm)
                Text(Price.license)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(PaywallCopy.licenseFeatureLines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.vfTextSecondary)
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfTextSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: VFSpacing.xs)

            // E-06: softens to disabled while the checkout URL is still a
            // placeholder — no enabled-looking button that dead-clicks into
            // the placeholder log below.
            OnboardingPrimaryButton(
                "Get a license",
                isEnabled: BillingLinks.licenseCheckoutURL != nil,
                action: openCheckout
            )
        }
    }

    private func openCheckout() {
        guard let url = BillingLinks.licenseCheckoutURL else {
            Log.billing.notice("paywall: license checkout URL not configured yet (placeholder)")
            return
        }
        Log.billing.notice("paywall: opening license checkout in browser")
        // Tier 3 analytics: fire `checkout_opened` and open the custom-data-
        // decorated URL (carries ph_distinct_id + product for server-side
        // purchase-event stitching).
        Analytics.capture("checkout_opened", [
            "product": BillingLinks.checkoutProductValue,
            "placement": "paywall"
        ])
        NSWorkspace.shared.open(BillingLinks.checkoutURL(url))
    }
}

// MARK: - Incompatible-license notice

/// Shown when a license IS on file but doesn't cover this build (wrong
/// product, or a different Zerro major). States the specific reason above
/// the purchase pitch — never a silent re-sell.
private struct IncompatibleLicenseNotice: View {
    let licensedMajor: Int?

    var body: some View {
        OptionCardChrome(alignment: .leading) {
            HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.vfWarningAmber)
                Text(PaywallCopy.incompatibleLicenseLine(
                    licensedMajor: licensedMajor,
                    requiredMajor: LicenseEditionPolicy.current.requiredMajor
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Privacy note

/// Honest one-liner on where recordings go (§14.5). Understated secondary text.
private struct PrivacyNote: View {
    var body: some View {
        Text("Your recordings go straight from your Mac to your AI provider (OpenAI, Anthropic, or Google) on your own key. They never pass through Zerro\u{2019}s servers.")
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextTertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Manage license link (licensed users)

/// Shown to a licensed user in place of the license card: a quiet link to
/// the Lemon Squeezy customer portal to manage devices and the order.
/// No-op (with a log) until the portal URL placeholder is filled.
private struct ManagePlanLink: View {
    var body: some View {
        OptionCardChrome(alignment: .leading) {
            OnboardingSecondaryButton("Manage license & devices") {
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

/// The shared "already purchased? enter your key" flow for the Zerro
/// license. Self-contained so the field state lives with the card.
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
                Text("Enter your license key")
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
/// card stretch to its container; `highlighted` is the website pricing
/// section's recommended-plan treatment (accent border + slightly lifted
/// fill).
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
                // A highlighted card keeps a quiet lift in addition to its
                // accent border without reverting to a near-black fill.
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
/// manual paste). Mirrors the onboarding window chrome
/// (`OnboardingStepLayout` + logo-tile-sized badge) so it reads as one app. The
/// detail copy + analytics plan live on `PurchaseSuccessInfo`; this view only
/// renders them and owns the dismiss / route-to-Settings actions.
private struct PurchaseSuccessView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(EntitlementStore.self) private var entitlements
    let info: PurchaseSuccessInfo

    var body: some View {
        OnboardingStepLayout {
            SuccessBadge()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("You\u{2019}re all set")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text(info.detailLine)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            OnboardingPrimaryButton("Start using Zerro") { finish() }

            // The license still needs the user's own provider key before
            // generating — give them a direct route to the Settings API-key
            // section.
            OnboardingSecondaryButton("Open Settings") { openSettings() }
        }
        .frame(minHeight: 600)
    }

    /// Clear the one-shot confirmation and close the window.
    private func finish() {
        entitlements.purchaseSuccess = nil
        dismissWindow(id: PaywallScene.windowID)
    }

    /// Route to the Settings API-key (API Keys & License) section, then close the
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

#Preview("Paywall \u{00B7} Blocked (trial expired)") {
    PaywallView()
        .environment(paywallPreviewStore(.localTrialExpired, trigger: .blocked))
}

#Preview("Paywall \u{00B7} Voluntary upgrade (trial)") {
    PaywallView()
        .environment(paywallPreviewStore(.localTrial(daysRemaining: 9), trigger: .voluntaryUpgrade))
}

#Preview("Paywall \u{00B7} Manage (licensed)") {
    PaywallView()
        .environment(paywallPreviewStore(.byok, trigger: .manage))
}

// The purchase-success confirmation: pins the licensed state, then sets the
// one-shot `purchaseSuccess` so the view renders the success screen instead
// of the buy/manage matrix.
#Preview("Paywall \u{00B7} Success (license)") {
    let store = EntitlementStore.preview(.byok)
    store.purchaseSuccess = .license
    return PaywallView().environment(store)
}
#endif
