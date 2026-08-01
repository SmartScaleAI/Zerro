//
//  BYOKOnboardingFlow.swift
//  Zerro
//
//  Legacy nested own-key renderer retained only for persisted-route migration
//  and debug previews. The production flow now uses OnboardingSetupView and
//  always configures BYOK with local transcription.
//

import SwiftUI

private enum BYOKSetupStep: Int {
    case intro
    case keys
    case transcription
}

struct BYOKOnboardingFlowView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(BYOKTrialManager.self) private var trial
    @Environment(PreferencesStore.self) private var preferences
    @Environment(LocalModelManager.self) private var modelManager
    @Environment(ProviderKeyPresence.self) private var keyPresence

    @AppStorage(OnboardingPersistenceKeys.legacyBYOKSetupStep) private var persistedStep = 0
    let onCancel: () -> Void

    private var step: BYOKSetupStep {
        BYOKSetupStep(rawValue: persistedStep) ?? .intro
    }

    var body: some View {
        switch step {
        case .intro:
            BYOKTrialIntroView(
                onContinue: { persistedStep = BYOKSetupStep.keys.rawValue },
                onBack: {
                    persistedStep = BYOKSetupStep.intro.rawValue
                    trial.deselectIfUnstarted()
                    onboarding.selectPath(.free)
                    onCancel()
                }
            )
        case .keys:
            BYOKKeysStepView(
                onContinue: {
                    onboarding.move(to: .transcription)
                    persistedStep = BYOKSetupStep.transcription.rawValue
                },
                onBack: {
                    onboarding.move(to: .setup)
                    persistedStep = BYOKSetupStep.intro.rawValue
                }
            )
        case .transcription:
            BYOKTranscriptionStepView(
                onAddOpenAIKey: {
                    onboarding.move(to: .setup)
                    persistedStep = BYOKSetupStep.keys.rawValue
                },
                onBack: {
                    onboarding.move(to: .setup)
                    persistedStep = BYOKSetupStep.keys.rawValue
                },
                onComplete: {
                    trial.select()
                    persistedStep = BYOKSetupStep.intro.rawValue
                    UserDefaults.standard.removeObject(forKey: OnboardingPersistenceKeys.legacyBYOKPathActive)
                    onboarding.advance()
                }
            )
        }
    }
}

private struct BYOKTrialIntroView: View {
    @Environment(BYOKTrialManager.self) private var trial
    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        OnboardingStepLayout(spacing: VFSpacing.sm) {
            OnboardingIconTile(systemName: "key.horizontal.fill", size: 56)
        } content: {
            VStack(spacing: VFSpacing.xs) {
                VStack(spacing: VFSpacing.xs) {
                    Text("Use Zerro with your own keys")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.vfTextPrimary)
                        .multilineTextAlignment(.center)

                    Text("No account or email required. Try 10 generations with your own provider accounts.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: VFSpacing.sm) {
                    BYOKPrivacyRow(
                        systemName: "arrow.triangle.branch",
                        title: "Direct to your providers",
                        detail: "Your recordings, prompts, and API keys never pass through Zerro\u{2019}s generation servers."
                    )
                    BYOKPrivacyRow(
                        systemName: "number",
                        title: "10 generations",
                        detail: "Failures and retries don\u{2019}t count. There\u{2019}s no time limit."
                    )
                    BYOKPrivacyRow(
                        systemName: "desktopcomputer",
                        title: "One free trial per Mac",
                        detail: "Zerro checks a one-way device identifier. The email and own-key trials can\u{2019}t be combined."
                    )
                }

                Text("Your providers may charge for API usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfRecordingRed)
                        .multilineTextAlignment(.center)
                }
            }
        } actions: {
            OnboardingPrimaryButton(
                working ? "Checking eligibility\u{2026}" : "Continue with my keys",
                isEnabled: !working
            ) {
                checkEligibility()
            }
            Button("Back", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(Color.vfTextSecondary)
        }
    }

