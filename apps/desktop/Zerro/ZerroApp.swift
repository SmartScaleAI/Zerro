//
//  ZerroApp.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct ZerroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState: AppState
    @State private var preferences: PreferencesStore
    @State private var permissions: PermissionsManager
    @State private var onboarding: OnboardingState
    @State private var pillController: PillWindowController
    @State private var recordingFocusController: RecordingFocusWindowController
    @State private var areaSelectorController: AreaSelectorWindowController

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
        let prefs = PreferencesStore()
        let perms = PermissionsManager()
        let onb = OnboardingState()
        let selectorCtrl = AreaSelectorWindowController()
        _appState = State(initialValue: state)
        _preferences = State(initialValue: prefs)
        _permissions = State(initialValue: perms)
        _onboarding = State(initialValue: onb)
        _pillController = State(initialValue: PillWindowController(appState: state))
        _recordingFocusController = State(initialValue: RecordingFocusWindowController(appState: state))
        _areaSelectorController = State(initialValue: selectorCtrl)

        // Tell the AppDelegate whether to bring the onboarding window
        // forward post-launch. `.defaultLaunchBehavior(.presented)`
        // ensures the window is INSTANTIATED at launch; the AppDelegate
        // calls NSApp.activate so the window actually comes to front in
        // an .accessory-activation-policy app.
        AppDelegate.shouldPresentOnboardingOnLaunch = !onb.hasCompletedOnboarding

        // Register the global hotkey exactly once. Captures the long-
        // lived instances weakly — @State keeps them alive for the
        // app's lifetime, so weak references stay valid.
        if !Self.didRegisterGlobalShortcuts {
            Self.didRegisterGlobalShortcuts = true
            KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak state, weak prefs, weak perms, weak onb, weak selectorCtrl] in
                Self.handleHotkey(
                    state: state,
                    preferences: prefs,
                    permissions: perms,
                    onboarding: onb,
                    areaSelector: selectorCtrl
                )
            }
            // Phase 8 launch-sweep: clear orphaned zerro-*
            // recordings and working dirs from prior crashes / force-
            // quits. Runs in this one-shot block (NOT App.init body,
            // which SwiftUI may re-invoke). Safe to run before any
            // new artifact is created — anything alive in the current
            // run is constructed after this returns.
            WorkingDirectory.sweep()
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
            // OnboardingOpenerRegistrar is a zero-size sibling whose
            // only job is to capture SwiftUI's `openWindow` environment
            // action into AppDelegate.requestOpenOnboarding *as soon
            // as the app launches*. The MenuBarExtra label is the only
            // always-mounted View in this app — Window scenes only
            // mount their content when the window is on screen, and
            // MenuBarExtra's dropdown content only mounts when opened.
            // Without this, the hotkey can't re-open onboarding once
            // the user has dismissed it, because the closure that was
            // previously captured in OnboardingWindowView.onAppear is
            // never reset on later launches when `hasCompletedOnboarding`
            // suppresses auto-presentation.
            OnboardingOpenerRegistrar()
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
        Window("Zerro \u{2014} Setup", id: OnboardingScene.windowID) {
            OnboardingWindowView()
                .environment(permissions)
                .environment(onboarding)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(onboarding.hasCompletedOnboarding ? .automatic : .presented)
    }

    // MARK: - Hotkey gating

    /// Decides what the global hotkey does given the current state. The
    /// hotkey is a true toggle, so two outcomes short-circuit before any
    /// setup gating (those gates are about STARTING, not stopping):
    ///   0a. A recording is active — stop it (→ processing). Runs even if
    ///       a permission was revoked mid-session; you must always be able
    ///       to stop.
    ///   0b. Processing is in flight — ignore. The record hotkey must not
    ///       interrupt local/API work; the pill's Cancel is that affordance.
    /// Otherwise (idle / done / failed) the start flow, in priority order:
    ///   1. Onboarding incomplete — bring onboarding forward (any step).
    ///   2. Onboarding complete but a required permission is no longer
    ///      .granted — bring onboarding forward, jumped to the relevant
    ///      step so the System Settings deep link is immediately
    ///      reachable. DEFERRED: replace with a brief non-blocking
    ///      notification once UNUserNotification permission infra exists.
    ///   3. All gates satisfied — present the area-selector overlay.
    ///      Recording does NOT start here; it starts on confirm via
    ///      the selector's callback (Phase 6 wiring). From a visible
    ///      result/error (done/failed) the confirm callback resets to
    ///      idle first so a new recording can begin.
    @MainActor
    private static func handleHotkey(
        state: AppState?,
        preferences: PreferencesStore?,
        permissions: PermissionsManager?,
        onboarding: OnboardingState?,
        areaSelector: AreaSelectorWindowController?
    ) {
        guard let state, let preferences, let permissions, let onboarding, let areaSelector else {
            NSLog("[Hotkey] dropped — one of state/preferences/permissions/onboarding/areaSelector was nil")
            return
        }

        NSLog("[Hotkey] fired — hasCompletedOnboarding=%@", onboarding.hasCompletedOnboarding ? "Y" : "N")

        // 0a. Active recording — stop it. Runs before any setup gate
        // because you must always be able to stop, even if a permission
        // was revoked mid-session.
        if state.isRecordingActive {
            NSLog("[Hotkey] active recording — stopping (toggle)")
            state.stopRecording()
            return
        }
        // 0b. Processing in flight — ignore. The record hotkey must not
        // interrupt local/API work; the pill's Cancel is that affordance.
        if state.state == .processing {
            NSLog("[Hotkey] processing in flight — ignoring hotkey")
            return
        }

        if !onboarding.hasCompletedOnboarding {
            NSLog("[Hotkey] gating: onboarding incomplete — opening onboarding")
            AppDelegate.openOnboarding()
            return
        }

        // Re-read live OS state in case a permission was revoked while
        // the app was running. We only treat Screen Recording + Mic as
        // gating; Accessibility is informational per Checkpoint 3.
        permissions.refreshStatuses()
        NSLog("[Hotkey] permission statuses — screen=%@ mic=%@ accessibility=%@",
              String(describing: permissions.screenRecordingStatus),
              String(describing: permissions.microphoneStatus),
              String(describing: permissions.accessibilityStatus))

        if permissions.screenRecordingStatus != .granted {
            NSLog("[Hotkey] gating: screen recording not granted — opening onboarding @ screenRecording")
            onboarding.jump(to: .screenRecording)
            AppDelegate.openOnboarding()
            return
        }
        if permissions.microphoneStatus != .granted {
            NSLog("[Hotkey] gating: microphone not granted — opening onboarding @ microphone")
            onboarding.jump(to: .microphone)
            AppDelegate.openOnboarding()
            return
        }

        NSLog("[Hotkey] all gates passed — presenting area selector")

        // hotkey → area selector → (on confirm) → startRecording(selection:mic:)
        // Mic device is read fresh from preferences at confirm time so a
        // Settings change between recordings takes effect on the next one
        // without restarting the app.
        areaSelector.present(
            preferences: preferences,
            onConfirm: { [weak state, weak preferences] selection in
                guard let state else { return }
                // From a visible result/error (done/failed) reset to idle
                // first so startRecording's `guard state == .idle` passes
                // and a new recording can begin.
                if state.state != .idle {
                    state.resetToIdle()
                }
                state.startRecording(
                    selection: selection,
                    microphoneDeviceID: preferences?.microphoneDeviceID ?? ""
                )
            },
            onCancel: {
                // No-op: ESC simply dismisses the overlay; the user
                // returns to whatever they were doing.
            }
        )
    }
}

