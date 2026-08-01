//
//  OnboardingSteps.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  The step views. The merged Permissions step shows Screen Recording
//  and Microphone as two rows on one screen, each branching on a
//  tri-state sub-state derived from PermissionsManager (plus a fourth
//  "needs relaunch" sub-state for Screen Recording), with DEBUG-only
//  override pins on OnboardingState so the dev panel can preview any
//  sub-state per row without toggling system permissions.
//
//  Sub-state semantics (per row):
//    • notDetermined — an Allow control triggers the OS request.
//    • granted — a checkmark indicator.
//    • denied — Open System Settings deep-link + Check again.
//    • needs-relaunch (Screen only) — Relaunch + Check again.
//  Advancing is an explicit user action: the single Continue Setup
//  button stays disabled until BOTH permissions are granted (no
//  auto-advance).
//

import AppKit
import os
import SwiftUI

// MARK: - Welcome

struct WelcomeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Welcome to Zerro")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                VStack(spacing: VFSpacing.sm) {
                    Text("Record your screen, explain what you want, and get it done faster.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("We\u{2019}ll set up a few things. It takes about a minute.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vfTextTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        } actions: {
            OnboardingPrimaryButton("Get Started") { onboarding.advance() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.vfTextSecondary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Email verification (Phase F — required step)

@MainActor
enum TrialEmailNoCodeContinuation {
    static func perform(on onboarding: OnboardingState) {
        perform(on: onboarding) { Analytics.capture($0, $1) }
    }

    static func perform(
        on onboarding: OnboardingState,
        capture: (_ event: String, _ properties: [String: Any]) -> Void
    ) {
        // This action intentionally has no TrialCreditsManager dependency, so it
        // cannot persist an email/token/grant or grant credits.
        capture("trial_verification_skipped", [
            "reason": "code_not_received",
            "surface": "onboarding",
        ])
        Log.billing.notice("trial email verification skipped after no-code help — continuing without credits")
        onboarding.advance()
    }
}

/// The required email-verification step (right after Welcome). Every new user
/// verifies an email here; on success the server-funded trial credits are
/// granted (via `TrialCreditsManager` / `trial-start`) so the trial works
/// afterward with no mid-task interruption.
///
/// Delivery-failure resilience: repeated infrastructure errors OR the explicit
/// "Didn't get a code?" help path may continue WITHOUT trial credits. No email
/// or token is persisted, and Settings keeps the verification affordance.
struct EmailStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(TrialCreditsManager.self) private var trialCredits
    @Environment(EntitlementStore.self) private var entitlements

    private enum Step { case email, code }

    @State private var step: Step = .email
    @State private var email: String = ""
    @State private var code: String = ""
    @State private var working: Bool = false
    @State private var verified: Bool = false
    /// A spent email or device is informational, not a retryable send failure.
    /// Both outcomes remain continuable without granting or resetting credits.
    @State private var terminalState: TrialEmailTerminalState?
    @State private var showNoCodeHelp: Bool = false
    @State private var errorMessage: String?
    /// True when the last error was an infrastructure failure (network/5xx/send)
    /// rather than user error (wrong code, etc.) — only these unlock the
    /// infra fallback and surface "Resend code".
    @State private var errorIsSystem: Bool = false
    @State private var systemFailureCount: Int = 0
    @FocusState private var fieldFocused: Bool
    @AppStorage(OnboardingPersistenceKeys.legacyBYOKPathActive) private var showBYOKFlow = false

    /// After this many CONSECUTIVE system-class failures, offer the infra
    /// fallback so a backend/Resend outage can never permanently trap the user.
    private static let maxSystemFailuresBeforeFallback = 2

    private var showInfraFallback: Bool { systemFailureCount >= Self.maxSystemFailuresBeforeFallback }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailLooksValid: Bool { trimmedEmail.contains("@") && trimmedEmail.contains(".") }

    var body: some View {
        Group {
            if showBYOKFlow {
                BYOKOnboardingFlowView {
                    showBYOKFlow = false
                    prefill()
                }
            } else {
                emailFlow
            }
        }
    }

    private var emailFlow: some View {
        OnboardingStepLayout {
            OnboardingIconTile(systemName: "envelope.fill")
        } content: {
            VStack(spacing: VFSpacing.lg) {
                VStack(spacing: VFSpacing.md) {
                    Text(headline)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.vfTextPrimary)
                        .multilineTextAlignment(.center)
                    Text(subhead)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !verified && terminalState == nil {
                    field
                }
            }
        } actions: {
            actions
        }
        .onAppear(perform: prefill)
    }

    // MARK: - Copy

    private var headline: String {
        if verified { return "Email verified" }
        if let terminalState { return terminalState.headline }
        return step == .email ? "Verify your email" : "Enter your code"
    }

    private var subhead: String {
        if verified {
            return "Your free trial is ready. You\u{2019}re good to go."
        }
        if let terminalState { return terminalState.message }
        switch step {
        case .email:
            return "Verify your email to start your free trial: no credit card, no API key. We\u{2019}ll send a 6-digit code."
        case .code:
            return TrialEmailCopy.codeDelivery(to: trimmedEmail)
        }
    }

    // MARK: - Field

    @ViewBuilder
    private var field: some View {
        VStack(alignment: .leading, spacing: VFSpacing.xs) {
            switch step {
            case .email:
                fieldCapsule {
                    TextField("you@example.com", text: $email)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextPrimary)
                        .focused($fieldFocused)
                        .disabled(working)
                        .onChange(of: email) { _, _ in clearErrorOnEdit() }
                        .onSubmit(sendCode)
                }
            case .code:
                fieldCapsule {
                    TextField("123456", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.vfTextPrimary)
                        .focused($fieldFocused)
                        .disabled(working)
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(6))
                            if digits != newValue { code = digits }
                            clearErrorOnEdit()
                        }
                        .onSubmit(verify)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfRecordingRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fieldCapsule<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        HStack(spacing: VFSpacing.sm) {
            inner()
            if working {
                ProgressView().controlSize(.small).progressViewStyle(.circular)
            }
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .fill(Color.vfControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if verified || terminalState != nil {
            // Verified and genuinely already-used states advance normally.
            OnboardingPrimaryButton("Continue", systemImage: "arrow.right") { onboarding.advance() }
        } else {
            switch step {
            case .email:
                if working {
                    OnboardingPrimaryButton("Sending\u{2026}", isEnabled: false) { }
                } else {
                    OnboardingPrimaryButton("Send code", isEnabled: emailLooksValid) { sendCode() }
                }
                byokTrialButton
            case .code:
                if working {
                    OnboardingPrimaryButton("Verifying\u{2026}", isEnabled: false) { }
                } else {
                    OnboardingPrimaryButton("Verify", isEnabled: trimmedCode.count == 6) { verify() }
                }
                Button(showNoCodeHelp ? "Hide delivery options" : "Didn\u{2019}t get a code?") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showNoCodeHelp.toggle()
                    }
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .disabled(working)
                    .padding(.top, 2)
                if showNoCodeHelp {
                    noCodeHelp
                }
            }

            // Infra fallback — appears ONLY after repeated SYSTEM failures, so a
            // backend/Resend outage can't trap the user. Framed as an outage
            // consequence, NOT a skip; the user gets no credits until they
            // verify later in Settings → Billing.
            if showInfraFallback {
                infraFallback
            }
        }
    }

    private var byokTrialButton: some View {
        Button("Use my own API keys instead") {
            fieldFocused = false
            onboarding.selectPath(.byok)
            showBYOKFlow = true
            Analytics.capture("byok_trial_selected", ["surface": "onboarding"])
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Color.vfTextTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 2)
    }

    private var infraFallback: some View {
        VStack(spacing: VFSpacing.xs) {
            Text("We\u{2019}re having trouble reaching our servers. You can continue and finish verifying your email later in Settings \u{2192} Billing.")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue for now") {
                Log.billing.notice("trial email verification: infra fallback taken in onboarding — entering app WITHOUT granted credits (signals a trial-start/Resend outage)")
                onboarding.advance()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.vfTextSecondary)
        }
        .padding(.top, VFSpacing.sm)
    }

    private var noCodeHelp: some View {
        VStack(spacing: VFSpacing.xs) {
            Text("Check spam or wait a minute before trying again. You can also continue without trial credits and verify later in Settings \u{2192} Billing.")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Resend code", action: sendCode)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
                .disabled(working)

            Button("Use a different email", action: useDifferentEmail)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)

            Button("Continue without trial", action: continueWithoutTrial)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
        }
        .padding(.top, VFSpacing.xs)
    }

    // MARK: - Behavior

    private func prefill() {
        // Pre-fill the remembered email for convenience ONLY. Do NOT treat a
        // locally-cached email / credit count as "verified": verification is
        // server-side truth, and a deleted server grant must not still read as
        // verified locally (the bug this guards against). The user always
        // re-verifies with a fresh code here — `verify_trial_grant` resumes the
        // same grant server-side (no refarm), so re-verifying a still-valid email
        // is cheap and simply continues with the existing balance.
        if email.isEmpty, let remembered = trialCredits.rememberedEmail {
            email = remembered
        }
        fieldFocused = true
    }

    private func clearErrorOnEdit() {
        if errorMessage != nil { errorMessage = nil }
    }

    private func sendCode() {
        let address = trimmedEmail
        guard emailLooksValid else {
            errorMessage = TrialStartError.invalidEmail.userMessage
            errorIsSystem = false
            return
        }
        working = true
        errorMessage = nil
        Task { @MainActor in
            defer { working = false }
            do {
                try await trialCredits.requestCode(email: address)
                step = .code
                code = ""
                showNoCodeHelp = false
                fieldFocused = true
            } catch let error as TrialStartError {
                handle(error)
            } catch {
                handleSystem("Couldn\u{2019}t send the code. Please try again.", error)
            }
        }
    }

    private func verify() {
        let address = trimmedEmail
        let entered = trimmedCode
        guard entered.count == 6 else {
            errorMessage = TrialStartError.invalidCode.userMessage
            errorIsSystem = false
            return
        }
        working = true
        errorMessage = nil
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await trialCredits.verifyCode(email: address, code: entered)
                // Token + email + credits are now stored by TrialCreditsManager.
                // Refresh the entitlement so the trial credits are reflected
                // (and the gating affordance unlocks). Then the user continues.
                entitlements.refresh()
                systemFailureCount = 0
                verified = true
                Log.billing.notice("trial email verified during onboarding")
            } catch let error as TrialStartError {
                handle(error)
            } catch {
                handleSystem("Couldn\u{2019}t verify the code. Please try again.", error)
            }
        }
    }

    /// Map a typed `TrialStartError`, distinguishing USER state (stay on the
    /// step) from SYSTEM/infra failure (counts toward the fallback).
    private func handle(_ error: TrialStartError) {
        switch error {
        case .alreadyUsed:
            // Not an error — the email's trial is spent. Let them continue.
            terminalState = TrialEmailTerminalState(error)
            errorMessage = nil
        case .deviceTrialUsed:
            // Not an error — this Mac's trial is spent (a new email won't help).
            // Distinct copy, still continuable. Log so we can measure how often
            // the hard block fires on real (possibly shared-machine) users.
            terminalState = TrialEmailTerminalState(error)
            errorMessage = nil
            Log.billing.notice("trial email verification: device already trialed (onboarding) — continuing without credits")
        case .network, .server, .sendFailed, .malformedResponse, .malformedRequest,
             .invalidContactToken:
            handleSystem(error.userMessage, error)
        case .invalidEmail, .disposableEmail, .invalidCode, .codeExpired,
             .tooManyAttempts, .rateLimited:
            // User-correctable → stay on the step, no fallback unlock.
            errorMessage = error.userMessage
            errorIsSystem = false
        }
    }

    private func handleSystem(_ message: String, _ error: Error) {
        errorMessage = message
        errorIsSystem = true
        systemFailureCount += 1
        Log.billing.error("trial email verification system failure #\(systemFailureCount, privacy: .public) during onboarding: \(String(describing: error), privacy: .public)")
    }

    private func useDifferentEmail() {
        step = .email
        code = ""
        errorMessage = nil
        errorIsSystem = false
        showNoCodeHelp = false
        fieldFocused = true
    }

    private func continueWithoutTrial() {
        TrialEmailNoCodeContinuation.perform(on: onboarding)
    }
}

