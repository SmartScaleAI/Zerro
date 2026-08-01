//
//  TrialEmailCaptureView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/2/26.
//
//  Phase F (revised) — the standalone email-verification surface for users who
//  DIDN'T verify during onboarding: existing users (onboarded before the required
//  email step) and the rare user who took the infra-failure fallback. Email
//  verification for NEW users now happens in onboarding (`EmailStepView`); this
//  window is reached only from the Settings/Billing "verify email" affordance +
//  the menu-bar banner. Two steps in one window, reusing the paywall/onboarding
//  chrome so it reads as one app:
//    1. Enter email → "Send code" (POST trial-start request).
//    2. Enter the 6-digit code → "Verify" (POST trial-start verify) → on success
//       the trial token is stored in `TrialCreditsManager` and the entitlement is
//       refreshed so the granted credits show.
//
//  Dismissing without verifying just closes — no penalty; the affordance stays
//  available until they verify.
//

import AppKit
import os
import SwiftUI

// MARK: - TrialEmailModel

/// Drives the two-step capture flow. Mirrors `PaywallActivationModel`'s shape: a
/// small `@Observable` field model with an explicit phase the UI renders against.
@MainActor
@Observable
final class TrialEmailModel {
    enum Purpose { case managedTrial, onboardingContact }
    enum Step: Equatable { case email, code }
    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
        case terminal(TrialEmailTerminalState)
    }

    var step: Step = .email
    var email: String = ""
    var code: String = ""
    var phase: Phase = .idle
    private(set) var systemFailureCount = 0
    private let purpose: Purpose

    init(purpose: Purpose = .managedTrial) {
        self.purpose = purpose
    }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isWorking: Bool { phase == .working }
    var shouldOfferInfrastructureFallback: Bool { systemFailureCount >= 2 }
    var terminalState: TrialEmailTerminalState? {
        guard case .terminal(let state) = phase else { return nil }
        return state
    }

    /// Editing after an error demotes back to `.idle` so the stale error clears.
    func handleEdit() {
        if isWorking { return }
        if case .failed = phase { phase = .idle }
    }

    /// Request a code be emailed. On success advances to the code step.
    func sendCode(using trial: TrialCreditsManager) {
        let email = trimmedEmail
        guard email.contains("@"), email.contains(".") else {
            phase = .failed(TrialStartError.invalidEmail.userMessage)
            systemFailureCount = 0
            return
        }
        phase = .working
        Task { @MainActor in
            do {
                switch purpose {
                case .managedTrial:
                    try await trial.requestCode(email: email)
                case .onboardingContact:
                    try await trial.requestOnboardingCode(email: email)
                }
                phase = .idle
                systemFailureCount = 0
                step = .code
            } catch let error as TrialStartError {
                handle(error)
            } catch {
                recordSystemFailure("Couldn\u{2019}t send the code. Please try again.", error: error)
            }
        }
    }

    /// Verify the entered code. On success calls `onVerified` (AppState resumes).
    func verify(
        using trial: TrialCreditsManager,
        marketingEmailOptIn: Bool? = nil,
        onVerified: @escaping () -> Void
    ) {
        let email = trimmedEmail
        let code = trimmedCode
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            phase = .failed(TrialStartError.invalidCode.userMessage)
            systemFailureCount = 0
            return
        }
        phase = .working
        Task { @MainActor in
            do {
                switch purpose {
                case .managedTrial:
                    _ = try await trial.verifyCode(
                        email: email,
                        code: code,
                        marketingEmailOptIn: marketingEmailOptIn
                    )
                case .onboardingContact:
                    try await trial.verifyOnboardingCode(
                        email: email,
                        code: code,
                        marketingEmailOptIn: marketingEmailOptIn ?? false
                    )
                }
                phase = .idle
                systemFailureCount = 0
                onVerified()
            } catch let error as TrialStartError {
                handle(error)
            } catch {
                recordSystemFailure("Couldn\u{2019}t verify the code. Please try again.", error: error)
            }
        }
    }

    func useDifferentEmail() {
        step = .email
        code = ""
        phase = .idle
        systemFailureCount = 0
    }

    private func handle(_ error: TrialStartError) {
        if let terminal = TrialEmailTerminalState(error) {
            phase = .terminal(terminal)
            systemFailureCount = 0
            return
        }

        switch error {
        case .network, .server, .sendFailed, .malformedResponse, .malformedRequest,
             .invalidContactToken:
            recordSystemFailure(error.userMessage, error: error)
        case .invalidEmail, .disposableEmail, .rateLimited, .invalidCode,
             .codeExpired, .tooManyAttempts, .alreadyUsed, .deviceTrialUsed:
            phase = .failed(error.userMessage)
            systemFailureCount = 0
        }
    }

    private func recordSystemFailure(_ message: String, error: Error) {
        systemFailureCount += 1
        phase = .failed(message)
        Log.billing.error(
            "trial email system failure #\(self.systemFailureCount, privacy: .public): \(String(describing: error), privacy: .public)"
        )
    }
}

