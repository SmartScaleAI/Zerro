//
//  OnboardingModeSelectionView.swift
//  Zerro
//
//  The explicit post-email fork between Zerro-managed cloud processing and
//  local transcription backed by the user's provider keys.
//

import SwiftUI

enum OnboardingModeChoice: String, CaseIterable, Equatable {
    case managed
    case localBYOK
}

struct OnboardingModeSelectionView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(TrialCreditsManager.self) private var trialCredits
    @Environment(BYOKTrialManager.self) private var byokTrial
    @Environment(EntitlementStore.self) private var entitlements

    @AppStorage(OnboardingPersistenceKeys.legacyBYOKPathActive)
    private var legacyBYOKPathActive = false

    @State private var selection: OnboardingModeChoice = .managed
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var canContinueWithoutTrial = false

    var body: some View {
        VStack(spacing: 22) {
            OnboardingSetupHero(
                systemName: "slider.horizontal.3",
                title: "Choose how you want to use Zerro",
                description: "Pick the setup that fits your workflow. You can change transcription later in Settings."
            )

            HStack(alignment: .top, spacing: 14) {
                modeCard(
                    choice: .managed,
                    systemName: "cloud.fill",
                    title: "Zerro Cloud",
                    badge: "Recommended",
                    detail: "The fastest setup. No API keys or model download required."
                )

                modeCard(
                    choice: .localBYOK,
                    systemName: "desktopcomputer",
                    title: "Local + Own API Keys",
                    badge: nil,
                    detail: "Transcription runs on this Mac. Generation uses OpenAI, Anthropic, or Gemini."
                )
            }

            VStack(spacing: 10) {
                Text("Local setup downloads a transcription model (about 1 GB). AI generation still uses your selected provider\u{2019}s API.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfRecordingRed)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 470)
                }

                OnboardingPrimaryButton(
                    primaryTitle,
                    systemImage: isWorking ? nil : "arrow.right",
                    isEnabled: !isWorking,
                    action: continueWithSelection
                )

                if canContinueWithoutTrial {
                    Button("Continue setup without free credits") {
                        onboarding.selectPath(.free)
                        onboarding.finishSetup()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                }

                Button("Back") {
                    onboarding.move(to: .setup)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
                .disabled(isWorking)
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryTitle: String {
        if isWorking {
            return selection == .managed
                ? "Setting up Zerro Cloud\u{2026}"
                : "Checking eligibility\u{2026}"
        }
        return selection == .managed
            ? "Continue with Zerro Cloud"
            : "Continue with Local Setup"
    }

    private func modeCard(
        choice: OnboardingModeChoice,
        systemName: String,
        title: String,
        badge: String?,
        detail: String
    ) -> some View {
        let selected = selection == choice
        return Button {
            guard !isWorking else { return }
            selection = choice
            errorMessage = nil
            canContinueWithoutTrial = false
        } label: {
            VStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.zerroSetupBlue.opacity(0.14) : Color.white.opacity(0.055))
                    .frame(width: 54, height: 54)
                    .overlay(
                        Image(systemName: systemName)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(selected ? Color.zerroSetupBlue : Color.vfTextSecondary)
                    )

                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                        .multilineTextAlignment(.center)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.zerroSetupBlue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.zerroSetupBlue.opacity(0.12), in: Capsule())
                    }
                }

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .top)
            .background(
                selected ? Color.zerroSetupBlue.opacity(0.075) : Color.vfCardBackground,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        selected ? Color.zerroSetupBlue.opacity(0.9) : Color.white.opacity(0.11),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .shadow(color: selected ? Color.zerroSetupBlue.opacity(0.13) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func continueWithSelection() {
        errorMessage = nil
        canContinueWithoutTrial = false
        isWorking = true

        switch selection {
        case .managed:
            activateManagedTrial()
        case .localBYOK:
            beginLocalSetup()
        }
    }

    private func activateManagedTrial() {
        Task { @MainActor in
            do {
                _ = try await trialCredits.activateManagedOnboardingTrial()
                legacyBYOKPathActive = false
                onboarding.selectPath(.free)
                entitlements.refresh()
                onboarding.finishSetup()
            } catch let error as TrialStartError {
                isWorking = false
                if error == .alreadyUsed || error == .deviceTrialUsed {
                    errorMessage = "This Mac has already used its free trial. You can continue setup and add a license later."
                    canContinueWithoutTrial = true
                } else {
                    errorMessage = error.userMessage
                }
            } catch {
                isWorking = false
                errorMessage = TrialStartError.malformedResponse.userMessage
            }
        }
    }

    private func beginLocalSetup() {
        Task { @MainActor in
            do {
                let eligibility = try await byokTrial.checkEligibility()
                switch eligibility {
                case .eligible, .active:
                    byokTrial.select()
                    legacyBYOKPathActive = true
                    onboarding.beginBYOKKeys()
                case .exhausted:
                    isWorking = false
                    errorMessage = "This Mac has already completed its own-key trial. Add a BYOK license in Settings to continue."
                }
            } catch let error as BYOKTrialError {
                isWorking = false
                errorMessage = error.userMessage
            } catch {
                isWorking = false
                errorMessage = BYOKTrialError.server.userMessage
            }
        }
    }
}

#if DEBUG

#Preview("Setup · Choose mode") {
    OnboardingPreviewHost(step: .email) {
        OnboardingModeSelectionView()
    }
}

#endif