// MARK: - Permissions (merged Screen Recording + Microphone)

/// One native-forward screen for both macOS permissions Zerro needs. Screen
/// Recording and Microphone each render as their own row with their own state
/// and action, while a single Continue button stays disabled until BOTH are
/// granted and live in the current process.
///
/// Advancing is an explicit user action — there is NO auto-advance. The
/// per-row controls reflect each permission's effective sub-state (with a
/// DEBUG dev-panel pin override per row), but the Continue gate reads the
/// LIVE `permissions.*` values so a pin can't let a tester past the real
/// gate.
struct PermissionsStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.dismissWindow) private var dismissWindow

    #if DEBUG
    /// Canvas-only overrides keep visual state previews internally consistent
    /// without weakening the live production gate or mutating macOS TCC.
    private let previewContinueGate: Bool?
    private let previewScreenNeedsRelaunch: Bool?

    init(
        previewContinueGate: Bool? = nil,
        previewScreenNeedsRelaunch: Bool? = nil
    ) {
        self.previewContinueGate = previewContinueGate
        self.previewScreenNeedsRelaunch = previewScreenNeedsRelaunch
    }
    #else
    init() { }
    #endif

    /// Per-row display state honors the DEBUG dev-panel pin so each
    /// sub-state can be previewed without toggling system permissions.
    private var effectiveScreen: PermissionStatus {
        onboarding.pinnedScreenSubState ?? permissions.screenRecordingStatus
    }

    private var effectiveMic: PermissionStatus {
        onboarding.pinnedMicSubState ?? permissions.microphoneStatus
    }

    /// M1: the "granted in Settings but not live in this process" recovery
    /// path. Takes priority over the tri-state for the Screen Recording row
    /// so the user is offered a Relaunch affordance instead of a "denied"
    /// row that contradicts their System Settings toggle. Suppressed while a
    /// dev pin is active so the panel can still inspect the base tri-state.
    private var screenNeedsRelaunch: Bool {
        #if DEBUG
        if let previewScreenNeedsRelaunch { return previewScreenNeedsRelaunch }
        #endif
        return onboarding.pinnedScreenSubState == nil &&
            permissions.screenRecordingNeedsRelaunch
    }

    /// Continue is gated on the LIVE OS values (never the dev pins) so a
    /// pinned sub-state can't let a tester advance past the real gate —
    /// matches the prior per-step production behavior.
    ///
    /// Also blocks while `screenRecordingNeedsRelaunch`: in that state
    /// `CGPreflightScreenCaptureAccess()` reads `.granted` even though live
    /// capture fails until the app is relaunched, so without this check
    /// Continue would enable while the Screen Recording row still shows the
    /// "Relaunch Zerro" affordance — letting a user finish onboarding into a
    /// state where their first recording fails.
    private var bothGranted: Bool {
        #if DEBUG
        if let previewContinueGate { return previewContinueGate }
        #endif
        return OnboardingPermissionsPolicy.canContinue(
            screenStatus: permissions.screenRecordingStatus,
            microphoneStatus: permissions.microphoneStatus,
            screenNeedsRelaunch: permissions.screenRecordingNeedsRelaunch
        )
    }

    private var screenPresentationState: OnboardingPermissionPresentationState {
        OnboardingPermissionsPolicy.presentationState(
            for: effectiveScreen,
            needsRelaunch: screenNeedsRelaunch
        )
    }

    private var microphonePresentationState: OnboardingPermissionPresentationState {
        OnboardingPermissionsPolicy.presentationState(for: effectiveMic)
    }

    /// Re-keys the polling `.task` whenever either effective status changes,
    /// so an out-of-band System Settings toggle flips the row within ~1s.
    private var pollKey: PollKey {
        PollKey(screen: effectiveScreen, mic: effectiveMic)
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            OnboardingSetupHero(
                systemName: "viewfinder",
                title: "Allow Zerro to see and hear",
                description: "These permissions are used only when you start a recording. Zerro stays quiet in your menu bar the rest of the time."
            )

            VStack(spacing: 10) {
                screenRow
                micRow
            }

            PermissionPrivacyNote()

            OnboardingPrimaryButton(
                onboarding.hasCompletedOnboarding ? "Done" : "Continue",
                systemImage: onboarding.hasCompletedOnboarding ? nil : "arrow.right",
                isEnabled: bothGranted
            ) {
                continueFromPermissions()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.xxl)
        // Single combined poller: poll iff either row is denied, so two
        // callers can't fight over the one shared timer. Re-runs on every
        // status transition via `pollKey`; stops when neither row is denied
        // and on disappear.
        .task(id: pollKey) {
            let needsPolling = effectiveScreen == .denied || effectiveMic == .denied
            if needsPolling { permissions.startPolling() } else { permissions.stopPolling() }
        }
        .onDisappear { permissions.stopPolling() }
    }

    // MARK: Rows

    private var screenRow: some View {
        PermissionRow(
            systemName: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            description: screenDescription,
            state: screenPresentationState
        ) {
            screenControl
        }
    }

    private var micRow: some View {
        PermissionRow(
            systemName: "mic.fill",
            title: "Microphone",
            description: microphoneDescription,
            state: microphonePresentationState
        ) {
            micControl
        }
    }

    private var screenDescription: String {
        switch screenPresentationState {
        case .request, .granted:
            return "Captures only the area you choose."
        case .denied:
            return "Turn this on in System Settings, then check again."
        case .needsRelaunch:
            return "Permission is on. Relaunch Zerro to apply it."
        }
    }

    private var microphoneDescription: String {
        switch microphonePresentationState {
        case .request, .granted:
            return "Hears the explanation you narrate."
        case .denied:
            return "Turn this on in System Settings, then check again."
        case .needsRelaunch:
            // Microphone never enters this state, but keeping the mapping
            // exhaustive makes the row safe if the policy grows later.
            return "Relaunch Zerro to apply this permission."
        }
    }

    // MARK: Trailing controls

    @ViewBuilder
    private var screenControl: some View {
        switch screenPresentationState {
        case .needsRelaunch:
            PermissionActionStack {
                PermissionMiniButton("Relaunch Zerro", prominent: true) {
                    permissions.relaunchToApplyScreenRecording()
                }
                PermissionMiniButton("Check again") {
                    Task { await permissions.probeScreenRecordingEffectiveness() }
                }
            }
        case .request:
            PermissionAllowButton { permissions.requestScreenRecording() }
        case .granted:
            PermissionGrantedIndicator()
        case .denied:
            PermissionActionStack {
                PermissionMiniButton("Open Settings", prominent: true) {
                    NSWorkspace.shared.open(SystemSettingsURLs.screenRecording)
                }
                // This live probe distinguishes granted, denied, and the
                // macOS state that requires a process relaunch.
                PermissionMiniButton("Check again") {
                    Task { await permissions.probeScreenRecordingEffectiveness() }
                }
            }
        }
    }

    @ViewBuilder
    private var micControl: some View {
        switch microphonePresentationState {
        case .request:
            PermissionAllowButton { Task { await permissions.requestMicrophone() } }
        case .granted:
            PermissionGrantedIndicator()
        case .denied:
            PermissionActionStack {
                PermissionMiniButton("Open Settings", prominent: true) {
                    NSWorkspace.shared.open(SystemSettingsURLs.microphone)
                }
                PermissionMiniButton("Check again") { permissions.refreshStatuses() }
            }
        case .needsRelaunch:
            EmptyView()
        }
    }

    private func continueFromPermissions() {
        // A COMPLETED user lands here only through the record gate after a
        // permission is revoked. Return them to the app instead of replaying
        // the final onboarding route and completion side effects.
        if onboarding.hasCompletedOnboarding {
            if onboarding.needsConsent {
                onboarding.beginReconsent()
            } else {
                dismissWindow(id: OnboardingScene.windowID)
            }
        } else {
            onboarding.advance()
        }
    }

    /// Equatable key for `.task(id:)` — `PermissionStatus` is Equatable, so a
    /// struct of the two effective statuses re-runs the poller on any
    /// transition. (`.task(id:)` only requires Equatable, not Hashable.)
    private struct PollKey: Equatable {
        let screen: PermissionStatus
        let mic: PermissionStatus
    }
}

