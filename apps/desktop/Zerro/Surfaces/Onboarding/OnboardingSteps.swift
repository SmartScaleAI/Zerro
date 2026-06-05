//
//  OnboardingSteps.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  The five step views. Permission steps (Screen / Mic) branch on a
//  tri-state sub-state derived from PermissionsManager, with a
//  DEBUG-only override pin on OnboardingState so the dev panel can
//  preview any sub-state without toggling system permissions.
//
//  Sub-state semantics:
//    • Screen / Mic — blocking. Continue in BEFORE triggers the OS
//      request; GRANTED shows a manual Continue (auto-advance lands
//      in Checkpoint 4); DENIED offers System Settings + Check again.
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
                    (
                        Text("Record your screen, narrate what you want, and get a ready-to-paste prompt for ")
                        + Text("your agent").fontWeight(.semibold).foregroundColor(.vfTextPrimary)
                        + Text(".")
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("We\u{2019}ll set up a few things \u{2014} takes about a minute.")
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

/// The required email-verification step (right after Welcome). Every new user
/// verifies an email here; on success the server-funded trial credits are
/// granted (via `TrialCreditsManager` / `trial-start`) so the trial works
/// afterward with no mid-task interruption. There is NO user-facing skip —
/// verification is required to advance.
///
/// Infra-failure resilience (NOT a skip): if the backend/email service is
/// genuinely unreachable (network / 5xx / Resend failure) and keeps failing,
/// the user is allowed to proceed into the app WITHOUT granted credits, with a
/// persistent "verify in Settings" affordance to finish later. This path is
/// reached only on repeated SYSTEM failure — never by user choice, and never via
/// a visible "Skip" control. A wrong code / unverified user simply stays here.
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
    /// The email's trial is already spent (exhausted grant) — there are no
    /// credits to grant, but the user may still continue (it's not an error).
    @State private var alreadyUsed: Bool = false
    @State private var errorMessage: String?
    /// True when the last error was an infrastructure failure (network/5xx/send)
    /// rather than user error (wrong code, etc.) — only these unlock the
    /// infra fallback and surface "Resend code".
    @State private var errorIsSystem: Bool = false
    @State private var systemFailureCount: Int = 0
    @FocusState private var fieldFocused: Bool

    /// After this many CONSECUTIVE system-class failures, offer the infra
    /// fallback so a backend/Resend outage can never permanently trap the user.
    private static let maxSystemFailuresBeforeFallback = 2

    private var showInfraFallback: Bool { systemFailureCount >= Self.maxSystemFailuresBeforeFallback }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailLooksValid: Bool { trimmedEmail.contains("@") && trimmedEmail.contains(".") }

    var body: some View {
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
                if !verified && !alreadyUsed {
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
        if alreadyUsed { return "Welcome back" }
        return step == .email ? "Verify your email" : "Enter your code"
    }

    private var subhead: String {
        if verified {
            return "Your free trial is ready \u{2014} you\u{2019}re good to go."
        }
        if alreadyUsed {
            return "This email has already used its free trial. You can continue \u{2014} add your own OpenAI key or subscribe anytime."
        }
        switch step {
        case .email:
            return "Verify your email to start your free trial \u{2014} no credit card, no API key. We\u{2019}ll send a 6-digit code."
        case .code:
            return "We sent a 6-digit code to \(trimmedEmail). Enter it below to finish."
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
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if verified || alreadyUsed {
            // The ONLY way to advance is after verification (or a genuinely
            // already-used email). No skip exists for an unverified user.
            OnboardingPrimaryButton("Continue", systemImage: "arrow.right") { onboarding.advance() }
        } else {
            switch step {
            case .email:
                if working {
                    OnboardingPrimaryButton("Sending\u{2026}", isEnabled: false) { }
                } else {
                    OnboardingPrimaryButton("Send code", isEnabled: emailLooksValid) { sendCode() }
                }
            case .code:
                if working {
                    OnboardingPrimaryButton("Verifying\u{2026}", isEnabled: false) { }
                } else {
                    OnboardingPrimaryButton("Verify", isEnabled: trimmedCode.count == 6) { verify() }
                }
                Button("Resend code", action: sendCode)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .disabled(working)
                    .padding(.top, 2)
                Button("Use a different email") {
                    step = .email
                    code = ""
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
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
                fieldFocused = true
            } catch let error as TrialStartError {
                handle(error)
            } catch {
                handleSystem("Couldn\u{2019}t send the code \u{2014} please try again.", error)
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
                handleSystem("Couldn\u{2019}t verify the code \u{2014} please try again.", error)
            }
        }
    }

    /// Map a typed `TrialStartError`, distinguishing USER state (stay on the
    /// step) from SYSTEM/infra failure (counts toward the fallback).
    private func handle(_ error: TrialStartError) {
        switch error {
        case .alreadyUsed:
            // Not an error — the email's trial is spent. Let them continue.
            alreadyUsed = true
            errorMessage = nil
        case .network, .server, .sendFailed, .malformedResponse, .malformedRequest:
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
}

// MARK: - Screen Recording

struct ScreenRecordingStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions

    private var effectiveStatus: PermissionStatus {
        onboarding.pinnedScreenSubState ?? permissions.screenRecordingStatus
    }

    /// Auto-advance only when the granted state is the live OS value;
    /// a dev pin suppresses the timer so the state can be inspected.
    private var autoAdvanceFromGranted: Bool {
        onboarding.pinnedScreenSubState == nil
    }

    /// M1: show the dedicated "needs relaunch" sub-view when the grant is
    /// present in System Settings but a live capture probe failed in this
    /// process. Takes priority over the tri-state so the user is never
    /// stranded on a "denied" screen that contradicts their toggle (in a
    /// stuck Release build CGPreflight may even read `.granted` and the
    /// step would otherwise auto-advance into a recording that can't
    /// capture). Suppressed while a dev pin is active so the panel can
    /// still inspect the three base sub-states.
    private var showsNeedsRelaunch: Bool {
        onboarding.pinnedScreenSubState == nil && permissions.screenRecordingNeedsRelaunch
    }

    var body: some View {
        content
            .task(id: effectiveStatus) { permissions.managePolling(for: effectiveStatus) }
            .onDisappear { permissions.stopPolling() }
    }

    @ViewBuilder
    private var content: some View {
        if showsNeedsRelaunch {
            OnboardingRelaunchView(
                title: "Almost there",
                description: "Screen Recording is enabled but needs a relaunch to take effect.",
                onRelaunch: { permissions.relaunchToApplyScreenRecording() },
                onCheckAgain: { Task { await permissions.probeScreenRecordingEffectiveness() } }
            )
        } else {
            screenStatusContent
        }
    }

    @ViewBuilder
    private var screenStatusContent: some View {
        switch effectiveStatus {
        case .notDetermined:
            OnboardingStepLayout {
                EmptyView()
            } content: {
                OnboardingHeadline(
                    title: "Screen Recording",
                    bodyText: "Zerro needs to see your screen to capture what you\u{2019}re showing."
                )
            } accessory: {
                RecordingPillDemo()
            } actions: {
                OnboardingPrimaryButton("Continue") {
                    permissions.requestScreenRecording()
                }
            }
        case .granted:
            OnboardingGrantedView(
                title: "Screen Recording allowed",
                autoAdvance: autoAdvanceFromGranted,
                onContinue: { onboarding.advance() }
            )
        case .denied:
            OnboardingDeniedView(
                title: "Screen Recording was denied",
                description: "macOS won\u{2019}t re-prompt \u{2014} you need to enable it manually.",
                breadcrumbLabel: "Screen Recording",
                settingsURL: SystemSettingsURLs.screenRecording,
                // M1: "Check Again" is a decision point, so it runs the
                // SCShareableContent effectiveness probe. Three outcomes:
                // a live grant advances to .granted; a grant that's present
                // in Settings but not yet live in this process flips to the
                // "needs relaunch" sub-view (instead of stranding the user
                // here); still-missing stays denied. Stays silent when the
                // grant is live; may spawn one popup if permission is still
                // actually missing — acceptable for a user-initiated action.
                secondary: .checkAgain {
                    Task { await permissions.probeScreenRecordingEffectiveness() }
                }
            )
        }
    }
}

// MARK: - Microphone

struct MicrophoneStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions

    private var effectiveStatus: PermissionStatus {
        onboarding.pinnedMicSubState ?? permissions.microphoneStatus
    }

    private var autoAdvanceFromGranted: Bool {
        onboarding.pinnedMicSubState == nil
    }

    var body: some View {
        content
            .task(id: effectiveStatus) { permissions.managePolling(for: effectiveStatus) }
            .onDisappear { permissions.stopPolling() }
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveStatus {
        case .notDetermined:
            OnboardingStepShell(
                title: "Microphone",
                bodyText: "We capture your narration so the AI knows what you\u{2019}re saying about what\u{2019}s on screen."
            ) {
                OnboardingPrimaryButton("Continue") {
                    Task { await permissions.requestMicrophone() }
                }
            }
        case .granted:
            OnboardingGrantedView(
                title: "Microphone allowed",
                autoAdvance: autoAdvanceFromGranted,
                onContinue: { onboarding.advance() }
            )
        case .denied:
            OnboardingDeniedView(
                title: "Microphone was denied",
                description: "macOS won\u{2019}t re-prompt \u{2014} you need to enable it manually.",
                breadcrumbLabel: "Microphone",
                settingsURL: SystemSettingsURLs.microphone,
                secondary: .checkAgain { permissions.refreshStatuses() }
            )
        }
    }
}

// MARK: - All Set

struct AllSetStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.lg) {
                Text("You\u{2019}re all set.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                HStack(spacing: VFSpacing.sm) {
                    OnboardingKeyCapLarge(label: "\u{2318}")
                    Text("+").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.vfTextTertiary)
                    OnboardingKeyCapLarge(label: "\u{21E7}")
                    Text("+").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.vfTextTertiary)
                    OnboardingKeyCapLarge(label: "R")
                }

                Text("Hit \u{2318}\u{21E7}R, select a region, narrate what you want, and we\u{2019}ll do the rest.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            OnboardingPrimaryButton("Done") {
                onboarding.completeOnboarding()
                dismissWindow(id: OnboardingScene.windowID)
            }
        }
    }
}

