//
//  OnboardingConsentStep.swift
//  Zerro
//
//  Phase 22 — Onboarding Consent.
//
//  Clickwrap consent gate, shown as step 2 (right after Welcome, before the
//  email + TCC-permission steps). The affirmative "Agree & Continue" press IS
//  the consent action: there is no skip or dismiss path around it, and there
//  is no pre-checked auto-advance — the flow cannot move forward until the
//  button is pressed. Pressing it records the acceptance locally (see
//  `OnboardingState.recordConsent`) and either advances (first run) or
//  dismisses the window (re-consent mode).
//
//  The anonymous-analytics choice is surfaced here as an INFORMED, clearly
//  labeled toggle writing to the SAME UserDefaults key the Settings screen
//  uses (`CrashReporting.isEnabledDefaultsKey`) — one source of truth, no
//  second store. The analytics preference is INDEPENDENT of consent: it does
//  not gate "Agree & Continue" (agreeing to Terms is required; analytics is
//  optional, on by default per `OnboardingState.analyticsDefaultOptIn`).
//

import SwiftUI

struct ConsentStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.dismissWindow) private var dismissWindow

    /// Same key + default the Settings "Send Anonymous Usage Data & Crash
    /// Reports" row binds to — this is deliberately the identical source of
    /// truth, so a change here is reflected there and vice versa. The default
    /// is routed through the constant (not hardcoded) so the opt-out posture
    /// can be flipped to opt-in without touching this view.
    //
    // DEFERRED Phase 22.x — EU/US geo-detection of the default opt-in state.
    @AppStorage(CrashReporting.isEnabledDefaultsKey)
    private var analyticsEnabled = OnboardingState.analyticsDefaultOptIn

    var body: some View {
        OnboardingStepLayout {
            OnboardingIconTile(systemName: "checkmark.shield.fill")
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Terms & Privacy")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                // Markdown links open https://getzerro.app/terms and /privacy
                // in the default browser via the environment's openURL action.
                Text("By continuing, you agree to Zerro\u{2019}s [Terms of Service](https://getzerro.app/terms) and [Privacy Policy](https://getzerro.app/privacy).")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .tint(Color.vfBrandAccent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            analyticsToggleRow
        } actions: {
            // The ONLY way forward. No skip / dismiss path around it; no
            // pre-checked auto-advance. Always enabled — analytics never
            // gates consent.
            OnboardingPrimaryButton("Agree & Continue") { agree() }
        }
    }

    // MARK: - Analytics choice (shares storage with Settings)

    private var analyticsToggleRow: some View {
        HStack(alignment: .top, spacing: VFSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send anonymous usage data & crash reports")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Metadata only, never your recordings, transcripts, or prompts. Change anytime in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle("Send anonymous usage data & crash reports", isOn: $analyticsEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.vfSuccessGreen)
                // Flip PostHog's opt-out state live, mirroring the Settings row
                // so the choice takes effect immediately without a restart.
                .onChange(of: analyticsEnabled) { _, newValue in
                    Analytics.setEnabled(newValue)
                }
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, VFSpacing.md)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: VFRadius.md))
    }

    // MARK: - Consent action

    private func agree() {
        // Capture BEFORE recording — `recordConsent()` clears the flag.
        let wasReconsent = onboarding.isReconsenting
        onboarding.recordConsent()
        if wasReconsent {
            // Re-consent mode: onboarding is already complete, so accepting
            // the refreshed Terms simply closes the window back to the app.
            dismissWindow(id: OnboardingScene.windowID)
        } else {
            onboarding.advance()
        }
    }
}