// MARK: - Permission row + controls

/// A single permission row: icon tile, title, one-line description, and a
/// trailing control reflecting that permission's effective sub-state.
private struct PermissionRow<Trailing: View>: View {
    let systemName: String
    let title: String
    let description: String
    let state: OnboardingPermissionPresentationState
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.vfTextPrimary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: VFSpacing.sm)

            trailing()
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, VFSpacing.md)
        .frame(minHeight: 70)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: VFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        switch state {
        case .request:
            return Color.vfHairline
        case .granted:
            return Color.vfSuccessGreen.opacity(0.2)
        case .denied:
            return Color.vfWarningAmber.opacity(0.32)
        case .needsRelaunch:
            return Color.vfBrandAccent.opacity(0.38)
        }
    }
}

/// The primary per-row "Allow" pill that triggers the OS permission request.
private struct PermissionAllowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Allow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vfOnBrand)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, 7)
                .background(Color.vfBrandAccent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The granted indicator shown once a permission has been allowed.
private struct PermissionGrantedIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.vfSuccessGreen)
            Text("Allowed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfSuccessGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.vfSuccessGreen.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionPrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.vfSuccessGreen)
                .padding(.top, 1)

            (
                Text("Local first. ")
                    .fontWeight(.semibold)
                    .foregroundColor(Color.vfTextPrimary)
                + Text("Screen images are prepared on this Mac, and detected secrets are redacted by default.")
                    .foregroundColor(Color.vfTextSecondary)
            )
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, 11)
        .background(
            Color.vfSuccessGreen.opacity(0.055),
            in: RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(Color.vfSuccessGreen.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Right-aligned vertical stack for the two-button denied / needs-relaunch
/// trailing controls.
private struct PermissionActionStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            content()
        }
    }
}

