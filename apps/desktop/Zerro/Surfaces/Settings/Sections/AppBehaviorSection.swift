//
//  AppBehaviorSection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — App Behavior section of the redesigned Settings layout:
//    1. Launch at Login — toggle backed by SMAppService.mainApp via
//       LaunchAtLoginController (the OS is the source of truth, so the
//       toggle stays honest even if the user disables the login item
//       in System Settings).
//    2. Re-run Onboarding — secondary button that flips the persisted
//       hasCompletedOnboarding flag back to false, jumps to .welcome,
//       and re-presents the onboarding window via the same opener path
//       the hotkey-gating code uses.
//    3. Reset to Defaults — destructive button behind an NSAlert that
//       wipes PreferencesStore-tracked UserDefaults keys (microphone,
//       default output mode) but NOT the Keychain API key and NOT the
//       prompt history. Those have their own destructive affordances
//       elsewhere in the same Settings surface.
//

import AppKit
import SwiftUI

struct AppBehaviorSection: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(OnboardingState.self) private var onboarding
    @Environment(LaunchAtLoginController.self) private var launchAtLogin
    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        SettingsSection("App Behavior") {
            LaunchAtLoginRow()
            SettingsRowDivider()
            CrashReportingRow()
            SettingsRowDivider()
            RerunOnboardingRow()
            SettingsRowDivider()
            ResetDefaultsRow()
        }
    }
}

// MARK: - Analytics & Crash Reporting

// The SINGLE documented exception to Zerro's "your content stays local"
// story. Anonymous, on by default, one-click off. The toggle writes to
// the UserDefaults key both `Analytics` and `CrashReporting` read for
// their opt-out gate, and `.onChange` flips PostHog's opt-out state live,
// so turning it OFF stops all transmission immediately — no restart.
// Default ON matches the `isEnabled` fallback ("key absent" → true).

private struct CrashReportingRow: View {
    @AppStorage(CrashReporting.isEnabledDefaultsKey) private var isEnabled: Bool = true

    var body: some View {
        SettingsRow(
            label: "Send Anonymous Usage Data & Crash Reports",
            description: "Shares anonymous product usage and crash diagnostics so we can fix bugs and improve Zerro. Recordings, transcripts, generated prompts, and your API key are never sent."
        ) {
            Toggle("Send Anonymous Usage Data & Crash Reports", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.vfSuccessGreen)
                .onChange(of: isEnabled) { _, newValue in
                    Analytics.setEnabled(newValue)
                }
        }
    }
}

// MARK: - Launch at Login

private struct LaunchAtLoginRow: View {
    @Environment(LaunchAtLoginController.self) private var controller

    var body: some View {
        SettingsRow(
            label: "Launch at Login",
            description: "Start Zerro automatically when you sign in."
        ) {
            Toggle("Launch at Login", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.vfSuccessGreen)
        }
        .onAppear { controller.refresh() }
    }

    /// Custom binding so the SMAppService call happens before the
    /// observed value flips. The setter routes through
    /// LaunchAtLoginController, which re-reads from the OS — that's
    /// what makes the toggle snap back if the OS rejected the register.
    private var binding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }
}

// MARK: - Re-run Onboarding

private struct RerunOnboardingRow: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsRow(
            label: "Re-run Onboarding",
            description: "Walk through setup and permission checks again."
        ) {
            Button("Re-run Setup", action: rerun)
                .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }

    private func rerun() {
        // Mirrors the DEBUG "Reset Onboarding" dev affordance in the
        // menu-bar panel: flip the persisted flag, return to step 1,
        // clear the permission request-tracking flags so the
        // dev-drift fallback doesn't false-positive into the granted
        // view before the user has been prompted, then bring the
        // window forward. The TCC grants themselves stay where they
        // are — re-running setup shouldn't make a user re-grant Screen
        // Recording, only re-confirm that the app sees it correctly.
        onboarding.hasCompletedOnboarding = false
        onboarding.currentStep = .welcome
        permissions.resetRequestFlags()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: OnboardingScene.windowID)
    }
}

// MARK: - Reset to Defaults

private struct ResetDefaultsRow: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        SettingsRow(
            label: "Reset to Defaults",
            description: "Restore every setting above to its original value."
        ) {
            Button("Reset\u{2026}", action: confirmAndReset)
                .buttonStyle(SettingsDestructiveButtonStyle())
        }
    }

    private func confirmAndReset() {
        let alert = NSAlert()
        alert.messageText = "Reset settings to defaults?"
        alert.informativeText = "This restores the microphone selection and default output mode to their original values. Your API key and prompt history aren't affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            preferences.resetToDefaults()
        }
    }
}

#Preview {
    AppBehaviorSection()
        .environment(PreferencesStore())
        .environment(OnboardingState())
        .environment(LaunchAtLoginController())
        .environment(PermissionsManager())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