// MARK: - TrialEmailCaptureView

struct TrialEmailCaptureView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(AppState.self) private var appState
    @Environment(TrialCreditsManager.self) private var trialCredits
    @Environment(EntitlementStore.self) private var entitlements

    @State private var model = TrialEmailModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text(headline)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text(subhead)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if model.terminalState != nil {
                OnboardingPrimaryButton("Done", action: cancel)
            } else {
                VStack(spacing: VFSpacing.md) {
                    switch model.step {
                    case .email: emailStep
                    case .code:  codeStep
                    }

                    if case .failed(let message) = model.phase {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfWarningAmber)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    OnboardingSecondaryButton("Not now", action: cancel)
                }
            }
        }
        .frame(width: 460)
        .frame(minHeight: 440)
        .background(Color.vfPanelBackground)
        .onAppear {
            // Pre-fill the remembered email (reinstall / repeat-trial convenience).
            if model.email.isEmpty, let remembered = trialCredits.rememberedEmail {
                model.email = remembered
            }
            fieldFocused = true
        }
    }

    // MARK: Copy

    private var headline: String {
        if let terminal = model.terminalState { return terminal.headline }
        switch model.step {
        case .email: return "Start your free trial"
        case .code:  return "Enter your code"
        }
    }

    private var subhead: String {
        if let terminal = model.terminalState { return terminal.message }
        switch model.step {
        case .email:
            return "Verify your email to get free generations on us: no credit card, no API key. We\u{2019}ll send a 6-digit code."
        case .code:
            return TrialEmailCopy.codeDelivery(to: model.trimmedEmail)
        }
    }

    // MARK: Email step

    private var emailStep: some View {
        VStack(spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                TextField("you@example.com", text: $model.email)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextPrimary)
                    .focused($fieldFocused)
                    .disabled(model.isWorking)
                    .onChange(of: model.email) { _, _ in model.handleEdit() }
                    .onSubmit(sendCode)
                    .padding(.horizontal, VFSpacing.md)
                    .frame(height: 38)
                    .background(fieldBackground)
                    .overlay(fieldBorder)
                if model.isWorking { SettingsStatusPill(kind: .checking) }
            }
            OnboardingPrimaryButton("Send code", isEnabled: !model.isWorking, action: sendCode)
        }
    }

    // MARK: Code step

    private var codeStep: some View {
        VStack(spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                TextField("123456", text: $model.code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .focused($fieldFocused)
                    .disabled(model.isWorking)
                    .onChange(of: model.code) { _, newValue in
                        // Keep only digits, cap at 6.
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { model.code = digits }
                        model.handleEdit()
                    }
                    .onSubmit(verify)
                    .padding(.horizontal, VFSpacing.md)
                    .frame(height: 38)
                    .background(fieldBackground)
                    .overlay(fieldBorder)
                if model.isWorking { SettingsStatusPill(kind: .checking) }
            }
            OnboardingPrimaryButton("Verify", isEnabled: !model.isWorking, action: verify)

            Button("Use a different email", action: { model.step = .email; model.code = ""; model.phase = .idle })
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.vfBrandAccent)
        }
    }

    // MARK: Chrome

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.vfControlBackground)
    }
    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.vfHairline, lineWidth: 0.5)
    }

    // MARK: Actions

    private func sendCode() {
        model.sendCode(using: trialCredits)
    }

    private func verify() {
        model.verify(using: trialCredits) {
            // Token + email + credits are stored by TrialCreditsManager; refresh
            // the entitlement so the new trial credits show, then close.
            appState.handleTrialVerified()
            dismissWindow(id: TrialEmailScene.windowID)
        }
    }

    private func cancel() {
        // No penalty — this surface is the optional "finish verifying" path for
        // existing / infra-fallback users; closing just dismisses.
        dismissWindow(id: TrialEmailScene.windowID)
    }
}

// MARK: - Preview

#Preview("Trial email capture") {
    TrialEmailCaptureView()
        .environment(AppState())
        .environment(TrialCreditsManager.inMemory())
        .environment(EntitlementStore(licenseService: .inMemory()))
}
