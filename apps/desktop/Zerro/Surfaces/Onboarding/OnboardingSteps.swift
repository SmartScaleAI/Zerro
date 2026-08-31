//
//  OnboardingSteps.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  The step views. The merged Permissions step shows Screen Recording
//  and Microphone as two rows on one screen, each branching on a
//  tri-state sub-state derived from PermissionsManager (plus a fourth
//  "needs relaunch" sub-state for Screen Recording), with DEBUG-only
//  override pins on OnboardingState so the dev panel can preview any
//  sub-state per row without toggling system permissions.
//
//  Sub-state semantics (per row):
//    • notDetermined — an Allow control triggers the OS request.
//    • granted — a checkmark indicator.
//    • denied — Open System Settings deep-link + Check again.
//    • needs-relaunch (Screen only) — Relaunch + Check again.
//  Advancing is an explicit user action: the single Continue Setup
//  button stays disabled until BOTH permissions are granted (no
//  auto-advance).
//

import AppKit
import os
import SwiftUI

// MARK: - Welcome

struct WelcomeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Welcome to Zerro")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                VStack(spacing: VFSpacing.sm) {
                    Text("Record your screen, explain what you want, and get it done faster.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("We\u{2019}ll set up a few things. It takes about a minute.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vfTextTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        } actions: {
            OnboardingPrimaryButton("Get Started") { onboarding.advance() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.vfTextSecondary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Permissions (merged Screen Recording + Microphone)

/// One native-forward screen for both macOS permissions Zerro needs. Screen
/// Recording and Microphone each render as their own row with their own state
/// and action, while a single Continue button stays disabled until BOTH are
/// granted and live in the current process.
///
/// Advancing is an explicit user action — there is NO auto-advance. The
/// per-row controls reflect each permission's effective sub-state (with a
/// DEBUG dev-panel pin override per row), but the Continue gate reads the
/// LIVE `permissions.*` values so a pin can't let a tester past the real
/// gate.
struct PermissionsStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.dismissWindow) private var dismissWindow

    #if DEBUG
    /// Canvas-only overrides keep visual state previews internally consistent
    /// without weakening the live production gate or mutating macOS TCC.
    private let previewContinueGate: Bool?
    private let previewScreenNeedsRelaunch: Bool?

    init(
        previewContinueGate: Bool? = nil,
        previewScreenNeedsRelaunch: Bool? = nil
    ) {
        self.previewContinueGate = previewContinueGate
        self.previewScreenNeedsRelaunch = previewScreenNeedsRelaunch
    }
    #else
    init() { }
    #endif

    /// Per-row display state honors the DEBUG dev-panel pin so each
    /// sub-state can be previewed without toggling system permissions.
    private var effectiveScreen: PermissionStatus {
        onboarding.pinnedScreenSubState ?? permissions.screenRecordingStatus
    }

    private var effectiveMic: PermissionStatus {
        onboarding.pinnedMicSubState ?? permissions.microphoneStatus
    }

    /// M1: the "granted in Settings but not live in this process" recovery
    /// path. Takes priority over the tri-state for the Screen Recording row
    /// so the user is offered a Relaunch affordance instead of a "denied"
    /// row that contradicts their System Settings toggle. Suppressed while a
    /// dev pin is active so the panel can still inspect the base tri-state.
    private var screenNeedsRelaunch: Bool {
        #if DEBUG
        if let previewScreenNeedsRelaunch { return previewScreenNeedsRelaunch }
        #endif
        return onboarding.pinnedScreenSubState == nil &&
            permissions.screenRecordingNeedsRelaunch
    }

    /// Continue is gated on the LIVE OS values (never the dev pins) so a
    /// pinned sub-state can't let a tester advance past the real gate —
    /// matches the prior per-step production behavior.
    ///
    /// Also blocks while `screenRecordingNeedsRelaunch`: in that state
    /// `CGPreflightScreenCaptureAccess()` reads `.granted` even though live
    /// capture fails until the app is relaunched, so without this check
    /// Continue would enable while the Screen Recording row still shows the
    /// "Relaunch Zerro" affordance — letting a user finish onboarding into a
    /// state where their first recording fails.
    private var bothGranted: Bool {
        #if DEBUG
        if let previewContinueGate { return previewContinueGate }
        #endif
        return OnboardingPermissionsPolicy.canContinue(
            screenStatus: permissions.screenRecordingStatus,
            microphoneStatus: permissions.microphoneStatus,
            screenNeedsRelaunch: permissions.screenRecordingNeedsRelaunch
        )
    }

    private var screenPresentationState: OnboardingPermissionPresentationState {
        OnboardingPermissionsPolicy.presentationState(
            for: effectiveScreen,
            needsRelaunch: screenNeedsRelaunch
        )
    }

    private var microphonePresentationState: OnboardingPermissionPresentationState {
        OnboardingPermissionsPolicy.presentationState(for: effectiveMic)
    }

    /// Re-keys the polling `.task` whenever either effective status changes,
    /// so an out-of-band System Settings toggle flips the row within ~1s.
    private var pollKey: PollKey {
        PollKey(screen: effectiveScreen, mic: effectiveMic)
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            OnboardingSetupHero(
                systemName: "viewfinder",
                title: "Allow Zerro to see and hear",
                description: "These permissions are used only when you start a recording. Zerro stays quiet in your menu bar the rest of the time."
            )

            VStack(spacing: 10) {
                screenRow
                micRow
            }

            PermissionPrivacyNote()

            OnboardingPrimaryButton(
                onboarding.hasCompletedOnboarding ? "Done" : "Continue",
                systemImage: onboarding.hasCompletedOnboarding ? nil : "arrow.right",
                isEnabled: bothGranted
            ) {
                continueFromPermissions()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.xxl)
        // Single combined poller: poll iff either row is denied, so two
        // callers can't fight over the one shared timer. Re-runs on every
        // status transition via `pollKey`; stops when neither row is denied
        // and on disappear.
        .task(id: pollKey) {
            let needsPolling = effectiveScreen == .denied || effectiveMic == .denied
            if needsPolling { permissions.startPolling() } else { permissions.stopPolling() }
        }
        .onDisappear { permissions.stopPolling() }
    }

    // MARK: Rows

    private var screenRow: some View {
        PermissionRow(
            systemName: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            description: screenDescription,
            state: screenPresentationState
        ) {
            screenControl
        }
    }

    private var micRow: some View {
        PermissionRow(
            systemName: "mic.fill",
            title: "Microphone",
            description: microphoneDescription,
            state: microphonePresentationState
        ) {
            micControl
        }
    }

    private var screenDescription: String {
        switch screenPresentationState {
        case .request, .granted:
            return "Captures only the area you choose."
        case .denied:
            return "Turn this on in System Settings, then check again."
        case .needsRelaunch:
            return "Permission is on. Relaunch Zerro to apply it."
        }
    }

    private var microphoneDescription: String {
        switch microphonePresentationState {
        case .request, .granted:
            return "Hears the explanation you narrate."
        case .denied:
            return "Turn this on in System Settings, then check again."
        case .needsRelaunch:
            // Microphone never enters this state, but keeping the mapping
            // exhaustive makes the row safe if the policy grows later.
            return "Relaunch Zerro to apply this permission."
        }
    }

    // MARK: Trailing controls

    @ViewBuilder
    private var screenControl: some View {
        switch screenPresentationState {
        case .needsRelaunch:
            PermissionActionStack {
                PermissionMiniButton("Relaunch Zerro", prominent: true) {
                    permissions.relaunchToApplyScreenRecording()
                }
                PermissionMiniButton("Check again") {
                    Task { await permissions.probeScreenRecordingEffectiveness() }
                }
            }
        case .request:
            PermissionAllowButton { permissions.requestScreenRecording() }
        case .granted:
            PermissionGrantedIndicator()
        case .denied:
            PermissionActionStack {
                PermissionMiniButton("Open Settings", prominent: true) {
                    NSWorkspace.shared.open(SystemSettingsURLs.screenRecording)
                }
                // This live probe distinguishes granted, denied, and the
                // macOS state that requires a process relaunch.
                PermissionMiniButton("Check again") {
                    Task { await permissions.probeScreenRecordingEffectiveness() }
                }
            }
        }
    }

    @ViewBuilder
    private var micControl: some View {
        switch microphonePresentationState {
        case .request:
            PermissionAllowButton { Task { await permissions.requestMicrophone() } }
        case .granted:
            PermissionGrantedIndicator()
        case .denied:
            PermissionActionStack {
                PermissionMiniButton("Open Settings", prominent: true) {
                    NSWorkspace.shared.open(SystemSettingsURLs.microphone)
                }
                PermissionMiniButton("Check again") { permissions.refreshStatuses() }
            }
        case .needsRelaunch:
            EmptyView()
        }
    }

    private func continueFromPermissions() {
        // A COMPLETED user lands here only through the record gate after a
        // permission is revoked. Return them to the app instead of replaying
        // the final onboarding route and completion side effects.
        if onboarding.hasCompletedOnboarding {
            if onboarding.needsConsent {
                onboarding.beginReconsent()
            } else {
                dismissWindow(id: OnboardingScene.windowID)
            }
        } else {
            onboarding.advance()
        }
    }

    /// Equatable key for `.task(id:)` — `PermissionStatus` is Equatable, so a
    /// struct of the two effective statuses re-runs the poller on any
    /// transition. (`.task(id:)` only requires Equatable, not Hashable.)
    private struct PollKey: Equatable {
        let screen: PermissionStatus
        let mic: PermissionStatus
    }
}