    private func checkEligibility() {
        working = true
        errorMessage = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let result = try await trial.checkEligibility()
                switch result {
                case .eligible, .active:
                    trial.select()
                    onContinue()
                case .exhausted:
                    errorMessage = "This Mac has already completed its own-key trial."
                }
            } catch let error as BYOKTrialError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = BYOKTrialError.server.userMessage
            }
        }
    }
}

private struct BYOKPrivacyRow: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: VFSpacing.md) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.vfBrandAccent)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, 6)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: VFRadius.md))
    }
}

private struct BYOKKeysStepView: View {
    @Environment(ProviderKeyPresence.self) private var keyPresence

    @State private var openAI: APIKeyFieldModel
    @State private var gemini: APIKeyFieldModel
    @State private var anthropic: APIKeyFieldModel

    let onContinue: () -> Void
    let onBack: () -> Void

    init(
        onContinue: @escaping () -> Void,
        onBack: @escaping () -> Void,
        openAI: APIKeyFieldModel? = nil,
        gemini: APIKeyFieldModel? = nil,
        anthropic: APIKeyFieldModel? = nil
    ) {
        self.onContinue = onContinue
        self.onBack = onBack
        _openAI = State(initialValue: openAI ?? APIKeyFieldModel(provider: .openai))
        _gemini = State(initialValue: gemini ?? APIKeyFieldModel(provider: .gemini))
        _anthropic = State(initialValue: anthropic ?? APIKeyFieldModel(provider: .anthropic))
    }

    private var models: [APIKeyFieldModel] { [openAI, gemini, anthropic] }
    private var canContinue: Bool {
        !keyPresence.present.isEmpty && !models.contains { $0.state == .checking }
    }

    var body: some View {
        OnboardingStepLayout {
            EmptyView()
        } content: {
            VStack(spacing: VFSpacing.md) {
                VStack(spacing: VFSpacing.xs) {
                    Text("Add your API keys")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.vfTextPrimary)
                    Text("Add one, two, or all three providers. You can change them later in Settings.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.vfTextSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: VFSpacing.sm) {
                    BYOKProviderKeyRow(
                        model: openAI,
                        detail: "OpenAI models + optional cloud transcription"
                    )
                    BYOKProviderKeyRow(
                        model: gemini,
                        detail: "Gemini models"
                    )
                    BYOKProviderKeyRow(
                        model: anthropic,
                        detail: "Claude models"
                    )
                }

                Text(providerSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
            }
        } actions: {
            OnboardingPrimaryButton("Choose transcription", isEnabled: canContinue) {
                onContinue()
            }
            Button("Back", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(Color.vfTextSecondary)
        }
        .onAppear(perform: wireModels)
    }

    private var providerSummary: String {
        let count = keyPresence.present.count
        if count == 0 {
            return "Add at least one key to continue. Keys are stored securely in macOS Keychain."
        }
        return "\(count) provider\(count == 1 ? "" : "s") ready. Keys are stored securely in macOS Keychain."
    }

    private func wireModels() {
        let refresh = { [keyPresence] in keyPresence.refresh() }
        for model in models {
            model.onKeyStoreChanged = refresh
        }
        keyPresence.refresh()
    }
}

private struct BYOKProviderKeyRow: View {
    @Bindable var model: APIKeyFieldModel
    let detail: String
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.md) {
                ProviderLogo(provider: model.provider)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.provider.displayName) API Key")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfTextSecondary)
                }

                Spacer(minLength: VFSpacing.sm)