/// Compact trailing button used by the denied / needs-relaunch sub-states.
/// `prominent` styles the primary action (Open Settings / Relaunch) with the
/// brand fill; the secondary "Check again" uses the muted fill.
private struct PermissionMiniButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.vfOnBrand : Color.vfTextPrimary)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    prominent ? Color.vfBrandAccent : Color.white.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dev Mode (educational)

/// Purely informational step shown to every user just before All Set.
/// Introduces Dev Mode at "what it is + where the switch is" depth — it does
/// NOT cover agent-CLI install or folder setup (those live in the selector's
/// dev-settings menu and Settings). No gating: shown to all users.
struct DevModeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepLayout {
            DevModeGlyphTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Building software? Try Dev Mode")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Normally Zerro copies a ready-to-paste result (a prompt, draft, snippet, or doc) to your clipboard. Flip the green </> Dev switch in the selector toolbar and Zerro instead hands your narrated recording to a local coding agent, like Claude Code, that edits the files in your project for you.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            VStack(spacing: VFSpacing.sm) {
                DevModeToolbarIllustration()

                Text("Look for it on the left of the toolbar after you select a region.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            OnboardingPrimaryButton("Continue") { onboarding.advance() }
        }
    }
}

/// Small icon tile echoing the real Dev switch: the `</>` glyph in the same
/// green (`vfDevAccent`) the toolbar segment shows when active.
private struct DevModeGlyphTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
            .fill(Color.vfDevAccent.opacity(0.14))
            .frame(width: 64, height: 64)
            .overlay(
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.vfDevAccent)
            )
    }
}