// MARK: - Permission row + controls

/// A single permission row: icon tile, title, one-line description, and a
/// trailing control reflecting that permission's effective sub-state.
private struct PermissionRow<Trailing: View>: View {
    let systemName: String
    let title: String
    let description: String
    let state: OnboardingPermissionPresentationState
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.vfTextPrimary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: VFSpacing.sm)

            trailing()
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, VFSpacing.md)
        .frame(minHeight: 70)
        .background(Color.vfCardBackground, in: RoundedRectangle(cornerRadius: VFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        switch state {
        case .request:
            return Color.vfHairline
        case .granted:
            return Color.vfSuccessGreen.opacity(0.2)
        case .denied:
            return Color.vfWarningAmber.opacity(0.32)
        case .needsRelaunch:
            return Color.vfBrandAccent.opacity(0.38)
        }
    }
}

/// The primary per-row "Allow" pill that triggers the OS permission request.
private struct PermissionAllowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Allow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vfOnBrand)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, 7)
                .background(Color.vfBrandAccent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The granted indicator shown once a permission has been allowed.
private struct PermissionGrantedIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.vfSuccessGreen)
            Text("Allowed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfSuccessGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.vfSuccessGreen.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionPrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.vfSuccessGreen)
                .padding(.top, 1)

            (
                Text("Local first. ")
                    .fontWeight(.semibold)
                    .foregroundColor(Color.vfTextPrimary)
                + Text("Screen images are prepared on this Mac, and detected secrets are redacted by default.")
                    .foregroundColor(Color.vfTextSecondary)
            )
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, 11)
        .background(
            Color.vfSuccessGreen.opacity(0.055),
            in: RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(Color.vfSuccessGreen.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Right-aligned vertical stack for the two-button denied / needs-relaunch
/// trailing controls.
private struct PermissionActionStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            content()
        }
    }
}

