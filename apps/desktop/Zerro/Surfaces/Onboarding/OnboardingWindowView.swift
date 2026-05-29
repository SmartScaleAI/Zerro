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
//  scene in `OnboardingScene`. The dark panel background and rounded
//  card here match the mockup composition.
//

import SwiftUI

struct OnboardingWindowView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        mainPanel
            .frame(width: 580)
            .background(Color.vfCardBackground)
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
        }
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch onboarding.currentStep {
        case .welcome:         WelcomeStepView()
        case .screenRecording: ScreenRecordingStepView()
        case .microphone:      MicrophoneStepView()
        case .accessibility:   AccessibilityStepView()
        case .apiKey:          APIKeyStepView()
        case .allSet:          AllSetStepView()
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
