//
//  OnboardingWindowView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Root container for the onboarding window. Hosts:
//    • Step dots indicator at the top.
//    • The current step view, switched on OnboardingState.currentStep.
//    • The dev panel below the main panel (DEBUG only) so jumping
//      between steps doesn't require advancing through each one
//      manually.
//
//  Window chrome (title bar, traffic lights) is provided by the Window
//  scene in `OnboardingScene`. The root uses the pure-black panel token.
//

import SwiftUI

struct OnboardingWindowView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        mainPanel
            .frame(width: 580)
            .background(Color.vfPanelBackground)
            .onAppear {
                // Register the openWindow action so the global hotkey can
                // re-present this window after the user has dismissed it.
                // Pairs with the MenuBarPanelView registration — whichever
                // view appears first wins; subsequent appearances overwrite
                // with the same captured closure (idempotent).
                AppDelegate.requestOpenOnboarding = {
                    openWindow(id: OnboardingScene.windowID)
                }
            }
    }

    private var mainPanel: some View {
        VStack(spacing: VFSpacing.lg) {
            StepDotsIndicator(current: onboarding.currentStep)
                .padding(.top, VFSpacing.lg)

            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, VFSpacing.lg)
                // Tier 4: per-step funnel, fired when a step becomes visible.
                // From the view (not advance()) so the step restored after the
                // Screen Recording SIGKILL relaunch is counted; deduped per
                // install inside recordStepViewed so it can't inflate.
                .onAppear { onboarding.recordStepViewed(onboarding.currentStep) }
                .onChange(of: onboarding.currentStep) { _, newStep in
                    onboarding.recordStepViewed(newStep)
                }
        }
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch onboarding.currentStep {
        case .welcome:     WelcomeStepView()
        case .consent:     ConsentStepView()
        case .email:       EmailStepView()
        case .permissions: PermissionsStepView()
        case .devMode:     DevModeStepView()
        case .allSet:      AllSetStepView()
        }
    }
}

// MARK: - Step dots indicator

private struct StepDotsIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Circle()
                    .fill(step == current ? Color.vfBrandAccent : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

#if DEBUG

// MARK: - Canvas previews

/// Isolated shell for onboarding Canvas previews. It mirrors the production
/// panel dimensions and environment while keeping UserDefaults, Keychain,
/// model storage, and managed-backend traffic out of the developer's real app
/// state. Individual step previews live below and alongside their private BYOK
/// views in `BYOKOnboardingFlow.swift`.
@MainActor
struct OnboardingPreviewHost<Content: View>: View {
    @State private var onboarding: OnboardingState
    @State private var permissions: PermissionsManager
    @State private var trialCredits: TrialCreditsManager
    @State private var byokTrial: BYOKTrialManager
    @State private var entitlements: EntitlementStore
    @State private var preferences: PreferencesStore
    @State private var modelManager: LocalModelManager
    @State private var keyPresence: ProviderKeyPresence

    private let defaults: UserDefaults
    private let step: OnboardingStep
    @ViewBuilder private let content: () -> Content

    init(
        step: OnboardingStep,
        screenStatus: PermissionStatus? = nil,
        microphoneStatus: PermissionStatus? = nil,
        providerKeys: Set<ModelProvider> = [],
        @ViewBuilder content: @escaping () -> Content
    ) {
        let defaults = UserDefaults.ephemeralPreview()
        let onboarding = OnboardingState(defaults: defaults)
        onboarding.jump(to: step)
        onboarding.pinnedScreenSubState = screenStatus
        onboarding.pinnedMicSubState = microphoneStatus

        let preferences = PreferencesStore(defaults: defaults)
        let permissions = PermissionsManager(defaults: defaults)
        let trialCredits = TrialCreditsManager.inMemory()
        let byokTrial = BYOKTrialManager.inMemory()
        let entitlements = EntitlementStore(
            licenseService: .inMemory(),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(),
            trialCredits: trialCredits,
            byokTrial: byokTrial,
            defaults: defaults
        )
        let previewModel = ModelSpec(
            id: "preview-model",
            fileName: "preview-model.bin",
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            byteSize: 0
        )
        let modelManager = LocalModelManager(
            spec: previewModel,
            preferences: preferences,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ZerroCanvasPreview-\(UUID().uuidString)", isDirectory: true),
            diskHeadroom: 0
        )
        let keyPresence = ProviderKeyPresence { providerKeys.contains($0) }

        self.defaults = defaults
        self.step = step
        self.content = content
        _onboarding = State(initialValue: onboarding)
        _permissions = State(initialValue: permissions)
        _trialCredits = State(initialValue: trialCredits)
        _byokTrial = State(initialValue: byokTrial)
        _entitlements = State(initialValue: entitlements)
        _preferences = State(initialValue: preferences)
        _modelManager = State(initialValue: modelManager)
        _keyPresence = State(initialValue: keyPresence)
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            StepDotsIndicator(current: step)
                .padding(.top, VFSpacing.lg)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, VFSpacing.lg)
        }
        .frame(width: 580, height: 500)
        .background(Color.vfPanelBackground)
        .defaultAppStorage(defaults)
        .environment(permissions)
        .environment(onboarding)
        .environment(trialCredits)
        .environment(byokTrial)
        .environment(entitlements)
        .environment(preferences)
        .environment(modelManager)
        .environment(keyPresence)
        .preferredColorScheme(.dark)
    }
}

#endif