// MARK: - AppDelegate

/// Thin AppKit bridge for window activation, since `MenuBarExtra` apps
/// run with `.accessory` activation policy and SwiftUI windows don't
/// come to front on their own. Holds a static handle to the onboarding
/// window's openWindow action, populated by `OnboardingWindowView`
/// when it appears.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `ZerroApp.init` based on the persisted
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
        if let opener = requestOpenOnboarding {
            opener()
        } else {
            // Should be impossible once OnboardingOpenerRegistrar
            // captures `openWindow` at launch, but log loudly if it
            // ever happens — this exact silent-no-op was the bug that
            // made hotkey presses look like they did nothing.
            NSLog("[Onboarding] openOnboarding() called but requestOpenOnboarding is nil — registrar didn't mount")
        }
    }
}

// MARK: - OnboardingOpenerRegistrar
//
// Zero-size helper view whose only job is to capture the SwiftUI
// `openWindow` environment action into AppDelegate.requestOpenOnboarding
// at app launch. Lives inside the MenuBarExtra label (the only
// always-mounted View) so the closure is available before the user
// ever interacts with anything. See ZerroApp.body for why this
// matters.

private struct OnboardingOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.requestOpenOnboarding = {
                    openWindow(id: OnboardingScene.windowID)
                }
            }
    }
}
