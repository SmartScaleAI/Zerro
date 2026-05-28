//
//  OnboardingSteps.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  The six step views. Permission steps (Screen / Mic / Accessibility)
//  branch on a tri-state sub-state derived from PermissionsManager,
//  with a DEBUG-only override pin on OnboardingState so the dev panel
//  can preview any sub-state without toggling system permissions.
//
//  Sub-state semantics:
//    • Screen / Mic — blocking. Continue in BEFORE triggers the OS
//      request; GRANTED shows a manual Continue (auto-advance lands
//      in Checkpoint 4); DENIED offers System Settings + Check again.
//    • Accessibility — informational/optional. Continue in BEFORE just
//      advances (no AX request API exists); DENIED offers System
//      Settings + "Continue anyway" to skip.
//

import AppKit
import SwiftUI

// MARK: - Welcome

struct WelcomeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepShell(
            title: "Welcome to VisualFlow AI",
            bodyText: "Record your screen, narrate what you want, and get a ready-to-paste prompt for Cursor, Windsurf, or v0.\n\nWe\u{2019}ll set up a few things \u{2014} takes about a minute."
        ) {
            OnboardingPrimaryButton("Get Started") { onboarding.advance() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.vfTextSecondary)
                .padding(.top, 4)
        }
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
                title: "Screen Recording",
                bodyText: "VisualFlow needs to see your screen to capture what you\u{2019}re showing."
            ) {
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
                secondary: .checkAgain { permissions.refreshStatuses() }
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

// MARK: - Accessibility

struct AccessibilityStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions

    private var effectiveStatus: PermissionStatus {
        onboarding.pinnedAccessSubState ?? permissions.accessibilityStatus
    }

    private var autoAdvanceFromGranted: Bool {
        onboarding.pinnedAccessSubState == nil
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
            // Accessibility has no "request" API; Continue here just
            // advances, since the permission is optional and the user
            // can grant it later in System Settings on their own.
            OnboardingStepShell(
                title: "Accessibility",
                bodyText: "So you can trigger VisualFlow with \u{2318}\u{21E7}R from anywhere, without switching apps."
            ) {
                OnboardingPrimaryButton("Continue") { onboarding.advance() }
            }
        case .granted:
            OnboardingGrantedView(
                title: "Accessibility enabled \u{2014} you\u{2019}re good to go",
                autoAdvance: autoAdvanceFromGranted,
                onContinue: { onboarding.advance() }
            )
        case .denied:
            // Optional tone: the user can skip without enabling.
            OnboardingDeniedView(
                title: "Accessibility is off",
                description: "Optional \u{2014} you can enable it later in Settings if you ever need it.",
                breadcrumbLabel: "Accessibility",
                settingsURL: SystemSettingsURLs.accessibility,
                secondary: .continueAnyway { onboarding.advance() }
            )
        }
    }
}

// MARK: - API Key validation state

enum APIKeyValidationState: Equatable {
    case untouched
    case valid
    case invalid
}

// MARK: - API Key

