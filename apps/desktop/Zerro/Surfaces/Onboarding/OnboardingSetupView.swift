//
//  OnboardingSetupView.swift
//  Zerro
//
//  Redesigned onboarding setup. Every user verifies an email first; the next
//  screen selects Zerro Cloud or Local + Own API Keys. The BYOK key screen is
//  therefore focused only on provider credentials.
//

import os
import SwiftUI

enum OnboardingSetupPolicy {
    enum LocalModelPreparationAction: Equatable {
        case finish
        case wait
        case download
    }

    static func emailLooksValid(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    static func canStartFree(email: String, agreed: Bool, isWorking: Bool) -> Bool {
        emailLooksValid(email) && agreed && !isWorking
    }

    static func canContinueBYOK(keys: [String], agreed: Bool, isWorking: Bool) -> Bool {
        agreed && !isWorking && keys.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func canContinueBYOK(keys: [String], isWorking: Bool) -> Bool {
        !isWorking && keys.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Local + Own Keys cannot finish setup until Whisper is actually ready.
    /// A stopped/failed download is explicitly retryable; an active download is
    /// observed in place instead of letting onboarding advance in the background.
    static func localModelPreparationAction(
        for state: LocalModelManager.State
    ) -> LocalModelPreparationAction {
        switch state {
        case .ready:
            return .finish
        case .downloading:
            return .wait
        case .notDownloaded, .failed:
            return .download
        }
    }
}

struct OnboardingSetupStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @State private var hasAgreed = false

    var body: some View {
        ManagedSetupView(hasAgreed: $hasAgreed)
        .onAppear {
            // A relaunch after accepting current terms should not ask the user
            // to accept the same version again.
            if !onboarding.needsConsent {
                hasAgreed = true
            }
        }
    }
}

// MARK: - Shared email verification

private struct ManagedSetupView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(TrialCreditsManager.self) private var trialCredits

    @Binding var hasAgreed: Bool

    @State private var model = TrialEmailModel(purpose: .onboardingContact)
    @State private var marketingEmailOptIn = false
    @State private var showNoCodeHelp = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, code }

    var body: some View {
        VStack(spacing: 24) {
            OnboardingBrandHero(description: heroDescription)

            VStack(spacing: 12) {
                if let terminal = model.terminalState {
                    terminalContent(terminal)
                } else {
                    switch model.step {
                    case .email: emailContent
                    case .code: codeContent
                    }
                }
            }
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if model.email.isEmpty, let remembered = trialCredits.rememberedEmail {
                model.email = remembered
            }
            focusedField = model.step == .email ? .email : .code
        }
        .onChange(of: model.step) { _, step in
            focusedField = step == .email ? .email : .code
        }
    }

    private var heroDescription: String {
        if let terminal = model.terminalState { return terminal.message }
        switch model.step {
        case .email:
            return "Record your screen, explain what you want, and get it done faster."
        case .code:
            return TrialEmailCopy.codeDelivery(to: model.trimmedEmail)
        }
    }

