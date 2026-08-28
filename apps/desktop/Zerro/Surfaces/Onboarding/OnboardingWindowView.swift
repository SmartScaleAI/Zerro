//
//  OnboardingWindowView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Root container for the redesigned onboarding window. The visible renderer
//  follows OnboardingState.currentScreen while the state keeps the legacy step
//  synchronized for safe phased migration and Screen Recording relaunches.
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
            .frame(width: 700, height: 680)
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
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                if onboarding.currentScreen != .reconsent {
                    OnboardingRouteProgressIndicator(
                        screens: onboarding.progressScreens,
                        currentIndex: onboarding.progressIndex
                    )
                    .padding(.top, 28)
                }

                stepBody
                    .id(onboarding.currentScreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 48)
                    .padding(.top, onboarding.currentScreen == .reconsent ? 28 : 20)
                    .padding(.bottom, 36)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: onboarding.currentScreen)
        .onAppear { onboarding.recordScreenViewed(onboarding.currentScreen) }
        .onChange(of: onboarding.currentScreen) { _, screen in
            onboarding.recordScreenViewed(screen)
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch onboarding.currentScreen {
        case .setup:
            OnboardingSetupStepView()
        case .keys:
            BYOKSetupView()
        case .transcription:
            BYOKSetupView()
        case .permissions:
            PermissionsStepView()
        case .complete:
            AllSetStepView()
        case .reconsent:
            ConsentStepView()
        }
    }

    private var onboardingBackground: some View {
        ZStack {
            Color.vfPanelBackground
            RadialGradient(
                colors: [Color.zerroOnboardingBlue.opacity(0.18), .clear],
                center: UnitPoint(x: 0.18, y: 0.08),
                startRadius: 0,
                endRadius: 390
            )
            RadialGradient(
                colors: [Color.zerroOnboardingGreen.opacity(0.13), .clear],
                center: UnitPoint(x: 0.84, y: 0.12),
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Route progress

struct OnboardingRouteProgressIndicator: View {
    let screens: [OnboardingScreen]
    let currentIndex: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(index < (currentIndex ?? 0) ? 0.26 : 0.14))
                    if index == currentIndex {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.zerroOnboardingBlue, .zerroOnboardingGreen],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                }
                .frame(width: 40, height: 5)
                .accessibilityLabel(screen.analyticsName.capitalized)
                .accessibilityValue(index == currentIndex ? "Current step" : "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }
}

private extension Color {
    static let zerroOnboardingBlue = Color(red: 0.55, green: 0.66, blue: 1.0)
    static let zerroOnboardingGreen = Color(red: 0.56, green: 0.84, blue: 0.68)
}

#if DEBUG

// MARK: - Canvas previews

/// Isolated shell for onboarding Canvas previews. It mirrors the production
/// panel dimensions and environment while keeping UserDefaults, Keychain,
/// and model storage out of the developer's real app state.
@MainActor
struct OnboardingPreviewHost<Content: View>: View {
    @State private var onboarding: OnboardingState
    @State private var permissions: PermissionsManager
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
        let entitlements = EntitlementStore(licenseService: .inMemory())
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
        _entitlements = State(initialValue: entitlements)
        _preferences = State(initialValue: preferences)
        _modelManager = State(initialValue: modelManager)
        _keyPresence = State(initialValue: keyPresence)
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            OnboardingRouteProgressIndicator(
                screens: onboarding.progressScreens,
                currentIndex: onboarding.progressIndex
            )
                .padding(.top, VFSpacing.lg)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, VFSpacing.lg)
        }
        .frame(width: 700, height: 680)
        .background(Color.vfPanelBackground)
        .defaultAppStorage(defaults)
        .environment(permissions)
        .environment(onboarding)
        .environment(entitlements)
        .environment(preferences)
        .environment(modelManager)
        .environment(keyPresence)
        .preferredColorScheme(.dark)
    }
}

#endif