// MARK: - Dev Mode toolbar illustration

/// A static, non-interactive picture of the selector toolbar with the Dev mode
/// switch turned ON — so the onboarding step shows users exactly what to look
/// for and where. Mirrors `AreaSelectorView.modeSegment` styling (same SF
/// Symbols + `vfDevAccent`) but is fully self-contained: no `AreaSelectorState`,
/// no geometry/hit-testing, no animation. Hand-kept mock — if the real mode
/// switch is restyled, update this to match.
private struct DevModeToolbarIllustration: View {
    var body: some View {
        miniToolbar
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The selector toolbar, with the Dev mode switch turned on at its left end.")
    }

    private var miniToolbar: some View {
        HStack(spacing: VFSpacing.sm) {
            modeSwitch
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 18)
            ghostChip(system: "slider.horizontal.3")   // model (representative)
            ghostChip(system: "mic.fill")               // mic
            recordPill                                  // record affordance
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    /// Two-segment mode switch in a recessed well: Ask (dimmed, inactive) |
    /// Dev (active, green). A soft green ring rings the well to pull the eye.
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment(system: "wand.and.stars", active: false, isDev: false)
            segment(system: "chevron.left.forwardslash.chevron.right", active: true, isDev: true)
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.vfDevAccent.opacity(0.55), lineWidth: 1.5)
        )
    }

    private func segment(system: String, active: Bool, isDev: Bool) -> some View {
        let fill: Color = active
            ? (isDev ? Color.vfDevAccent.opacity(0.22) : Color.white.opacity(0.12))
            : .clear
        let iconColor: Color = active
            ? (isDev ? Color.vfDevAccent : Color.vfTextPrimary)
            : Color.vfTextTertiary
        return Image(systemName: system)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 30, height: 26)
            .background(Circle().fill(fill))
    }

    private func ghostChip(system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextTertiary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                    .fill(Color.vfControlBackground)
            )
    }

    /// The trailing Record pill — a fully-rounded `vfRecordingRed` capsule with
    /// a white dot + white label, matching `AreaSelectorView.recordPill`.
    private var recordPill: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.white).frame(width: 9, height: 9)
            Text("Record")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, VFSpacing.sm)
        .frame(height: 26)
        .background(Capsule(style: .continuous).fill(Color.vfRecordingRed))
    }
}

