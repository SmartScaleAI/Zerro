//
//  VisualFlowAIApp.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct VisualFlowAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState: AppState
    @State private var preferences: PreferencesStore
    @State private var permissions: PermissionsManager
    @State private var onboarding: OnboardingState
    @State private var pillController: PillWindowController

    /// Guard so the hotkey handler is appended to the library's handler
    /// list exactly once across the app's lifetime. SwiftUI re-invokes
    /// `App.init` whenever it re-evaluates the App struct (for example,
    /// when the MenuBarExtra reconciles), and on those re-inits the
    /// `@State(initialValue:)` is discarded — the persisted AppState
    /// stays in the @State storage box from the very first init, while
    /// each re-init builds a throwaway AppState that nothing retains.
    /// Without this guard, every re-init would APPEND a new handler
    /// capturing a soon-dead instance (`KeyboardShortcuts.onKeyDown`
    /// appends rather than replaces), and the only handler still bound
    /// to the live state would be the original — which itself gets
    /// drowned out by the dead ones in practice.
    private static var didRegisterGlobalShortcuts = false

    init() {
        let state = AppState()
        let perms = PermissionsManager()
        let onb = OnboardingState()
        _appState = State(initialValue: state)
        _preferences = State(initialValue: PreferencesStore())
        _permissions = State(initialValue: perms)
        _onboarding = State(initialValue: onb)
        _pillController = State(initialValue: PillWindowController(appState: state))

        // Tell the AppDelegate whether to bring the onboarding window
        // forward post-launch. `.defaultLaunchBehavior(.presented)`
        // ensures the window is INSTANTIATED at launch; the AppDelegate
        // calls NSApp.activate so the window actually comes to front in
        // an .accessory-activation-policy app.
        AppDelegate.shouldPresentOnboardingOnLaunch = !onb.hasCompletedOnboarding

        // Register the global hotkey exactly once. Captures the three
        // long-lived instances weakly — @State keeps them alive for the
        // app's lifetime, so weak references stay valid.
        if !Self.didRegisterGlobalShortcuts {
            Self.didRegisterGlobalShortcuts = true
            KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak state, weak perms, weak onb] in
                Self.handleHotkey(state: state, permissions: perms, onboarding: onb)
            }
        }
    }

    var body: some Scene {
        // The AppState → PillWindowController bridge is owned by the
        // controller itself (see `startObservingAppState`), not by a
        // `.task` on this content view, so pill updates keep flowing
        // while the dropdown is closed and while the app is backgrounded.
        MenuBarExtra {
            MenuBarPanelView()
                .environment(appState)
                .environment(preferences)
                .environment(permissions)
                .environment(onboarding)
        } label: {
            MenuBarIconView(isRecording: appState.isRecordingActive)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(preferences)
                .environment(permissions)
        }

        // Single-instance onboarding window. `.defaultLaunchBehavior` is
        // computed from the persisted hasCompletedOnboarding flag at
        // app-init time; the AppDelegate handles NSApp.activate so the
        // window actually surfaces in front of other apps.
        Window("VisualFlow AI \u{2014} Setup", id: OnboardingScene.windowID) {
            OnboardingWindowView()
                .environment(permissions)
                .environment(onboarding)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(onboarding.hasCompletedOnboarding ? .automatic : .presented)
    }

    // MARK: - Hotkey gating

    /// Decides what the global hotkey does given the current setup
    /// state. Three outcomes, in priority order:
    ///   1. Onboarding incomplete — bring onboarding forward (any step).
    ///   2. Onboarding complete but a required permission is no longer
    ///      .granted — bring onboarding forward, jumped to the relevant
    ///      step so the System Settings deep link is immediately
    ///      reachable. DEFERRED: replace with a brief non-blocking
    ///      notification once UNUserNotification permission infra exists.
    ///   3. All gates satisfied — start the recording flow as usual.
    @MainActor
    private static func handleHotkey(
        state: AppState?,
        permissions: PermissionsManager?,
        onboarding: OnboardingState?
    ) {
        guard let state, let permissions, let onboarding else { return }

        if !onboarding.hasCompletedOnboarding {
            AppDelegate.openOnboarding()
            return
        }

        // Re-read live OS state in case a permission was revoked while
        // the app was running. We only treat Screen Recording + Mic as
        // gating; Accessibility is informational per Checkpoint 3.
        permissions.refreshStatuses()
        if permissions.screenRecordingStatus != .granted {
            onboarding.jump(to: .screenRecording)
            AppDelegate.openOnboarding()
            return
        }
        if permissions.microphoneStatus != .granted {
            onboarding.jump(to: .microphone)
            AppDelegate.openOnboarding()
            return
        }

        state.startRecording()
    }
}

// MARK: - AppDelegate

/// Thin AppKit bridge for window activation, since `MenuBarExtra` apps
/// run with `.accessory` activation policy and SwiftUI windows don't
/// come to front on their own. Holds a static handle to the onboarding
/// window's openWindow action, populated by `OnboardingWindowView`
/// when it appears.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `VisualFlowAIApp.init` based on the persisted
    /// `hasCompletedOnboarding` flag. Read once in
    /// `applicationDidFinishLaunching`.
    nonisolated(unsafe) static var shouldPresentOnboardingOnLaunch: Bool = false

    /// Set by `OnboardingWindowView.onAppear`. Used by `openOnboarding`
    /// to re-open the window from the hotkey handler when the user has
    /// closed it but onboarding is incomplete or a permission was
    /// revoked.
    nonisolated(unsafe) static var requestOpenOnboarding: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Window scene's .defaultLaunchBehavior(.presented) already
        // instantiates the onboarding window when needed. We just need
        // to bring the app forward so the window has key focus in an
        // .accessory-policy menu-bar app.
        if Self.shouldPresentOnboardingOnLaunch {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    static func openOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        requestOpenOnboarding?()
    }
}