// MARK: - Shared layout

/// Vertically-centered step layout: optional icon header, content block,
/// and an actions block at the bottom. The three slots are stacked with
/// generous spacing and flanked by flexible spacers so each step sits
/// centered in the card regardless of how tall its content is.
struct OnboardingStepLayout<Icon: View, Content: View, Accessory: View, Actions: View>: View {
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var actions: () -> Actions

    init(
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.icon = icon
        self.content = content
        self.accessory = accessory
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: VFSpacing.xl) {
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
/// Used as the hero icon on Welcome and All Set.
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
            .fill(Color.white.opacity(0.06))
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

/// Large keycap used for the ⌘⇧R hint on the All Set step.
struct OnboardingKeyCapLarge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.vfTextPrimary)
            .frame(width: 48, height: 48)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 1)
            )
    }
}

// MARK: - Recording pill demo

/// Static, non-interactive preview of the recording pill, shown on the
/// Screen Recording step so the user knows what to expect once granted.
struct RecordingPillDemo: View {
    var body: some View {
        HStack(spacing: VFSpacing.md) {
            HStack(spacing: 6) {
                PulsingDot(color: .vfRecordingRed, size: 8)
                Text("0:14")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            WaveformView(
                bars: WaveformView.sampleBarsShort,
                color: Color.vfTextSecondary,
                barWidth: 2.5,
                spacing: 2,
                maxHeight: 16
            )

            Text("Cancel")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)

            Text("Stop")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfOnBrand)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.vfBrandAccent, in: Capsule())
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, VFSpacing.sm)
        .background(Color.vfPillBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 1))
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
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: VFRadius.md))
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
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
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
            .foregroundStyle(isEnabled ? Color.vfOnBrand : Color.vfTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                (isEnabled ? Color.vfBrandAccent : Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: VFRadius.lg)
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