// MARK: - All Set

enum OnboardingReadyCopy {
    static func trialMessage(
        for path: OnboardingPath,
        managedCreditsLimit: Int?,
        managedCreditsRemaining: Int?
    ) -> String? {
        switch path {
        case .byok:
            return "Your \(BYOKTrialManager.generationLimit)-generation trial is ready."
        case .free:
            guard let credits = managedCreditsLimit ?? managedCreditsRemaining,
                  credits > 0 else {
                return nil
            }
            return "Your \(credits) free credits are ready."
        }
    }
}

struct AllSetStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(TrialCreditsManager.self) private var trialCredits
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingStepLayout(spacing: VFSpacing.xxl) {
            OnboardingSuccessBadge()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("You\u{2019}re ready.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                if let trialReadyMessage {
                    Text(trialReadyMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.vfSuccessGreen)
                        .multilineTextAlignment(.center)
                }

                Text("Open Zerro\u{2019}s overlay and we\u{2019}ll guide you through your first capture. After that, use the shortcut anytime you want to show, speak, and get a result.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            VStack(spacing: VFSpacing.sm) {
                HStack(spacing: VFSpacing.sm) {
                    OnboardingKeyCapLarge(label: "\u{2325}")
                    Text("+")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.vfTextTertiary)
                    OnboardingKeyCapLarge(label: "Space")
                }

                Text("Your Zerro shortcut, anytime")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextTertiary)
            }
        } actions: {
            OnboardingPrimaryButton("Try Zerro now", systemImage: "arrow.right") {
                OnboardingCompletionHandoff.perform(
                    complete: { onboarding.completeOnboarding() },
                    dismiss: { dismissWindow(id: OnboardingScene.windowID) },
                    openOverlay: { AppDelegate.openAreaSelector() }
                )
            }
            .frame(maxWidth: 360)
        }
    }

    private var trialReadyMessage: String? {
        OnboardingReadyCopy.trialMessage(
            for: onboarding.onboardingPath,
            managedCreditsLimit: trialCredits.creditsLimit,
            managedCreditsRemaining: trialCredits.creditsRemaining
        )
    }
}