struct APIKeyStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    @State private var apiKey: String = ""
    @State private var liveValidationState: APIKeyValidationState = .untouched

    /// Same singleton the Settings field uses — single Keychain path per
    /// the Phase 5 spec. No APIKeyStore wrapper needed; this constant
    /// already IS the shared path.
    private let keychain = KeychainStore.openAIAPIKey

    private var effectiveState: APIKeyValidationState {
        onboarding.pinnedAPIKeySubState ?? liveValidationState
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            Spacer(minLength: 0)

            VStack(spacing: VFSpacing.sm) {
                Text("Your API Key")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)
                Text("VisualFlow processes locally and uses your own API key. Your key is stored in macOS Keychain \u{2014} never transmitted to our servers.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VFSpacing.xxl)

            keyField
                .padding(.horizontal, VFSpacing.xxl)

            actionRow
                .padding(.horizontal, VFSpacing.xxl)

            helpLink

            Spacer(minLength: 0)
        }
        .onAppear(perform: loadFromKeychain)
    }

    // MARK: - Subviews

    private var keyField: some View {
        VStack(alignment: .leading, spacing: VFSpacing.xs) {
            HStack(spacing: VFSpacing.sm) {
                SecureField("sk-\u{2026}", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .padding(.horizontal, VFSpacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: borderWidth)
                    )
                    .onChange(of: apiKey) { _, _ in
                        // Editing a previously-validated key demotes the
                        // state back to untouched so the user has to
                        // re-verify before continuing. Skipped while a
                        // dev pin is forcing the rendered state.
                        guard onboarding.pinnedAPIKeySubState == nil else { return }
                        if liveValidationState != .untouched { liveValidationState = .untouched }
                    }

                statusIcon
                    .frame(width: 18)
            }

            if effectiveState == .invalid {
                Text("Doesn\u{2019}t look right \u{2014} keys start with \u{201C}sk-\u{201D}.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfRecordingRed)
            } else if effectiveState == .valid {
                Text("Key verified. Stored in Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfSuccessGreen)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch effectiveState {
        case .untouched, .invalid:
            OnboardingPrimaryButton("Verify") { verify() }
        case .valid:
            OnboardingPrimaryButton("Continue") { onboarding.advance() }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch effectiveState {
        case .untouched:
            EmptyView()
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.vfSuccessGreen)
        case .invalid:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.vfRecordingRed)
        }
    }

    private var helpLink: some View {
        Button {
            if let url = URL(string: "https://platform.openai.com/api-keys") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text("Where do I get a key?")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .underline()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behavior

    private func loadFromKeychain() {
        guard let stored = keychain.read(), !stored.isEmpty else { return }
        apiKey = stored
        // Pre-filled key is treated as validated per the spec —
        // "if a key is already present when onboarding runs, pre-fill
        // the masked field and mark it validated."
        liveValidationState = .valid
    }

    private func verify() {
        // DEFERRED: replace synchronous prefix check with real provider
        // validation (async network call). When real validation lands,
        // this introduces a loading state and the user learns the
        // genuine async rhythm rather than a fake spinner.
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidPrefix(trimmed) {
            keychain.write(trimmed)
            liveValidationState = .valid
        } else {
            liveValidationState = .invalid
        }
    }

    private func isValidPrefix(_ key: String) -> Bool {
        // Both OpenAI (`sk-...`) and Anthropic (`sk-ant-...`) keys start
        // with `sk-`. Loose check by design — real validation is
        // deferred to actual provider pings in a later phase.
        !key.isEmpty && key.hasPrefix("sk-")
    }

    // MARK: - Field styling

    private var borderColor: Color {
        switch effectiveState {
        case .untouched: return Color.white.opacity(0.10)
        case .valid:     return Color.vfSuccessGreen.opacity(0.7)
        case .invalid:   return Color.vfRecordingRed.opacity(0.8)
        }
    }

    private var borderWidth: CGFloat {
        effectiveState == .untouched ? 1 : 1.5
    }
}

// MARK: - All Set

struct AllSetStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingStepShell(
            title: "You\u{2019}re all set.",
            bodyText: "Hit \u{2318}\u{21E7}R, select a region, narrate what you want, and we\u{2019}ll do the rest."
        ) {
            OnboardingPrimaryButton("Done") {
                onboarding.completeOnboarding()
                dismissWindow(id: OnboardingScene.windowID)
            }
        }
    }
}

// MARK: - Shared shell

struct OnboardingStepShell<Actions: View>: View {
    let title: String
    let bodyText: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            Spacer(minLength: 0)

            VStack(spacing: VFSpacing.sm) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)
                Text(bodyText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VFSpacing.xxl)

            VStack(spacing: VFSpacing.sm) {
                actions()
            }
            .padding(.horizontal, VFSpacing.xxl)

            Spacer(minLength: 0)
        }
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
        VStack(spacing: VFSpacing.lg) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Color.vfSuccessGreen)
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: VFSpacing.xs) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                if autoAdvance {
                    Text("Continuing\u{2026}")
                        .font(.system(size: 13))
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

/// Shared denied-state UI used by all three permission steps. The
/// `secondary` action distinguishes blocking-tone (Screen / Mic, where
/// the only path forward is to enable in System Settings) from
/// optional-tone (Accessibility, where the user can skip).
struct OnboardingDeniedView: View {
    enum SecondaryAction {
        case checkAgain(() -> Void)
        case continueAnyway(() -> Void)

        var label: String {
            switch self {
            case .checkAgain:     return "Check again"
            case .continueAnyway: return "Continue anyway"
            }
        }

        func invoke() {
            switch self {
            case .checkAgain(let action), .continueAnyway(let action):
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

            ZStack {
                Circle()
                    .fill(Color.vfWarningAmber)
                    .frame(width: 56, height: 56)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: VFSpacing.sm) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VFSpacing.xxl)

            breadcrumb
                .padding(.horizontal, VFSpacing.xxl)

            VStack(spacing: VFSpacing.sm) {
                OnboardingPrimaryButton("Open System Settings") {
                    NSWorkspace.shared.open(settingsURL)
                }
                Button(action: { secondary.invoke() }) {
                    Text(secondary.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.vfTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: VFRadius.lg))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, VFSpacing.xxl)

            Spacer(minLength: 0)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
            Text("System Settings")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
            Text("\u{203A}")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
            Text("Privacy & Security")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
            Text("\u{203A}")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
            Text(breadcrumbLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: VFRadius.md))
    }
}

// MARK: - Primary button

struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.vfBrandBlue, in: RoundedRectangle(cornerRadius: VFRadius.lg))
        }
        .buttonStyle(.plain)
    }
}