                if model.state == .verified, !model.trimmedKey.isEmpty {
                    HStack(spacing: VFSpacing.sm) {
                        Label("Saved", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.vfSuccessGreen)
                        Button("Remove") {
                            model.rawKey = ""
                            model.saveAndValidate()
                            editing = false
                        }
                        .buttonStyle(OnboardingKeyButtonStyle())
                    }
                } else {
                    Button(editing ? "Cancel" : "Add key") {
                        editing.toggle()
                        if editing {
                            DispatchQueue.main.async { focused = true }
                        }
                    }
                    .buttonStyle(OnboardingKeyButtonStyle())
                }
            }

            if editing {
                HStack(spacing: VFSpacing.sm) {
                    SecureField(placeholder, text: $model.rawKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.vfTextPrimary)
                        .focused($focused)
                        .onChange(of: model.rawKey) { _, _ in model.handleEdit() }
                        .onSubmit(save)
                    if model.state == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save", action: save)
                            .buttonStyle(OnboardingKeyButtonStyle())
                            .disabled(model.trimmedKey.isEmpty)
                    }
                }
                .padding(.horizontal, VFSpacing.md)
                .frame(height: 36)
                .background(Color.vfControlBackground, in: RoundedRectangle(cornerRadius: 10))
            }

            if model.state == .invalid {
                Text("That key wasn\u{2019}t accepted. Check it with \(model.provider.displayName) and try again.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfRecordingRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(VFSpacing.md)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: VFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md)
                .strokeBorder(
                    model.state == .verified
                        ? Color.vfSuccessGreen.opacity(0.35)
                        : Color.vfHairline,
                    lineWidth: 1
                )
        )
        .onChange(of: model.state) { _, newState in
            if newState == .verified {
                editing = false
            }
        }
    }

    private var placeholder: String {
        switch model.provider {
        case .openai: return "sk-\u{2026}"
        case .gemini: return "AIza\u{2026}"
        case .anthropic: return "sk-ant-\u{2026}"
        }
    }

    private func save() {
        model.saveAndValidate()
    }
}

private struct OnboardingKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextPrimary)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 7)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.12 : 0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

private struct ProviderLogo: View {
    let provider: ModelProvider

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .frame(width: 40, height: 40)
            .overlay {
                Image(provider.logoAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 23, height: 23)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("\(provider.displayName) logo")
    }
}

enum BYOKTranscriptionPolicy {
    static func isSelectable(_ engine: STTEngine, openAIKeyPresent: Bool) -> Bool {
        switch engine {
        case .local: return true
        case .cloud: return openAIKeyPresent
        case .auto: return false
        }
    }

    static func canContinue(selection: STTEngine?, openAIKeyPresent: Bool) -> Bool {
        guard let selection else { return false }
        return isSelectable(selection, openAIKeyPresent: openAIKeyPresent)
    }

    static func restoredSelection(
        preference: STTEngine,
        openAIKeyPresent: Bool
    ) -> STTEngine? {
        guard preference != .auto,
              isSelectable(preference, openAIKeyPresent: openAIKeyPresent)
        else { return nil }
        return preference
    }
}

/// Route-level host for the redesigned BYOK transcription step.
struct BYOKTranscriptionRouteView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(BYOKTrialManager.self) private var trial

    @AppStorage(OnboardingPersistenceKeys.legacyBYOKSetupStep) private var persistedStep = 0
    @AppStorage(OnboardingPersistenceKeys.legacyBYOKPathActive) private var legacyBYOKPathActive = false

    var body: some View {
        BYOKTranscriptionStepView(
            onAddOpenAIKey: { onboarding.returnToPathSelection() },
            onBack: { onboarding.returnToPathSelection() },
            onComplete: {
                trial.select()
                persistedStep = BYOKSetupStep.intro.rawValue
                legacyBYOKPathActive = false
                onboarding.finishSetup()
            }
        )
    }
}