private struct OnboardingSuccessBadge: View {
    var body: some View {
        Circle()
            .fill(Color.vfSuccessGreen.opacity(0.14))
            .frame(width: 58, height: 58)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.vfSuccessGreen)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.vfSuccessGreen.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.vfSuccessGreen.opacity(0.12), radius: 21)
            .accessibilityHidden(true)
    }
}

// MARK: - Shared layout

/// Vertically-centered step layout: optional icon header, content block,
/// and an actions block at the bottom. The three slots are stacked with
/// generous spacing and flanked by flexible spacers so each step sits
/// centered in the card regardless of how tall its content is.
struct OnboardingStepLayout<Icon: View, Content: View, Accessory: View, Actions: View>: View {
    let spacing: CGFloat
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var actions: () -> Actions

    init(
        spacing: CGFloat = VFSpacing.xl,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.spacing = spacing
        self.icon = icon
        self.content = content
        self.accessory = accessory
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: spacing) {
            Spacer(minLength: 0)

            icon()

            content()
                .padding(.horizontal, VFSpacing.xxl)

            accessory()
                .padding(.horizontal, VFSpacing.xxl)

            VStack(spacing: VFSpacing.sm) {
                actions()
            }
            .padding(.horizontal, VFSpacing.xxl)

            Spacer(minLength: 0)
        }
    }
}

/// Centered title + body text block shared by the icon-less steps.
struct OnboardingHeadline: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(spacing: VFSpacing.md) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.vfTextPrimary)
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(.system(size: 14))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared shell (icon-less title/body/actions step)

struct OnboardingStepShell<Actions: View>: View {
    let title: String
    let bodyText: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        OnboardingStepLayout {
            EmptyView()
        } content: {
            OnboardingHeadline(title: title, bodyText: bodyText)
        } actions: {
            actions()
        }
    }
}

// MARK: - Icon tiles

/// Large black rounded-square tile carrying the white-tinted brand glyph.
/// Used as the brand hero icon on onboarding-adjacent setup surfaces.
struct OnboardingLogoTile: View {
    var size: CGFloat = 80

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.vfOnBrand)
            .frame(width: size, height: size)
            .overlay(
                Image("MenuBarLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Dark elevated tile carrying an SF Symbol — used for the API-key step.
struct OnboardingIconTile: View {
    let systemName: String
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.vfCardBackground)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 1)
            )
    }
}

/// Large keycap used for the ⌥Space hint on the All Set step.
struct OnboardingKeyCapLarge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.vfTextPrimary)
            .padding(.horizontal, 14)
            .frame(minWidth: 48, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .fill(Color.vfControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 1)
            )
    }
}

// MARK: - Granted sub-state

/// Shared granted-state UI used by all three permission steps.
///
/// When `autoAdvance` is true, shows the "Continuing\u{2026}" copy and
/// fires `onContinue` after a short delay so the user perceives the
/// success state before the flow moves on. When false (dev pin active),
/// shows a manual Continue button instead so the state can be inspected
/// without vanishing.
struct OnboardingGrantedView: View {
    let title: String
    let autoAdvance: Bool
    let onContinue: () -> Void

    /// Delay before auto-advancing. Long enough to register the
    /// success affordance, short enough that nobody waits on it.
    private static let autoAdvanceDelay: Duration = .milliseconds(900)

    var body: some View {
        VStack(spacing: VFSpacing.xl) {
            Spacer(minLength: 0)

            HaloBadge(color: .vfSuccessGreen, systemName: "checkmark")

            VStack(spacing: VFSpacing.xs) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                if autoAdvance {
                    Text("Continuing\u{2026}")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextSecondary)
                }
            }

            if !autoAdvance {
                OnboardingPrimaryButton("Continue") { onContinue() }
                    .padding(.horizontal, VFSpacing.xxl)
            }

            Spacer(minLength: 0)
        }
        .task {
            guard autoAdvance else { return }
            try? await Task.sleep(for: Self.autoAdvanceDelay)
            // If the view is still mounted after the sleep, advance.
            // `.task` is cancelled on disappear or on `id`-change, so
            // a cancelled sleep simply throws and we skip onContinue.
            guard !Task.isCancelled else { return }
            onContinue()
        }
    }
}

// MARK: - Denied sub-state

/// Shared denied-state UI used by both permission steps (Screen / Mic),
/// where the only path forward is to enable in System Settings. The
/// `secondary` action offers a "Check again" re-probe.
struct OnboardingDeniedView: View {
    enum SecondaryAction {
        case checkAgain(() -> Void)