/// Compact trailing button used by the denied / needs-relaunch sub-states.
/// `prominent` styles the primary action (Open Settings / Relaunch) with the
/// brand fill; the secondary "Check again" uses the muted fill.
private struct PermissionMiniButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.vfOnBrand : Color.vfTextPrimary)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    prominent ? Color.vfBrandAccent : Color.white.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dev Mode (educational)

/// Purely informational step shown to every user just before All Set.
/// Introduces Dev Mode at "what it is + where the switch is" depth — it does
/// NOT cover agent-CLI install or folder setup (those live in the selector's
/// dev-settings menu and Settings). No gating: shown to all users.
struct DevModeStepView: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingStepLayout {
            DevModeGlyphTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Building software? Try Dev Mode")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Normally Zerro copies a ready-to-paste result (a prompt, draft, snippet, or doc) to your clipboard. Use the Dev Mode shortcut and Zerro instead hands your narrated recording to a local coding agent, like Claude Code, that edits the files in your project for you.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            VStack(spacing: VFSpacing.sm) {
                DevModeShortcutIllustration()

                Text("You can change the Ask and Dev Mode shortcuts anytime in Settings → Shortcuts.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            OnboardingPrimaryButton("Continue") { onboarding.advance() }
        }
    }
}

/// Small icon tile for the Dev Mode concept.
private struct DevModeGlyphTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
            .fill(Color.vfDevAccent.opacity(0.14))
            .frame(width: 64, height: 64)
            .overlay(
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.vfDevAccent)
            )
    }
}

// MARK: - Dev Mode shortcut illustration

private struct DevModeShortcutIllustration: View {
    var body: some View {
        HStack(spacing: VFSpacing.sm) {
            OnboardingKeyCapLarge(label: "⌥")
            plus
            OnboardingKeyCapLarge(label: "⇧")
            plus
            OnboardingKeyCapLarge(label: "Space")
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Option Shift Space opens Dev Mode")
    }

    private var plus: some View {
        Text("+")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.vfTextTertiary)
    }
}

// MARK: - All Set

enum OnboardingReadyCopy {
    /// The ready line under the "You're ready." headline: the local 14-day
    /// trial, derived from `TrialManager`'s single source of truth so the
    /// copy can't drift from the clock the gate actually enforces.
    static var trialMessage: String {
        "Your \(TrialManager.trialLengthDays)-day free trial is ready."
    }
}