    private var emailContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                setupField(isFocused: focusedField == .email) {
                    TextField("you@example.com", text: $model.email)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.vfTextPrimary)
                        .focused($focusedField, equals: .email)
                        .disabled(model.isWorking)
                        .onChange(of: model.email) { _, _ in model.handleEdit() }
                        .onSubmit(startFreeTrial)
                }

                errorMessage
            }

            OnboardingSetupConsent(
                isAgreed: $hasAgreed,
                marketingEmailOptIn: $marketingEmailOptIn
            )
                .padding(.top, 22)

            OnboardingPrimaryButton(
                model.isWorking ? "Sending code\u{2026}" : "Continue with email",
                systemImage: model.isWorking ? nil : "arrow.right",
                isEnabled: OnboardingSetupPolicy.canStartFree(
                    email: model.email,
                    agreed: hasAgreed,
                    isWorking: model.isWorking
                ),
                action: startFreeTrial
            )
            .padding(.top, 20)

        }
    }

    private var codeContent: some View {
        VStack(spacing: 12) {
            setupField(isFocused: focusedField == .code) {
                TextField("123456", text: $model.code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .focused($focusedField, equals: .code)
                    .disabled(model.isWorking)
                    .onChange(of: model.code) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { model.code = digits }
                        model.handleEdit()
                    }
                    .onSubmit(verifyCode)
            }

            errorMessage

            OnboardingPrimaryButton(
                model.isWorking ? "Verifying\u{2026}" : "Verify and continue",
                systemImage: model.isWorking ? nil : "arrow.right",
                isEnabled: model.trimmedCode.count == 6 && !model.isWorking,
                action: verifyCode
            )

            HStack(spacing: 18) {
                Button("Use a different email") {
                    model.useDifferentEmail()
                    showNoCodeHelp = false
                }
                Button(showNoCodeHelp ? "Hide help" : "Didn\u{2019}t get a code?") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showNoCodeHelp.toggle()
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextSecondary)
            .disabled(model.isWorking)

            if showNoCodeHelp {
                noCodeHelp
            }

            if model.shouldOfferInfrastructureFallback {
                infrastructureFallback
            }
        }
    }

    private func terminalContent(_ terminal: TrialEmailTerminalState) -> some View {
        VStack(spacing: 12) {
            Text(terminal.headline)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)

            Text("Verify your email to choose how you want to use Zerro.")
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextSecondary)
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if case .failed(let message) = model.phase {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.vfRecordingRed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noCodeHelp: some View {
        VStack(spacing: 8) {
            Text("Check spam or wait a minute before trying again.")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)

            HStack(spacing: 18) {
                Button("Resend code", action: startFreeTrial)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextSecondary)
        }
        .padding(.top, 2)
    }

    private var infrastructureFallback: some View {
        VStack(spacing: 8) {
            Text("We\u{2019}re having trouble reaching our servers. Please try again in a moment.")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func setupField<Content: View>(
        isFocused: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            content()
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(
                    isFocused ? Color.zerroSetupBlue.opacity(0.8) : Color.white.opacity(0.11),
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .shadow(color: isFocused ? Color.zerroSetupBlue.opacity(0.14) : .clear, radius: 8)
    }

    private func startFreeTrial() {
        guard OnboardingSetupPolicy.canStartFree(
            email: model.email,
            agreed: hasAgreed,
            isWorking: model.isWorking
        ) else { return }

        acceptTermsAndRecordStart()
        model.sendCode(using: trialCredits)
    }

    private func verifyCode() {
        model.verify(
            using: trialCredits,
            marketingEmailOptIn: marketingEmailOptIn
        ) {
            Log.billing.notice("shared onboarding email verified")
            onboarding.showPathSelection()
        }
    }

    private func acceptTermsAndRecordStart() {
        if onboarding.needsConsent {
            onboarding.recordConsent()
        }
        onboarding.recordOnboardingStarted()
        onboarding.recordScreenViewed(.setup)
    }
}

// MARK: - Own keys

struct BYOKSetupView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(BYOKTrialManager.self) private var trial
    @Environment(ProviderKeyPresence.self) private var keyPresence
    @Environment(PreferencesStore.self) private var preferences
    @Environment(LocalModelManager.self) private var modelManager

    @State private var openAI = APIKeyFieldModel(provider: .openai)
    @State private var anthropic = APIKeyFieldModel(provider: .anthropic)
    @State private var gemini = APIKeyFieldModel(provider: .gemini)
    @State private var submissionPhase: SubmissionPhase = .idle
    @State private var eligibilityConfirmed = false
    @State private var keysValidated = false
    @State private var errorMessage: String?

    private enum SubmissionPhase: Equatable {
        case idle
        case eligibility
        case validating
        case preparingLocalModel
    }

    private var models: [APIKeyFieldModel] { [openAI, anthropic, gemini] }
    private var keys: [String] { models.map(\.trimmedKey) }
    private var validationStates: [APIKeyFieldModel.State] { models.map(\.state) }
    private var isWorking: Bool { submissionPhase != .idle }

    var body: some View {
        VStack(spacing: 20) {
            OnboardingSetupHero(
                systemName: "key.horizontal.fill",
                title: "Use your own API keys",
                description: "Connect one or more providers. Transcription runs locally on this Mac; AI generation uses your selected provider."
            )

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("API keys")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.vfTextPrimary)
                        Text("Add at least one, or connect all three. Stored securely in macOS Keychain.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.vfTextTertiary)
                    }

                    BYOKSetupKeyField(model: openAI, isDisabled: isWorking)
                    BYOKSetupKeyField(model: anthropic, isDisabled: isWorking)
                    BYOKSetupKeyField(model: gemini, isDisabled: isWorking)

                    localModelStatus

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.vfRecordingRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                OnboardingPrimaryButton(
                    submissionTitle,
                    systemImage: isWorking ? nil : "arrow.right",
                    isEnabled: OnboardingSetupPolicy.canContinueBYOK(
                        keys: keys,
                        isWorking: isWorking
                    ),
                    action: submit
                )
                .padding(.top, 20)

                Button("Back") {
                    trial.deselectIfUnstarted()
                    onboarding.returnToPathSelection()
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .disabled(isWorking)
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            wireModels()
            eligibilityConfirmed = trial.isSelected
        }
        .onChange(of: validationStates) { _, _ in
            finishValidationIfReady()
        }
        .onChange(of: modelManager.state) { _, state in
            finishLocalModelPreparationIfReady(state)
        }
    }

    private var submissionTitle: String {
        switch submissionPhase {
        case .idle: return keysValidated ? "Retry local model download" : "Continue"
        case .eligibility: return "Checking eligibility\u{2026}"
        case .validating: return "Checking keys\u{2026}"
        case .preparingLocalModel: return "Preparing local transcription\u{2026}"
        }
    }

    @ViewBuilder
    private var localModelStatus: some View {
        switch modelManager.state {
        case .ready:
            Label("Local transcription model is ready.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.vfSuccessGreen)
        case let .downloading(progress, downloaded, total):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Downloading the local transcription model", systemImage: "arrow.down.circle")
                    Spacer(minLength: 8)
                    Text("\(Self.megabytes(downloaded)) / \(Self.megabytes(total))")
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.zerroSetupBlue)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextSecondary)
        case .notDownloaded, .failed:
            Label(
                "Local transcription requires a one-time ~550 MB model download. Zerro installs it before setup finishes.",
                systemImage: "desktopcomputer"
            )
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wireModels() {
        let refresh = { [keyPresence] in keyPresence.refresh() }
        for model in models {
            model.onKeyStoreChanged = refresh
        }
        keyPresence.refresh()
    }

    private func submit() {
        if keysValidated {
            beginLocalModelPreparation()
            return
        }
        guard OnboardingSetupPolicy.canContinueBYOK(
            keys: keys,
            isWorking: isWorking
        ) else { return }

        errorMessage = nil
        if eligibilityConfirmed {
            beginValidation()
            return
        }

        submissionPhase = .eligibility
        Task { @MainActor in
            do {
                let eligibility = try await trial.checkEligibility()
                switch eligibility {
                case .eligible, .active:
                    eligibilityConfirmed = true
                    trial.select()
                    beginValidation()
                case .exhausted:
                    submissionPhase = .idle
                    errorMessage = "This Mac has already completed its own-key trial."
                }
            } catch let error as BYOKTrialError {
                submissionPhase = .idle
                errorMessage = error.userMessage
            } catch {
                submissionPhase = .idle
                errorMessage = BYOKTrialError.server.userMessage
            }
        }
    }

    private func beginValidation() {
        submissionPhase = .validating
        for model in models {
            model.saveAndValidate()
        }
        // Already-saved keys do not emit a state change, so evaluate once on
        // the next turn in addition to observing validation-state changes.
        DispatchQueue.main.async {
            finishValidationIfReady()
        }
    }

    private func finishValidationIfReady() {
        guard submissionPhase == .validating else { return }
        guard !models.contains(where: { $0.state == .checking }) else { return }

        let invalid = models.filter { !$0.trimmedKey.isEmpty && $0.state == .invalid }
        guard invalid.isEmpty else {
            submissionPhase = .idle
            errorMessage = invalid.count == 1
                ? "Check the highlighted \(invalid[0].provider.displayName) key and try again."
                : "Check the highlighted API keys and try again."
            return
        }

        keyPresence.refresh()
        guard !keyPresence.present.isEmpty else {
            submissionPhase = .idle
            errorMessage = "Add at least one API key to continue."
            return
        }

        keysValidated = true
        Analytics.captureOnce(
            "byok_trial_selected",
            key: "vf.analytics.byokTrialSelected",
            ["surface": "onboarding"]
        )
        preferences.sttEngine = .local
        Analytics.capture("stt_engine_changed", [
            "engine": STTEngine.local.rawValue,
            "surface": "onboarding",
        ])
        beginLocalModelPreparation()
    }

    private func beginLocalModelPreparation() {
        errorMessage = nil
        preferences.sttEngine = .local
        switch OnboardingSetupPolicy.localModelPreparationAction(for: modelManager.state) {
        case .finish:
            onboarding.finishSetup()
        case .wait:
            submissionPhase = .preparingLocalModel
        case .download:
            submissionPhase = .preparingLocalModel
            modelManager.download()
        }
    }

    private func finishLocalModelPreparationIfReady(_ state: LocalModelManager.State) {
        guard submissionPhase == .preparingLocalModel else { return }
        switch state {
        case .ready:
            onboarding.finishSetup()
        case .failed(let reason):
            submissionPhase = .idle
            errorMessage = "\(reason) Try the download again."
        case .notDownloaded:
            submissionPhase = .idle
            errorMessage = "The local transcription model download stopped. Try again."
        case .downloading:
            break
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private struct BYOKSetupKeyField: View {
    @Bindable var model: APIKeyFieldModel
    let isDisabled: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.provider.displayName) API key")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.vfTextPrimary)

            HStack(spacing: 10) {
                Image(model.provider.logoAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                SecureField("Paste your \(model.provider.displayName) API key", text: $model.rawKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .focused($isFocused)
                    .disabled(isDisabled)
                    .onChange(of: model.rawKey) { _, _ in model.handleEdit() }
                    .onSubmit(model.saveAndValidate)

                status
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
            .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
            )
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .verified:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.vfSuccessGreen)
        case .invalid:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.vfRecordingRed)
        case .unverified:
            EmptyView()
        }
    }

    private var borderColor: Color {
        if isFocused { return .zerroSetupBlue.opacity(0.8) }
        switch model.state {
        case .verified: return Color.vfSuccessGreen.opacity(0.45)
        case .invalid: return Color.vfRecordingRed.opacity(0.7)
        case .checking, .unverified: return Color.white.opacity(0.11)
        }
    }
}

// MARK: - Shared Setup components

private struct OnboardingBrandHero: View {
    let description: String

    var body: some View {
        VStack(spacing: 16) {
            OnboardingSetupMark {
                Image("MenuBarLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.vfTextPrimary)
            }

            VStack(spacing: 8) {
                Text("Talk to your screen.")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                Text("Zerro does the work.")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.zerroSetupBlue, .zerroSetupCyan, .zerroSetupGreen],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
        }
    }
}

struct OnboardingSetupHero: View {
    let systemName: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 14) {
            OnboardingSetupMark {
                Image(systemName: systemName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct OnboardingSetupMark<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.white.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 56, height: 56)
            .overlay(content())
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 16, y: 8)
    }
}

private struct OnboardingSetupConsent: View {
    @Binding var isAgreed: Bool
    private let marketingEmailOptIn: Binding<Bool>?
    @AppStorage(CrashReporting.isEnabledDefaultsKey)
    private var analyticsEnabled = OnboardingState.analyticsDefaultOptIn

    init(
        isAgreed: Binding<Bool>,
        marketingEmailOptIn: Binding<Bool>? = nil
    ) {
        _isAgreed = isAgreed
        self.marketingEmailOptIn = marketingEmailOptIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $isAgreed) {
                Text("I agree to Zerro\u{2019}s [Terms of Service](https://getzerro.app/terms) and [Privacy Policy](https://getzerro.app/privacy).")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .tint(Color.vfTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)

            Toggle(isOn: $analyticsEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share anonymous usage and crash data")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextSecondary)
                    Text("Never includes recordings, transcripts, prompts, or API keys.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextTertiary)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .onChange(of: analyticsEnabled) { _, enabled in
                Analytics.setEnabled(enabled)
            }

            if let marketingEmailOptIn {
                Toggle(isOn: marketingEmailOptIn) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Email me occasional Zerro updates")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.vfTextSecondary)
                        Text("Tips, feedback requests, product news, and offers. Unsubscribe anytime.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfTextTertiary)
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    static let zerroSetupBlue = Color(red: 0.55, green: 0.66, blue: 1.0)
    static let zerroSetupCyan = Color(red: 0.59, green: 0.79, blue: 0.83)
    static let zerroSetupGreen = Color(red: 0.56, green: 0.84, blue: 0.68)
}

#if DEBUG

#Preview("Setup · Managed") {
    OnboardingPreviewHost(step: .email) {
        OnboardingSetupStepView()
    }
}

#Preview("Setup · BYOK") {
    OnboardingPreviewHost(step: .email, path: .byok) {
        OnboardingSetupStepView()
    }
}

#endif