        var label: String {
            switch self {
            case .checkAgain: return "Check again"
            }
        }

        func invoke() {
            switch self {
            case .checkAgain(let action):
                action()
            }
        }
    }

    let title: String
    let description: String
    let breadcrumbLabel: String
    let settingsURL: URL
    let secondary: SecondaryAction

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            Spacer(minLength: 0)

            HaloBadge(color: .vfWarningAmber, systemName: "exclamationmark.triangle.fill")

            VStack(spacing: VFSpacing.md) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VFSpacing.xxl)

            settingsRow
                .padding(.horizontal, VFSpacing.xxl)

            VStack(spacing: VFSpacing.sm) {
                OnboardingPrimaryButton("Open System Settings") {
                    NSWorkspace.shared.open(settingsURL)
                }
                OnboardingSecondaryButton(secondary.label) { secondary.invoke() }
            }
            .padding(.horizontal, VFSpacing.xxl)

            Spacer(minLength: 0)
        }
    }

    /// Mirrors the row the user is looking for in System Settings: a
    /// gear tile, the permission name, and the toggle they need to flip on.
    private var settingsRow: some View {
        HStack(spacing: VFSpacing.md) {
            RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextSecondary)
                )

            Text(breadcrumbLabel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)

            Spacer(minLength: 0)

            // Static "on" toggle — illustrates the target state.
            Capsule()
                .fill(Color.vfSuccessGreen)
                .frame(width: 40, height: 24)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .padding(2),
                    alignment: .trailing
                )
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, VFSpacing.md)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: VFRadius.md))
    }
}

// MARK: - Needs-relaunch sub-state (M1)

/// Shown when Screen Recording reads as granted at the OS level but a live
/// capture probe still fails — the user enabled the toggle in System
/// Settings while Zerro was running, and the process needs a relaunch to
/// pick it up. Distinct from the denied view: the user has ALREADY granted,
/// so the only thing left is to restart the app. The primary action quits
/// and relaunches; "Check again" re-probes in case the grant went live
/// some other way (e.g. the user already relaunched manually).
struct OnboardingRelaunchView: View {
    let title: String
    let description: String
    let onRelaunch: () -> Void
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            Spacer(minLength: 0)

            HaloBadge(color: .vfBrandAccent, systemName: "arrow.clockwise")

            VStack(spacing: VFSpacing.md) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VFSpacing.xxl)

            VStack(spacing: VFSpacing.sm) {
                OnboardingPrimaryButton("Relaunch Zerro") { onRelaunch() }
                OnboardingSecondaryButton("Check again") { onCheckAgain() }
            }
            .padding(.horizontal, VFSpacing.xxl)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Halo badge

/// A solid status circle wrapped in a translucent halo ring, used by the
/// granted/denied states.
struct HaloBadge: View {
    let color: Color
    let systemName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 96, height: 96)
            Circle()
                .fill(color)
                .frame(width: 64, height: 64)
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Buttons

struct OnboardingPrimaryButton: View {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let tint: Color
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        tint: Color = .vfBrandAccent,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.vfOnBrand : Color.white.opacity(0.50))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                (isEnabled ? tint : Color.white.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: VFRadius.lg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                    .strokeBorder(
                        isEnabled ? Color.clear : Color.white.opacity(0.09),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.vfTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: VFRadius.lg))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG

// MARK: - Canvas previews

#Preview("1 · Welcome") {
    OnboardingPreviewHost(step: .welcome) {
        WelcomeStepView()
    }
}

#Preview("2 · Terms & Privacy") {
    OnboardingPreviewHost(step: .consent) {
        ConsentStepView()
    }
}

#Preview("3 · Email") {
    OnboardingPreviewHost(step: .email) {
        EmailStepView()
    }
}

#Preview("4 · Permissions · Request") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .notDetermined,
        microphoneStatus: .notDetermined
    ) {
        PermissionsStepView(previewContinueGate: false)
    }
}

#Preview("4 · Permissions · Denied") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .denied,
        microphoneStatus: .granted
    ) {
        PermissionsStepView(previewContinueGate: false)
    }
}

#Preview("4 · Permissions · Allowed") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .granted,
        microphoneStatus: .granted
    ) {
        PermissionsStepView(previewContinueGate: true)
    }
}

#Preview("4 · Permissions · Relaunch") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .granted,
        microphoneStatus: .granted
    ) {
        PermissionsStepView(
            previewContinueGate: false,
            previewScreenNeedsRelaunch: true
        )
    }
}

#Preview("Legacy · Dev Mode") {
    OnboardingPreviewHost(step: .devMode) {
        DevModeStepView()
    }
}

#Preview("Complete") {
    OnboardingPreviewHost(step: .allSet, path: .byok) {
        AllSetStepView()
    }
}

#endif