struct AllSetStepView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingStepLayout(spacing: VFSpacing.xxl) {
            OnboardingSuccessBadge()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("You\u{2019}re ready.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text(OnboardingReadyCopy.trialMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.vfSuccessGreen)
                    .multilineTextAlignment(.center)

                Text("Open Zerro\u{2019}s overlay and we\u{2019}ll guide you through your first capture. After that, use the shortcut anytime you want to show, speak, and get a result.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            VStack(spacing: VFSpacing.sm) {
                HStack(spacing: VFSpacing.sm) {
                    OnboardingKeyCapLarge(label: "\u{2325}")
                    Text("+")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.vfTextTertiary)
                    OnboardingKeyCapLarge(label: "Space")
                }

                Text("Your Zerro shortcut, anytime")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextTertiary)
            }
        } actions: {
            OnboardingPrimaryButton("Try Zerro now", systemImage: "arrow.right") {
                OnboardingCompletionHandoff.perform(
                    complete: { onboarding.completeOnboarding() },
                    dismiss: { dismissWindow(id: OnboardingScene.windowID) },
                    openOverlay: { AppDelegate.openAreaSelector() }
                )
            }
            .frame(maxWidth: 360)
        }
    }

}

private struct OnboardingSuccessBadge: View {
    var body: some View {
        Circle()
            .fill(Color.vfSuccessGreen.opacity(0.14))
            .frame(width: 58, height: 58)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.vfSuccessGreen)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.vfSuccessGreen.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.vfSuccessGreen.opacity(0.12), radius: 21)
            .accessibilityHidden(true)
    }
}

// MARK: - Shared layout

/// Vertically-centered step layout: optional icon header, content block,
/// and an actions block at the bottom. The three slots are stacked with
/// generous spacing and flanked by flexible spacers so each step sits
/// centered in the card regardless of how tall its content is.
struct OnboardingStepLayout<Icon: View, Content: View, Accessory: View, Actions: View>: View {
    let spacing: CGFloat
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var actions: () -> Actions

    init(
        spacing: CGFloat = VFSpacing.xl,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.spacing = spacing
        self.icon = icon
        self.content = content
        self.accessory = accessory
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: spacing) {
            Spacer(minLength: 0)

            icon()

            content()
                .padding(.horizontal, VFSpacing.xxl)

            accessory()
                .padding(.horizontal, VFSpacing.xxl)

            VStack(spacing: VFSpacing.sm) {
                actions()
            }
            .padding(.horizontal, VFSpacing.xxl)

            Spacer(minLength: 0)
        }
    }
}

/// Centered title + body text block shared by the icon-less steps.
struct OnboardingHeadline: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(spacing: VFSpacing.md) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.vfTextPrimary)
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(.system(size: 14))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Icon tiles

/// Large black rounded-square tile carrying the white-tinted brand glyph.
/// Used as the brand hero icon on onboarding-adjacent setup surfaces.
struct OnboardingLogoTile: View {
    var size: CGFloat = 80

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.vfOnBrand)
            .frame(width: size, height: size)
            .overlay(
                Image("MenuBarLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Dark elevated tile carrying an SF Symbol — used for the API-key step.
struct OnboardingIconTile: View {
    let systemName: String
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.vfCardBackground)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 1)
            )
    }
}

/// Large keycap used for the ⌥Space hint on the All Set step.
struct OnboardingKeyCapLarge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.vfTextPrimary)
            .padding(.horizontal, 14)
            .frame(minWidth: 48, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .fill(Color.vfControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

struct OnboardingPrimaryButton: View {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let tint: Color
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        tint: Color = .vfBrandAccent,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.vfOnBrand : Color.white.opacity(0.50))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                (isEnabled ? tint : Color.white.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: VFRadius.lg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                    .strokeBorder(
                        isEnabled ? Color.clear : Color.white.opacity(0.09),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.vfTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: VFRadius.lg))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG

// MARK: - Canvas previews

#Preview("1 · Welcome") {
    OnboardingPreviewHost(step: .welcome) {
        WelcomeStepView()
    }
}

#Preview("2 · Terms & Privacy") {
    OnboardingPreviewHost(step: .consent) {
        ConsentStepView()
    }
}

#Preview("4 · Permissions · Request") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .notDetermined,
        microphoneStatus: .notDetermined
    ) {
        PermissionsStepView(previewContinueGate: false)
    }
}

#Preview("4 · Permissions · Denied") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .denied,
        microphoneStatus: .granted
    ) {
        PermissionsStepView(previewContinueGate: false)
    }
}

#Preview("4 · Permissions · Allowed") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .granted,
        microphoneStatus: .granted
    ) {
        PermissionsStepView(previewContinueGate: true)
    }
}

#Preview("4 · Permissions · Relaunch") {
    OnboardingPreviewHost(
        step: .permissions,
        screenStatus: .granted,
        microphoneStatus: .granted
    ) {
        PermissionsStepView(
            previewContinueGate: false,
            previewScreenNeedsRelaunch: true
        )
    }
}

#Preview("Legacy · Dev Mode") {
    OnboardingPreviewHost(step: .devMode) {
        DevModeStepView()
    }
}

#Preview("Complete") {
    OnboardingPreviewHost(step: .allSet) {
        AllSetStepView()
    }
}

#endif