struct BYOKTranscriptionStepView: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(LocalModelManager.self) private var modelManager
    @Environment(ProviderKeyPresence.self) private var keyPresence

    let onAddOpenAIKey: () -> Void
    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var selection: STTEngine?

    var body: some View {
        VStack(spacing: 24) {
            OnboardingSetupHero(
                systemName: "captions.bubble.fill",
                title: "Choose transcription",
                description: "Choose where Zerro turns your narration into text."
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Transcription method")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)

                HStack(alignment: .top, spacing: 12) {
                    transcriptionCard(
                        engine: .local,
                        title: "Local transcription",
                        detail: "Downloads a model so transcription runs on this Mac.",
                        footnote: "One-time download · about 1 GB",
                        systemImage: "desktopcomputer",
                        badge: "Recommended",
                        enabled: true
                    )
                    transcriptionCard(
                        engine: .cloud,
                        title: "Cloud transcription",
                        detail: keyPresence.openAIKeyPresent
                            ? "No model download. Your audio is transcribed by OpenAI."
                            : "Requires an OpenAI API key. Add one on the previous step to use cloud transcription.",
                        footnote: keyPresence.openAIKeyPresent ? "No model download" : "OpenAI key required",
                        systemImage: keyPresence.openAIKeyPresent ? "cloud" : "lock.fill",
                        badge: nil,
                        enabled: keyPresence.openAIKeyPresent
                    )
                }

                statusArea
                    .frame(minHeight: 42)

                OnboardingPrimaryButton(
                    "Continue",
                    systemImage: "arrow.right",
                    isEnabled: BYOKTranscriptionPolicy.canContinue(
                        selection: selection,
                        openAIKeyPresent: keyPresence.openAIKeyPresent
                    ),
                    action: continueToPermissions
                )

                Button("Back", action: onBack)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            keyPresence.refresh()
            selection = BYOKTranscriptionPolicy.restoredSelection(
                preference: preferences.sttEngine,
                openAIKeyPresent: keyPresence.openAIKeyPresent
            )
        }
        .onChange(of: keyPresence.openAIKeyPresent) { _, hasOpenAIKey in
            if selection == .cloud, !hasOpenAIKey {
                selection = nil
            }
        }
    }

    private func transcriptionCard(
        engine: STTEngine,
        title: String,
        detail: String,
        footnote: String,
        systemImage: String,
        badge: String?,
        enabled: Bool
    ) -> some View {
        Button {
            guard enabled else { return }
            selection = engine
            if engine == .local, !localModelReady, !localModelDownloading {
                modelManager.download()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: selection == engine ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(radioColor(engine: engine, enabled: enabled))

                    Spacer(minLength: 0)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.zerroTranscriptionGreen)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.zerroTranscriptionGreen.opacity(0.12), in: Capsule())
                    }
                }

                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(enabled ? Color.vfTextPrimary : Color.vfTextTertiary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(enabled ? Color.vfTextPrimary : Color.vfTextTertiary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(enabled ? Color.vfTextSecondary : Color.vfTextTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text(footnote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(enabled ? Color.vfTextSecondary : Color.vfTextTertiary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
            .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        cardBorder(engine: engine, enabled: enabled),
                        lineWidth: selection == engine ? 1.5 : 1
                    )
            )
            .shadow(
                color: selection == engine ? Color.zerroTranscriptionBlue.opacity(0.12) : .clear,
                radius: 10
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityValue(selection == engine ? "Selected" : enabled ? "Not selected" : "Unavailable")
    }

    @ViewBuilder
    private var statusArea: some View {
        if selection == .local {
            localModelStatus
        } else if !keyPresence.openAIKeyPresent {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.vfTextTertiary)
                Text("Cloud transcription needs an OpenAI API key.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
                Spacer(minLength: 0)
                Button("Add OpenAI key", action: onAddOpenAIKey)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        } else {
            Text("Select a transcription method to continue.")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var localModelStatus: some View {
        switch modelManager.state {
        case .notDownloaded:
            statusMessage(
                "The on-device model download starts automatically.",
                systemImage: "arrow.down.circle"
            )
        case let .downloading(progress, downloaded, total):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading local transcription model\u{2026}")
                    Spacer(minLength: 0)
                    Text("\(Self.megabytes(downloaded)) / \(Self.megabytes(total))")
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.vfTextSecondary)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.zerroTranscriptionBlue)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
        case .ready:
            statusMessage(
                "Local transcription is ready.",
                systemImage: "checkmark.circle.fill",
                color: Color.vfSuccessGreen
            )
        case .failed(let reason):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.vfRecordingRed)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: modelManager.download)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
        }
    }

    private func statusMessage(
        _ text: String,
        systemImage: String,
        color: Color = Color.vfTextTertiary
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 12)
    }

    private func continueToPermissions() {
        guard BYOKTranscriptionPolicy.canContinue(
            selection: selection,
            openAIKeyPresent: keyPresence.openAIKeyPresent
        ), let selection else { return }

        preferences.sttEngine = selection
        if selection == .local, !localModelReady, !localModelDownloading {
            modelManager.download()
        }
        Analytics.capture("stt_engine_changed", [
            "engine": selection.rawValue,
            "surface": "onboarding",
        ])
        onComplete()
    }

    private func radioColor(engine: STTEngine, enabled: Bool) -> Color {
        guard enabled else { return Color.vfTextTertiary }
        return selection == engine ? Color.zerroTranscriptionBlue : Color.vfTextSecondary
    }

    private func cardBorder(engine: STTEngine, enabled: Bool) -> Color {
        guard enabled else { return Color.white.opacity(0.07) }
        return selection == engine
            ? Color.zerroTranscriptionBlue.opacity(0.8)
            : Color.white.opacity(0.11)
    }

    private var localModelReady: Bool {
        if case .ready = modelManager.state { return true }
        return false
    }

    private var localModelDownloading: Bool {
        if case .downloading = modelManager.state { return true }
        return false
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private extension Color {
    static let zerroTranscriptionBlue = Color(red: 0.55, green: 0.66, blue: 1.0)
    static let zerroTranscriptionGreen = Color(red: 0.56, green: 0.84, blue: 0.68)
}

#if DEBUG

// MARK: - BYOK Canvas previews

@MainActor
private func previewKeyModel(
    _ provider: ModelProvider,
    savedKey: String? = nil
) -> APIKeyFieldModel {
    let model = APIKeyFieldModel(
        provider: provider,
        keychain: InMemoryKeychainSlot(savedKey),
        firstKeyProbe: { savedKey == nil }
    )
    model.validator = { _ in .valid }
    return model
}

#Preview("3A · BYOK Trial") {
    OnboardingPreviewHost(step: .email) {
        BYOKTrialIntroView(onContinue: {}, onBack: {})
    }
}

#Preview("3B · BYOK API Keys") {
    let openAI = previewKeyModel(.openai)
    let gemini = previewKeyModel(.gemini, savedKey: "preview-gemini-key")
    let anthropic = previewKeyModel(.anthropic, savedKey: "preview-anthropic-key")

    return OnboardingPreviewHost(
        step: .email,
        providerKeys: [.gemini, .anthropic]
    ) {
        BYOKKeysStepView(
            onContinue: {},
            onBack: {},
            openAI: openAI,
            gemini: gemini,
            anthropic: anthropic
        )
    }
}

#Preview("3C · BYOK Transcription") {
    OnboardingPreviewHost(
        step: .email,
        providerKeys: [.openai, .gemini, .anthropic]
    ) {
        BYOKTranscriptionStepView(
            onAddOpenAIKey: {},
            onBack: {},
            onComplete: {}
        )
    }
}

#Preview("3D · Transcription without OpenAI") {
    OnboardingPreviewHost(
        step: .email,
        providerKeys: [.gemini, .anthropic]
    ) {
        BYOKTranscriptionStepView(
            onAddOpenAIKey: {},
            onBack: {},
            onComplete: {}
        )
    }
}

#endif

extension ModelProvider {
    var logoAssetName: String {
        switch self {
        case .openai: return "ProviderOpenAI"
        case .gemini: return "ProviderGemini"
        case .anthropic: return "ProviderAnthropic"
        }
    }
}
