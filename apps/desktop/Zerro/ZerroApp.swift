//
//  ZerroApp.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import AppKit
import KeyboardShortcuts
import MetricKit
import os
import SwiftUI

@main
struct ZerroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appState: AppState
    @State private var preferences: PreferencesStore
    @State private var permissions: PermissionsManager
    @State private var onboarding: OnboardingState
    /// Phase A (billing): the entitlement source of truth. Long-lived like
    /// the other services — constructed in init, kept in @State for the
    /// app's lifetime, injected into the menu-bar content, Settings, and
    /// the Paywall window. The recording-start gate reads `canGenerate`.
    @State private var entitlements: EntitlementStore
    /// Phase F (billing): the server-funded trial-credits layer. Long-lived like
    /// the other services; shared between the entitlement layer (trial-credit
    /// display + token presence) and AppState (proxy token provider for a trial
    /// generation), and injected into the trial email-capture window.
    @State private var trialCredits: TrialCreditsManager
    @State private var recentPrompts: RecentPromptStore
    @State private var launchAtLogin: LaunchAtLoginController
    @State private var pillController: PillWindowController
    @State private var recordingFocusController: RecordingFocusWindowController
    @State private var areaSelectorController: AreaSelectorWindowController
    /// Pulsing green screen-edge ring shown while a Dev Mode agent run is in
    /// progress. Self-observes `AppState.devRingActive`; owned here for the
    /// app's lifetime like the other overlay controllers.
    @State private var devRingController: DevRingWindowController
    /// Soft green glow drawn under the cursor while a Dev Mode recording is in
    /// progress (the system cursor itself is left untouched). Self-observes
    /// `AppState.devCursorActive`; owned here for the app's lifetime like the
    /// other overlay controllers.
    @State private var devCursorController: DevCursorWindowController

    /// MetricKit → PostHog bridge for crash/hang/exception diagnostics. Held
    /// for the app's lifetime because `MXMetricManager` keeps only a weak
    /// reference to its subscribers; registered in the one-shot bootstrap block
    /// alongside `CrashReporting.start()`.
    @State private var metricKitObserver: MetricKitObserver

    /// Phase 14 / C3.4: Sparkle updater. Must live for the full app
    /// session — owning it inside the MenuBarExtra content closure
    /// would tear down `SPUStandardUpdaterController` every time the
    /// dropdown closes, killing automatic update checks and any
    /// in-flight download UI (Phase 4 lifetime learning).
    @StateObject private var updater = UpdaterViewModel()

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

    /// True when the process is hosting a SwiftUI `#Preview`, not a real
    /// launch. Xcode sets `XCODE_RUNNING_FOR_PREVIEWS=1` in the preview
    /// agent's environment. The `@main` App is still instantiated to host a
    /// preview, so its `init` runs — but the launch-time bootstrap below
    /// (global-hotkey registration, working-dir sweeps, the wake observer,
    /// and the network refresh Tasks) is preview-hostile: it's what makes the
    /// canvas spin and then fail with `AppLaunchTimeoutError`. Skip it under
    /// previews; the long-lived services are still constructed above (cheap,
    /// synchronous Keychain reads) so any view's preview renders normally.
    static var isRunningInXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    init() {
        let state = AppState()
        let prefs = PreferencesStore()
        let perms = PermissionsManager()
        let onb = OnboardingState()
        // Phase E (billing): one shared session-token manager backs BOTH the
        // entitlement layer (license→session probe + display refresh) and the
        // Managed generation proxy, so they share one cached token.
        let sessionTokens = SessionTokenManager()
        let managedProxy = ManagedProxyClient(sessionTokens: sessionTokens)
        // Phase F: the trial-credits layer is shared by the entitlement store and
        // AppState (it's the proxy token provider for a trial generation).
        let trial = TrialCreditsManager()
        let ent = EntitlementStore(sessionTokens: sessionTokens, trialCredits: trial)
        let history = RecentPromptStore()
        let launch = LaunchAtLoginController()
        let metricObserver = MetricKitObserver()
        let selectorCtrl = AreaSelectorWindowController()
        let pillCtrl = PillWindowController(appState: state)
        // Phase 10: let AppState start/stop TCC monitoring around an
        // active recording so a mid-session revocation lands the user on
        // the dedicated failure pill within ~1s. Weak ref — both objects
        // live in @State for the app's lifetime.
        state.permissions = perms
        // Phase 11: same lifetime contract, same weak-ref pattern. The
        // AppState pipeline writes to the store after a successful prompt
        // generation; the menu-bar surfaces + Settings tab read from it
        // via the SwiftUI environment.
        state.recentPromptStore = history
        // Phase E: the generation pipeline's routing branch reads these to
        // decide local-BYOK vs Managed-proxy. Same lifetime + weak/owned
        // contract as the refs above.
        state.entitlements = ent
        state.managedProxyClient = managedProxy
        // Phase F: the trial token provider + trial-credit bookkeeping.
        state.trialCredits = trial
        // Phase 6 (multi-model): the proxy generation path reads the picker's
        // selected model from prefs fresh at request time (same lifetime +
        // weak-ref contract as the refs above; prefs lives in @State below).
        state.preferences = prefs
        _appState = State(initialValue: state)
        _preferences = State(initialValue: prefs)
        _permissions = State(initialValue: perms)
        _onboarding = State(initialValue: onb)
        _entitlements = State(initialValue: ent)
        _trialCredits = State(initialValue: trial)
        _recentPrompts = State(initialValue: history)
        _launchAtLogin = State(initialValue: launch)
        _metricKitObserver = State(initialValue: metricObserver)
        _pillController = State(initialValue: pillCtrl)
        _recordingFocusController = State(initialValue: RecordingFocusWindowController(appState: state))
        _areaSelectorController = State(initialValue: selectorCtrl)
        _devRingController = State(initialValue: DevRingWindowController(appState: state, preferences: prefs))
        _devCursorController = State(initialValue: DevCursorWindowController(appState: state, preferences: prefs))

        // Tell the AppDelegate whether to bring the onboarding window
        // forward post-launch. `.defaultLaunchBehavior(.presented)`
        // ensures the window is INSTANTIATED at launch; the AppDelegate
        // calls NSApp.activate so the window actually comes to front in
        // an .accessory-activation-policy app.
        // Phase 22: also present onboarding when a finished user owes fresh
        // consent (stale Terms version) so the consent screen re-papers them.
        AppDelegate.shouldPresentOnboardingOnLaunch = onb.shouldPresentOnboardingOnLaunch

        // Register the global hotkey exactly once. Captures the long-
        // lived instances weakly — @State keeps them alive for the
        // app's lifetime, so weak references stay valid.
        if !Self.didRegisterGlobalShortcuts && !Self.isRunningInXcodePreview {
            Self.didRegisterGlobalShortcuts = true
            // Phase 13 (Part B): bring up analytics + error tracking FIRST inside the
            // one-shot block so the crash reporter is live before any
            // launch-time work below (the working-dir sweep, the
            // hotkey closure capture) can fault. CrashReporting.start
            // is itself idempotent against re-entry, but this guard
            // already ensures the file-system sweep below runs only
            // once across SwiftUI's re-invocations of App.init, so we
            // get the right one-shot semantics for free.
            CrashReporting.start()
            // Subscribe to MetricKit so genuine crash/hang/CPU/disk-write
            // diagnostics (the detail PostHog's bare-SIGTRAP autocapture misses)
            // are forwarded into PostHog. `metricObserver` is retained for the
            // app's lifetime by the @State above — MXMetricManager keeps only a
            // weak reference. Inside this one-shot, preview-gated block so it
            // registers exactly once and never during a #Preview launch.
            MXMetricManager.shared.add(metricObserver)
            // Tier 1 analytics: seed the entitlement super-properties from the
            // resolved launch state so EVERY event this session carries
            // monetization context. The EntitlementStore.state didSet keeps them
            // live thereafter; this initial push is needed because that didSet
            // doesn't fire for the value computed in EntitlementStore.init.
            Analytics.updateEntitlementProperties(ent.state)
            // Phase 13A: anchor breadcrumb. Every subsequent breadcrumb
            // (state transitions, pipeline stages, permission changes)
            // accumulates AFTER this one in the local breadcrumb trail, so
            // any crash report shows a clean "app launched → ..." lead.
            Log.breadcrumb(category: .appLifecycle, message: "app launched")
            #if DEBUG
            // Phase F: log the trial email Keychain slot disposition at launch
            // (found/absent/failure, no values) so the reinstall-persistence of
            // the server-funded grant is observable without a debugger. See the
            // KeychainStore header.
            KeychainStore.debugLogTrialSlotDisposition()
            #endif
            KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak state, weak prefs, weak perms, weak onb, weak ent, weak selectorCtrl, weak pillCtrl] in
                Self.handleHotkey(
                    state: state,
                    preferences: prefs,
                    permissions: perms,
                    onboarding: onb,
                    entitlements: ent,
                    areaSelector: selectorCtrl,
                    pillController: pillCtrl
                )
            }
            // Phase 8 launch-sweep + M2 recovery: clear orphaned zerro-*
            // artifacts from prior crashes / force-quits, BUT first salvage a
            // recording a prior session abandoned for sleep —
            // RecordingSession.abandon leaves a fragmented .mov on disk
            // WITHOUT finalizing it (an interrupted finishWriting would corrupt
            // it), so it's recoverable instead of junk. recoverOrphanedRecording
            // IfAny OFFERS the survivor (rev 3 — asks before generating, never
            // auto-spends a credit) and sweeps the rest, or falls back to the
            // blanket sweep when there's nothing recoverable. Runs in this
            // one-shot block (NOT App.init body, which SwiftUI may re-invoke);
            // single-instance, so any orphan here is from a prior session,
            // never a live file.
            // M1: hand the live AppState to the AppDelegate so
            // applicationShouldTerminate can route a quit (abandon an in-flight
            // recording for recovery / clean an in-flight generation). Set here
            // in the one-shot block — `state` is the retained instance only on
            // the first init.
            AppDelegate.appState = state
            // Billing entry-point work: hand the long-lived entitlement store to
            // the AppDelegate so the `zerro://` checkout-return deep link and the
            // app-activation refresh can reach it (both live outside the SwiftUI
            // view tree). Weak (like `appState`), set only in this one-shot block.
            AppDelegate.entitlements = ent
            // Cold-launch checkout return: if a `zerro://checkout-complete` deep
            // link arrived before this wiring (clicking "Return to Zerro" can beat
            // scene mount on a cold launch), `handleCheckoutReturn` buffered it —
            // replay it now that the store is reachable, then clear it.
            AppDelegate.replayPendingCheckoutURLIfNeeded()
            // Wire onboarding gating for recovery (AppState owns the recovery
            // logic + the wake observer but not the OnboardingStore).
            state.onboardingCompleteProvider = { [weak onb] in
                onb?.hasCompletedOnboarding ?? false
            }
            // The error pill's "Retry" (when there's nothing to re-run on disk)
            // reopens the screen-region overlay — route it through the same
            // gated hotkey flow the global shortcut + menu use, so it re-checks
            // permissions/entitlement before presenting the selector.
            state.requestAreaSelector = { [weak state, weak prefs, weak perms, weak onb, weak ent, weak selectorCtrl, weak pillCtrl] in
                Self.handleHotkey(
                    state: state,
                    preferences: prefs,
                    permissions: perms,
                    onboarding: onb,
                    entitlements: ent,
                    areaSelector: selectorCtrl,
                    pillController: pillCtrl
                )
            }
            // M2 (rev 3): recover on WAKE too — the common lid-close case
            // survives sleep and never relaunches, so a launch-only check would
            // never surface it. App-lifetime observer, registered once here.
            state.startWakeRecoveryObserver()
            // M5 (resume after purchase): BEFORE the blanket launch sweep,
            // restore a paid-blocked recording the user was holding across a
            // quit-during-checkout. If one is restored, AppState re-enters
            // `.failed` with the recording loaded so the pill returns with a
            // Continue button; the marker in its working dir keeps the launch
            // sweep from reclaiming it. Stale/missing/corrupt records are cleared
            // here. Synchronous + on MainActor so state is set before the
            // recovery task below runs (which no-ops when state isn't `.idle`).
            state.restorePendingPaidGenerationIfAny()
            // Launch recovery still covers crash / force-quit / relaunch (where
            // the app actually exited). Both paths OFFER (ask before
            // generating); neither auto-spends a credit.
            //
            // Dev Mode quit-recovery runs FIRST — it restores real source files
            // (higher stakes) than re-offering a recording. If it makes an offer,
            // skip the recording scan this launch (the recording orphan re-offers
            // next launch); otherwise fall through to the unchanged recording
            // recovery.
            Task { @MainActor [weak state] in
                let offeredDevRecovery = await state?.recoverInterruptedDevCheckpointIfAny() ?? false
                // Launch-only reclaim of orphaned Dev Mode temp dirs (a hard crash
                // at the review gate, or a leaked throwaway index). Runs AFTER
                // recovery has loaded (and possibly cleared) the marker, so it
                // spares the one snapshot a surviving offer still needs and can't
                // race that offer. Launch-only by construction — the wake observer
                // never calls dev-checkpoint recovery.
                state?.sweepOrphanedDevSnapshots()
                guard !offeredDevRecovery else { return }
                await state?.recoverOrphanedRecordingIfAny(trigger: .launch)
            }

            // Dev Mode (Phase 1): for a returning Dev Mode user, warm agent
            // detection now (background) so the agent chip is resolved by the
            // time they open the overlay — no "checking" flicker. Gated on the
            // persisted toggle so normal-mode users never spawn the shell probe.
            if prefs.devModeEnabled {
                DevAgentDetection.shared.warm()
                // Phase 2: refresh the server-fetched model manifest (cache→disk)
                // so the dev-settings Model section shows the current pinned list.
                // Fail-open: offline keeps the cached/bundled list, never empty.
                Task { await AgentModelManifestStore.shared.warm() }
            }

            // Phase C: throttled background re-validation of a cached BYOK
            // license. No-ops unless a license is present AND the ~weekly
            // throttle window has elapsed, so it's offline-first and never
            // blocks launch (the synchronous `computeState` already decided
            // `.byok`). Catches refunds/revocations; fails open on any network
            // hiccup. Captures the long-lived store weakly (it lives in @State
            // for the app's lifetime).
            Task { @MainActor [weak ent] in
                await ent?.revalidateLicenseIfNeeded()
            }

            // Phase E: refresh the Managed credit/status snapshot at launch so
            // the menu-bar credits line + any past-due nudge are current. No-ops
            // unless the user is `.managed`; fails open (keeps the cached
            // snapshot) on any network hiccup, so it never blocks launch.
            Task { @MainActor [weak ent] in
                await ent?.refreshManagedEntitlement()
            }
        }
    }

    var body: some Scene {
        // The AppState → PillWindowController bridge is owned by the
        // controller itself (see `startObservingAppState`), not by a
        // `.task` on this content view, so pill updates keep flowing
        // while the dropdown is closed and while the app is backgrounded.
        MenuBarExtra {
            MenuBarPanelView(
                // Menu "Start Recording" runs the same path as the global
                // hotkey: present the area selector first (gated on
                // onboarding / permissions), record on confirm.
                onStartRecording: {
                    Self.handleHotkey(
                        state: appState,
                        preferences: preferences,
                        permissions: permissions,
                        onboarding: onboarding,
                        entitlements: entitlements,
                        areaSelector: areaSelectorController,
                        pillController: pillController
                    )
                }
            )
                .environment(appState)
                .environment(preferences)
                .environment(permissions)
                .environment(onboarding)
                .environment(entitlements)
                .environment(recentPrompts)
                .environmentObject(updater)
        } label: {
            // macOS 26.5 (Tahoe) SDK fix: the MenuBarExtra label must be a
            // SINGLE primary view. The previous multi-child label (three
            // zero-size opener registrars as siblings of the icon) caused
            // SwiftUI under the 26.5 SDK to fail to materialize the
            // MenuBarExtra scene — the status item neither rendered its icon
            // nor anchored the process, so the LSUIElement app terminated at
            // launch. The icon is now the sole label child; the openWindow
            // registrars ride along as zero-size `.background` content (still
            // always-mounted, so their `.onAppear` capture of `openWindow`
            // into the AppDelegate fires exactly as before — see each
            // registrar's onAppear), without making the label a composite.
            MenuBarIconView(isRecording: appState.isRecordingActive)
                .background(OnboardingOpenerRegistrar())
                .background(PaywallOpenerRegistrar())
                .background(TrialEmailOpenerRegistrar())
                .background(ActivateKeyOpenerRegistrar())
                .background(SettingsDismissRegistrar())
        }
        .menuBarExtraStyle(.window)

        // Activation anchor (root-cause fix for the spurious-Settings-window bug).
        //
        // AppKit auto-materializes the FIRST-declared `Window` scene whenever this
        // accessory (LSUIElement) app is brought to the foreground via an
        // activation — e.g. a `zerro://` checkout-return deep link reactivating it
        // from the browser. `.defaultLaunchBehavior(.suppressed)` only suppresses a
        // normal background launch, NOT this activation path, so whatever Window is
        // declared first pops on screen. The Settings window used to be first, which
        // is exactly how three windows (Settings + paywall + activate) ended up
        // visible after a purchase (confirmed via os_log: the Settings window
        // mounted on activation BEFORE the deep-link handler ran, and there was no
        // saved-state on disk — so it was scene materialization, not restoration).
        //
        // This invisible, suppressed window claims the first-scene slot so the
        // framework materializes nothing the user can see. It's fully transparent
        // (alpha 0), click-through, single-pixel, carries no Dock-icon visibility,
        // and is not a `qualifyingWindowID`, so it can never affect the policy flip
        // or be raised. It only ever materializes on the same activation that would
        // otherwise have popped Settings.
        Window("", id: ActivationAnchorScene.windowID) {
            Color.clear
                .frame(width: 1, height: 1)
                .disablesWindowRestoration()
                .background(WindowConfigurator { window in
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                    window.isExcludedFromWindowsMenu = true
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Phase 11 (revision 2): replaced the stock `Settings { ... }`
        // scene with a custom Window so the dark surface can bleed up
        // under the floating traffic-light buttons (Wispr Flow Hub
        // style). The `.hiddenTitleBar` style + the AppKit-level
        // properties applied by `applySettingsWindowChrome()` together
        // give us a chromeless surface with the traffic lights still
        // present for close/minimize/zoom.
        //
        // ⌘, binding: registered via `.appSettings` CommandGroup
        // below so the standard Settings keyboard shortcut continues
        // to work, and the menu-bar Preferences row routes through
        // openWindow(id:) too.
        //
        // The Recent Prompts window is intentionally NOT a separate
        // scene anymore — clicking that row inside Settings now swaps
        // the route in-window (see SettingsView's SettingsRoute enum).
        Window("Zerro Settings", id: SettingsScene.windowID) {
            SettingsView()
                // Dock icon while open (all four real windows carry this;
                // the pill/selector/menu-bar surfaces deliberately don't).
                .dockIconVisibility(windowID: SettingsScene.windowID)
                // Never restored on relaunch — AppKit clamp paired with the
                // scene's `.restorationBehavior(.disabled)` (see below).
                .disablesWindowRestoration()
                .environment(preferences)
                .environment(permissions)
                .environment(onboarding)
                // Phase A: makes the entitlement readable from Settings (a
                // Billing section lands in Phase C; injected now so it's
                // available without re-plumbing the scene later).
                .environment(entitlements)
                .environment(recentPrompts)
                .environment(launchAtLogin)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        // Round 5: explicit initial size. `idealWidth/idealHeight` on
        // SettingsView's `.frame()` isn't a reliable signal for
        // window-open sizing under `.hiddenTitleBar` +
        // `.contentSize` resizability — macOS will fall back to a
        // smaller default. `.defaultSize` is the SwiftUI-blessed
        // initial-size hint; the WindowConfigurator additionally
        // forces `setContentSize` every time the window mounts so a
        // user mid-session resize doesn't persist into the next open.
        .defaultSize(
            width: SettingsScene.preferredWidth,
            height: SettingsScene.preferredHeight
        )
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuItem()
            }
        }

        // Single-instance onboarding window. `.defaultLaunchBehavior` is
        // computed from the persisted hasCompletedOnboarding flag at
        // app-init time; the AppDelegate handles NSApp.activate so the
        // window actually surfaces in front of other apps.
        Window("Zerro \u{2014} Setup", id: OnboardingScene.windowID) {
            OnboardingWindowView()
                .dockIconVisibility(windowID: OnboardingScene.windowID)
                .environment(permissions)
                .environment(onboarding)
                // Phase F: the required email-verification step needs the trial
                // layer (to request/verify the code + grant credits) and the
                // entitlement store (to refresh once credits are granted).
                .environment(trialCredits)
                .environment(entitlements)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(onboarding.shouldPresentOnboardingOnLaunch ? .presented : .automatic)

        // Phase A: single-instance paywall window. Mirrors the onboarding
        // window's modifiers, but `.defaultLaunchBehavior(.suppressed)`
        // guarantees it NEVER auto-presents at launch — it is brought
        // forward only by the recording-start gate via
        // `AppDelegate.openPaywall()` when the user is `.expired`.
        Window("Zerro \u{2014} Unlock", id: PaywallScene.windowID) {
            PaywallView()
                .dockIconVisibility(windowID: PaywallScene.windowID)
                .disablesWindowRestoration()
                .environment(entitlements)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Dedicated post-purchase "Activate your key" window. Mirrors the paywall
        // window's modifiers (single-instance, content-sized, `.suppressed` so it
        // NEVER auto-presents at launch). Brought forward only by the checkout-
        // return deep link via `AppDelegate.openActivateKey()` when the link
        // carries an issued key — the key lands PREFILLED and the user explicitly
        // taps Activate (E-01); the full paywall is no longer opened for that flow.
        Window("Activate your key", id: ActivateKeyScene.windowID) {
            ActivateKeyView()
                .dockIconVisibility(windowID: ActivateKeyScene.windowID)
                .disablesWindowRestoration()
                .environment(entitlements)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Phase F: the trial email-capture window. Like the paywall it NEVER
        // auto-presents (`.suppressed`); AppState brings it forward via
        // `AppDelegate.openTrialEmailCapture()` at the first server-funded
        // generation, and dismisses on verify/cancel.
        Window("Zerro \u{2014} Free Trial", id: TrialEmailScene.windowID) {
            TrialEmailCaptureView()
                .dockIconVisibility(windowID: TrialEmailScene.windowID)
                .disablesWindowRestoration()
                .environment(appState)
                .environment(trialCredits)
                .environment(entitlements)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // In-app feedback dialog (replaces the old mailto link). Opened from the
        // menu-bar "Send feedback" row and the Settings "Send Feedback" row via
        // openWindow(id:). Mirrors the Settings window's chromeless/fixed-size
        // treatment (`.hiddenTitleBar` + `.contentSize`); never auto-presents.
        Window("Zerro \u{2014} Feedback", id: FeedbackScene.windowID) {
            FeedbackView()
                .dockIconVisibility(windowID: FeedbackScene.windowID)
                .disablesWindowRestoration()
                // The verified trial email (when present) attributes the report;
                // FeedbackView reads `rememberedEmail` and sends null otherwise.
                .environment(trialCredits)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(
            width: FeedbackScene.preferredWidth,
            height: FeedbackScene.preferredHeight
        )
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
    ///   2.5 (Phase A) Permissions pass but the user isn't entitled
    ///      (`EntitlementStore.canGenerate == false`, i.e. `.expired`) —
    ///      bring the paywall forward and stop before capture, exactly
    ///      like the gates above. Only the START path gates; 0a/0b (stop /
    ///      processing) above are never entitlement-gated.
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
        entitlements: EntitlementStore?,
        areaSelector: AreaSelectorWindowController?,
        pillController: PillWindowController?
    ) {
        guard let state, let preferences, let permissions, let onboarding, let areaSelector else {
            Log.hotkey.error("dropped — one of state/preferences/permissions/onboarding/areaSelector was nil")
            return
        }

        // All interpolated values in this function are .public — they're
        // either enum case descriptions (state, permission status) or
        // booleans, never user content.
        Log.hotkey.notice("fired — hasCompletedOnboarding=\(onboarding.hasCompletedOnboarding ? "Y" : "N", privacy: .public)")

        // 0a. Active recording — stop it. Runs before any setup gate
        // because you must always be able to stop, even if a permission
        // was revoked mid-session.
        if state.isRecordingActive {
            Log.hotkey.notice("active recording — stopping (toggle)")
            state.stopRecording()
            return
        }
        // 0b. Processing in flight — flash the pill instead of starting a
        // new recording. The record hotkey must not interrupt local/API
        // work (the pill's Cancel is that affordance), but a silent drop
        // reads as "the hotkey didn't fire" — the brief scale pulse
        // signals "registered, but the app is busy".
        if state.state == .processing {
            Log.hotkey.notice("processing in flight — flashing pill instead of starting")
            pillController?.flashBusy()
            return
        }
        // M2 (rev 3): the recovery offer is awaiting an answer (Generate /
        // Discard / dismiss). Like .processing, the record hotkey must not
        // start a new recording over it — flash to signal "resolve the pill
        // first" (the pill's "x" is the quick "not now").
        if case .confirmingRecovery = state.state {
            Log.hotkey.notice("recovery confirm in flight — flashing pill instead of starting")
            pillController?.flashBusy()
            return
        }
        // Dev Mode quit-recovery: the cross-launch Undo/Keep offer is awaiting an
        // answer. Like .confirmingRecovery, the record hotkey must not start a new
        // recording over it (resolving it first protects the interrupted edits) —
        // flash to signal "registered, resolve the pill".
        if case .confirmingDevRecovery = state.state {
            Log.hotkey.notice("dev recovery confirm in flight — flashing pill instead of starting")
            pillController?.flashBusy()
            return
        }
        // Dev Mode (M7 #3): a dispatch/revert is in flight — the record hotkey
        // must NOT start a new recording over it. Doing so would route through
        // resetToIdle → startRecording and abandon the running agent + destroy
        // its undo snapshot ("cancelled but files changed with no undo"). Flash,
        // like .processing; the pill's Cancel is the way to stop a live agent.
        if state.isDevBusy {
            Log.hotkey.notice("dev dispatch in flight — flashing pill instead of starting")
            pillController?.flashBusy()
            return
        }
        // Terminal "resting pill" states — a finished result (.done), an error
        // (.failed), or a Dev Mode result/failure card (.devDone/.devFailed) is
        // still on screen and the user hasn't resolved it. The record hotkey
        // must NOT silently tear it down (via resetToIdle / dismissFailure) and
        // start a new session; the user accepts/dismisses/undoes the pill via
        // its own controls first. Flash like .processing to signal
        // "registered — clear the pill first".
        if state.isShowingRestingPill {
            Log.hotkey.notice("resting pill showing (\(String(describing: state.state), privacy: .public)) — flashing instead of starting")
            pillController?.flashBusy()
            return
        }

        if !onboarding.hasCompletedOnboarding {
            Log.hotkey.notice("gating: onboarding incomplete — opening onboarding")
            AppDelegate.openOnboarding()
            return
        }

        // Re-read live OS state in case a permission was revoked while
        // the app was running. We only treat Screen Recording + Mic as
        // gating; Accessibility is informational per Checkpoint 3.
        permissions.refreshStatuses()
        Log.hotkey.info(
            "permission statuses — screen=\(String(describing: permissions.screenRecordingStatus), privacy: .public) mic=\(String(describing: permissions.microphoneStatus), privacy: .public) accessibility=\(String(describing: permissions.accessibilityStatus), privacy: .public)"
        )

        if permissions.screenRecordingStatus != .granted {
            Log.hotkey.notice("gating: screen recording not granted — opening onboarding @ permissions")
            onboarding.jump(to: .permissions)
            AppDelegate.openOnboarding()
            return
        }
        if permissions.microphoneStatus != .granted {
            Log.hotkey.notice("gating: microphone not granted — opening onboarding @ permissions")
            onboarding.jump(to: .permissions)
            AppDelegate.openOnboarding()
            return
        }

        // Phase B freshness point: re-evaluate the trial clock at the
        // moment of a record attempt, mirroring the `permissions.refreshStatuses()`
        // re-read above. A long-running app must not honor a stale "still in
        // trial" computed hours ago — a trial that lapsed while the app sat
        // idle is caught HERE. `refresh()` is a couple of Keychain reads +
        // arithmetic (cheap per attempt) and preserves the fail-open contract,
        // so it can never turn a transient read error into a lockout.
        entitlements?.refresh()

        // Phase A entitlement gate. Stops the START path (and only the
        // start path — 0a/0b above always run) before any capture when the
        // user isn't entitled (`.expired`). A nil `entitlements` is treated
        // as FAIL-OPEN: we proceed rather than trap a user behind a paywall
        // because of a wiring/lifetime gap — matching the fail-open contract
        // documented on EntitlementStore.refresh(). The state name is
        // .public (an enum description, no user content).
        if let entitlements, !entitlements.canGenerate {
            // Tier 3 analytics: the plain not-entitled (`.expired`) open has no
            // preflight reason → clear any stale block trigger so PaywallView
            // reports `manual`. (A managed out-of-credits / inactive block routes
            // to the failure pill below, not here, and sets its own trigger.)
            entitlements.paywallTrigger = nil
            Log.hotkey.notice("gating: not entitled — opening paywall")
            AppDelegate.openPaywall()
            return
        }

        // Pre-flight gate (Phase G UX): catch a DEFINITIVELY-known failure that
        // would otherwise only surface AFTER a wasted recording — Managed out of
        // credits, an inactive/cancelled subscription, or a BYOK user with no key
        // on file. Surfaces the SAME copy the post-recording path uses, before
        // capture. Strictly fail-open: `preflightBlock` returns nil for anything
        // inconclusive (no snapshot yet, an in-flight refresh, a Keychain blip),
        // so a transient infra failure never traps an otherwise-entitled user —
        // they record, and the proxy + post-recording path stay the backstop.
        // The genuinely-not-pre-flightable failures (empty/too-quiet recording,
        // OpenAI transient errors, model-output problems) are unreachable here by
        // construction — they need the recording/API call to exist.
        if let entitlements,
           let block = entitlements.preflightBlock(canGenerateLocally: state.canGenerateLocally()) {
            let reason = state.presentPreflightBlock(block)
            Log.hotkey.notice("gating: pre-flight block \(String(describing: reason), privacy: .public) — surfacing before capture")
            return
        }

        Log.hotkey.notice("all gates passed — presenting area selector")

        // hotkey → area selector → (on confirm) → startRecording(selection:mic:)
        // Mic device is read fresh from preferences at confirm time so a
        // Settings change between recordings takes effect on the next one
        // without restarting the app.
        areaSelector.present(
            preferences: preferences,
            // Multi-model: feeds the toolbar model dropdown's credit detail
            // (Managed/Trial) and BYOK key-gating.
            entitlements: entitlements,
            onConfirm: { [weak state, weak preferences] selection, modelID, devSelection in
                guard let state else { return }
                // From a visible result/error (done/failed) reset to idle
                // first so startRecording's `guard state == .idle` passes
                // and a new recording can begin.
                if state.state != .idle {
                    state.resetToIdle()
                }
                state.startRecording(
                    selection: selection,
                    microphoneDeviceID: preferences?.microphoneDeviceID ?? "",
                    // Phase 3: read the redaction pref fresh (same pattern) so a
                    // Settings change takes effect on the next recording.
                    redactSecrets: preferences?.redactSecrets ?? ProcessingConfig.redactSecretsDefault,
                    // Multi-model: the toolbar chip's pick, a PER-RECORDING
                    // override — handed through here, never persisted (unlike
                    // the mic above, by design).
                    modelID: modelID,
                    // Dev Mode (Phase 1): the toolbar's agent + folder, or nil
                    // for a normal clipboard recording.
                    devMode: devSelection
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

    /// Set by `PaywallOpenerRegistrar` (mounted in the always-present
    /// MenuBarExtra label). Used by `openPaywall` to bring the paywall
    /// window forward from the hotkey gate. Mirrors `requestOpenOnboarding`.
    nonisolated(unsafe) static var requestOpenPaywall: (() -> Void)?

    /// Set by `TrialEmailOpenerRegistrar`. Used by `openTrialEmailCapture` to
    /// bring the trial email-capture window forward when AppState pauses a trial
    /// user's first server-funded generation (Phase F). Mirrors the two above.
    nonisolated(unsafe) static var requestOpenTrialEmail: (() -> Void)?

    /// Set by `ActivateKeyOpenerRegistrar`. Used by `openActivateKey` to bring the
    /// dedicated "Activate your key" window forward when a checkout-return deep
    /// link carries an issued key. Mirrors the three above.
    nonisolated(unsafe) static var requestOpenActivateKey: (() -> Void)?

    /// Set by `PaywallOpenerRegistrar` alongside the opener. Used by the
    /// checkout-return deep link to dismiss the paywall for an already-activated
    /// buyer (a Managed top-up that updated credits silently).
    nonisolated(unsafe) static var requestDismissPaywall: (() -> Void)?

    /// Set by `SettingsDismissRegistrar`. Used by the checkout-return deep link's
    /// key-prefill branch to dismiss the Settings window if AppKit happened to
    /// materialize it on the deep-link reactivation, so only the Activate window
    /// remains (belt-and-suspenders alongside the activation-anchor scene).
    nonisolated(unsafe) static var requestDismissSettings: (() -> Void)?

    /// One-shot: the Settings category to preselect the next time the Settings
    /// window opens. Set right before `openWindow(id: SettingsScene.windowID)` —
    /// the BYOK success confirmation's "Open Settings" button routes to Account &
    /// Billing, where the API-key field lives. `SettingsView` reads + clears it on
    /// appear. UI only.
    nonisolated(unsafe) static var pendingSettingsCategory: SettingsCategory?

    /// Set by `ZerroApp.init`'s one-shot block to the long-lived entitlement
    /// store. Read by the `zerro://` checkout-return deep link and the
    /// app-activation refresh. Weak, like `appState` — owned by ZerroApp's
    /// @State for the app's lifetime.
    nonisolated(unsafe) static weak var entitlements: EntitlementStore?

    /// Throttle stamp for the app-activation entitlement refresh, so a flurry of
    /// activations doesn't hammer `/session` / `/entitlement`. MainActor-isolated
    /// (only touched from `refreshEntitlementOnActivation`).
    @MainActor private static var lastActivationRefresh: Date?

    /// Set by `ZerroApp.init`'s one-shot block to the live, long-lived
    /// AppState. Read by `applicationShouldTerminate` (M1) to route a quit by
    /// the current recording/processing state. Weak — AppState is owned by
    /// ZerroApp's @State for the app's lifetime, so the ref stays valid; set
    /// only inside the one-shot block so it never points at one of the
    /// throwaway AppStates SwiftUI builds on App.init re-invocation.
    nonisolated(unsafe) static weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Window scene's .defaultLaunchBehavior(.presented) already
        // instantiates the onboarding window when needed. We just need
        // to bring the app forward so the window has key focus in an
        // .accessory-policy menu-bar app.
        if Self.shouldPresentOnboardingOnLaunch {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Step 5 (billing): refresh the entitlement whenever Zerro becomes
        // active. This is the fallback for a checkout return where the `zerro://`
        // deep link didn't fire, AND it silently bumps an already-activated
        // Managed user's credit balance after a top-up (no paste needed). App-
        // lifetime observer; throttled so it never hammers the backend.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in Self.refreshEntitlementOnActivation() }
        }
    }

    /// Minimum gap between app-activation entitlement refreshes, so a rapid
    /// ⌘-Tab in/out doesn't spam `/session` / `/entitlement`.
    @MainActor
    private static let activationRefreshThrottle: TimeInterval = 15

    /// Throttled entitlement refresh on app activation. Always recomputes the
    /// local state (cheap, fail-open); only re-hits `/entitlement` when a license
    /// is actually on file (`refreshManagedEntitlement` itself no-ops unless the
    /// user is `.managed`).
    @MainActor
    static func refreshEntitlementOnActivation() {
        guard let entitlements else { return }
        let now = Date()
        if let last = lastActivationRefresh, now.timeIntervalSince(last) < activationRefreshThrottle {
            return
        }
        lastActivationRefresh = now
        entitlements.refresh()
        if entitlements.hasLicenseOnFile {
            Task { @MainActor in await entitlements.refreshManagedEntitlement() }
        }
    }

    /// The custom URL scheme THIS build registers for the checkout-return deep
    /// link, read back from the app's own `CFBundleURLTypes`. That array is
    /// populated by the per-configuration `DEEPLINK_SCHEME` build setting
    /// (`zerro` for production, `zerro-staging` for the side-by-side Staging
    /// build — see `apps/desktop/Config/*.xcconfig`), so the handler accepts
    /// exactly what macOS routes to this build and prod/staging never poach each
    /// other's callback. Reading the registered scheme keeps a single source of
    /// truth rather than hardcoding it twice. Falls back to `zerro` if the plist
    /// is somehow absent. Lowercased for a case-insensitive scheme compare.
    static let deeplinkScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let scheme = types?
            .compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme, !scheme.isEmpty { return scheme.lowercased() }
        return "zerro"
    }()

    /// Step 4 (billing): the checkout-return deep link. LemonSqueezy's per-product
    /// "Redirect URL after purchase" bounces the browser back to
    /// `<scheme>://checkout-complete?product=<product>` (`scheme` = `deeplinkScheme`
    /// above); macOS routes it here because CFBundleURLTypes registers the scheme.
    /// Custom-scheme opens arrive via this AppKit hook rather than SwiftUI
    /// `.onOpenURL` because the app may have no window mounted on return (it's a
    /// menu-bar/accessory app).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == Self.deeplinkScheme {
            Self.handleCheckoutReturn(url)
        }
    }

    /// A checkout-return deep link that arrived BEFORE the entitlement store was
    /// wired (cold launch from clicking "Return to Zerro" — macOS routes the open
    /// URL before SwiftUI mounts our scene and `ZerroApp.init` runs). Stashed by
    /// `handleCheckoutReturn` and replayed by `replayPendingCheckoutURLIfNeeded`
    /// from `ZerroApp.init`'s one-shot wiring block. MainActor-isolated.
    @MainActor static var pendingCheckoutURL: URL?

    /// Side effects the checkout-return resolution performs, injected so tests can
    /// observe them without driving real AppKit / analytics. Production passes
    /// `.live`.
    @MainActor
    struct CheckoutReturnEffects {
        var bringAppForward: () -> Void
        var dismissPaywall: () -> Void
        /// Dismisses the Settings window. The key-prefill branch calls it so a
        /// Settings window AppKit may have materialized on the deep-link
        /// reactivation is cleared, leaving only the Activate window. A no-op when
        /// Settings isn't open.
        var dismissSettings: () -> Void
        var openPaywall: () -> Void
        /// Opens the dedicated "Activate your key" window. The post-purchase
        /// key-prefill branch routes here instead of the full paywall.
        var openActivateKey: () -> Void
        var capture: (_ event: String, _ properties: [String: Any]) -> Void

        static let live = CheckoutReturnEffects(
            bringAppForward: { NSApp.activate(ignoringOtherApps: true) },
            dismissPaywall: { AppDelegate.requestDismissPaywall?() },
            dismissSettings: { AppDelegate.requestDismissSettings?() },
            openPaywall: { AppDelegate.openPaywall() },
            openActivateKey: { AppDelegate.openActivateKey() },
            capture: { Analytics.capture($0, $1) }
        )
    }

    /// Resolves a checkout return. Two shapes:
    ///
    ///   • The link carries a `license_key` (LemonSqueezy's bounce page forwards
    ///     the issued key): do NOT activate automatically (E-01 — any page/email
    ///     can craft such a link). Instead route the key into the activation UI
    ///     PREFILLED + focused so the user explicitly taps Activate; the
    ///     overwrite-a-present-license guard then lives in `LicenseService`.
    ///     An already-active key/device is the one exception — it's idempotent
    ///     (requires THIS device's exact active key, so it isn't spoofable) and
    ///     shows the success confirmation without re-POSTing. No purchase
    ///     analytics fire from this handler in either case.
    ///   • No `license_key` (a Managed top-up or an older link): keep the prior
    ///     behavior exactly — refresh, then silently surface an already-entitled
    ///     user or open the paywall focused on the activation field.
    ///
    /// `handleCheckoutReturn` is the AppKit entry point; the work lives here in a
    /// resolver that takes the parsed link + injected `effects` so it's unit-
    /// testable. Returns the `CheckoutOutcome` it took (also the analytics
    /// `outcome`).
    @MainActor
    static func handleCheckoutReturn(_ url: URL) {
        guard let parsed = CheckoutReturn.parse(url) else {
            Log.billing.notice("deep link: ignoring \(url.absoluteString, privacy: .public)")
            return
        }
        guard let entitlements else {
            // Cold launch: the deep link beat the store wiring. Stash it; the
            // one-shot block in `ZerroApp.init` replays it once the store is set.
            pendingCheckoutURL = url
            Log.billing.notice("deep link: checkout-complete before store wired — buffering")
            return
        }
        Log.billing.notice(
            "deep link: checkout-complete received (key=\(parsed.licenseKey != nil, privacy: .public) product=\(parsed.productKind?.rawValue ?? "none", privacy: .public))"
        )
        Task { @MainActor in
            _ = await resolveCheckoutReturn(parsed, entitlements: entitlements)
        }
    }

    /// Replays a checkout-return deep link buffered before the store was wired
    /// (cold launch). Called from `ZerroApp.init`'s one-shot block right after
    /// `AppDelegate.entitlements` is set. No-op when nothing is buffered.
    @MainActor
    static func replayPendingCheckoutURLIfNeeded() {
        guard let pending = pendingCheckoutURL else { return }
        pendingCheckoutURL = nil
        Log.billing.notice("deep link: replaying buffered checkout-complete")
        handleCheckoutReturn(pending)
    }

    @MainActor
    @discardableResult
    static func resolveCheckoutReturn(
        _ parsed: CheckoutReturn,
        entitlements: EntitlementStore,
        effects: CheckoutReturnEffects? = nil
    ) async -> CheckoutOutcome {
        // `.live` is a main-actor-isolated static, but default-argument expressions
        // are evaluated in a nonisolated context, so `= .live` warns (an error in
        // the Swift 6 language mode). Default to `nil` and resolve here, inside this
        // @MainActor body where `.live` is legitimately reachable.
        let effects = effects ?? .live
        guard let key = parsed.licenseKey else {
            return await resolveCheckoutReturnWithoutKey(entitlements: entitlements, effects: effects)
        }

        // Idempotency: an already-entitled user clicking the link again (or whose
        // key already activated THIS device) is a SUCCESS — don't re-POST to
        // LemonSqueezy, which could needlessly burn a machine slot. This requires
        // THIS device's EXACT active key, so it can't be spoofed by a hostile
        // link; it shows the confirmation without firing `purchase_activated`.
        entitlements.refresh()
        if entitlements.isActiveLicenseKey(key) {
            await finishSuccessfulActivation(entitlements: entitlements, effects: effects)
            Log.billing.notice("deep link: key already active — treated as success")
            return .alreadyActive
        }

        // E-01: do NOT auto-activate an externally-supplied key. Route it into the
        // dedicated "Activate your key" window PREFILLED + focused so the user
        // explicitly taps Activate — the same confirm path a failed auto-activation
        // already used, now on its own clean surface instead of the full paywall.
        // The "replace a present license?" guard lives in `LicenseService.activate`,
        // and `purchase_activated` is emitted only when the user actually
        // confirms (see `PaywallActivationModel`), never from this handler. No
        // network call, no Keychain write, no analytics happen here.
        entitlements.prefillLicenseKey = key
        entitlements.paywallTrigger = .manage
        entitlements.focusActivationFieldOnOpen = true
        // Window hygiene: the user arrives here from the in-paywall "buy" flow, so
        // the paywall is open; and AppKit may have materialized the Settings window
        // on this reactivation (see the activation-anchor scene). Dismiss both
        // BEFORE opening Activate so only the Activate window is left on screen —
        // no visible stack. Both are safe no-ops when the window isn't open.
        effects.dismissPaywall()
        effects.dismissSettings()
        effects.openActivateKey()
        Log.billing.notice("deep link: key received — prefilled activate-key window for explicit confirmation")
        return .prefilled
    }

    /// The no-key checkout return (a Managed top-up or an older link): refresh,
    /// then either confirm a top-up (when the credit balance went up) or, for an
    /// entitled user with no observable delta, surface silently as before. A
    /// not-yet-entitled user opens the paywall focused on the activation field
    /// (a brand-new buyer who must paste).
    @MainActor
    private static func resolveCheckoutReturnWithoutKey(
        entitlements: EntitlementStore,
        effects: CheckoutReturnEffects
    ) async -> CheckoutOutcome {
        // Snapshot the balance BEFORE the refresh so a top-up's delta is visible.
        let creditsBefore = entitlements.currentDisplayedCredits
        entitlements.refresh()
        await entitlements.refreshManagedEntitlement()
        if entitlements.isPaidEntitled {
            // Top-up: if credits demonstrably went up, confirm how many landed.
            if let info = PurchaseSuccessInfo.topupDelta(
                before: creditsBefore,
                after: entitlements.currentDisplayedCredits
            ) {
                entitlements.purchaseSuccess = info
                effects.capture("purchase_success_shown", ["method": "deeplink", "plan": "topup"])
                effects.openPaywall()
                Log.billing.notice("deep link: top-up confirmed")
                return .topupConfirmed
            }
            // No computable delta (no credit balance, or no increase) → silent.
            effects.bringAppForward()
            effects.dismissPaywall()
            Log.billing.notice("deep link: already entitled — refreshed silently")
            return .silentRefresh
        }
        entitlements.paywallTrigger = .manage
        entitlements.focusActivationFieldOnOpen = true
        effects.openPaywall()
        Log.billing.notice("deep link: not yet entitled — opening paywall focused on activation")
        return .openedPaywallNoKey
    }

    /// Shared success tail for an automatic activation (fresh or already-active):
    /// re-derive the entitlement, pull the latest Managed credits, then SHOW the
    /// success confirmation rather than dismissing — the user dismisses it via
    /// the confirmation's own button. The paywall window is opened to host the
    /// confirmation (it may not be open after a deep-link activation).
    @MainActor
    private static func finishSuccessfulActivation(
        entitlements: EntitlementStore,
        effects: CheckoutReturnEffects
    ) async {
        entitlements.refresh()
        await entitlements.refreshManagedEntitlement()
        guard let info = PurchaseSuccessInfo.fromActivatedState(entitlements.state) else {
            // Defensive: no paid state to confirm — fall back to surfacing the
            // app + dismissing the paywall (the prior success behavior).
            effects.bringAppForward()
            effects.dismissPaywall()
            return
        }
        entitlements.purchaseSuccess = info
        effects.capture("purchase_success_shown", ["method": "deeplink", "plan": info.analyticsPlan])
        effects.openPaywall()
    }

    /// M1 — quit (⌘Q / menu "Quit Zerro") routing. `NSApplication.terminate`
    /// has no other teardown hook in this app, so without this a quit
    /// mid-recording would orphan an unfinalized writer (an unplayable `.mov`)
    /// and a quit mid-processing would strand the working dir. We hand off to
    /// `AppState.prepareForTermination`, which abandons an in-flight recording
    /// down the SAME recoverable path sleep uses (offered on next launch) and
    /// cancels + cleans an in-flight generation, then return `.terminateNow`:
    /// the abandon/cleanup are prompt (no async wait), so quit is never blocked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.appState?.prepareForTermination()
        return .terminateNow
    }

    /// Clicking the Dock icon (visible only while a qualifying window is
    /// open — see DockIconController) should raise that window. Without
    /// this, AppKit's default reopen handling can leave the window buried
    /// behind other apps because none of our scenes are "main"-window
    /// material in the usual sense.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockIconController.shared.bringVisibleWindowsToFront()
        return false
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
            Log.onboarding.error("openOnboarding() called but requestOpenOnboarding is nil — registrar didn't mount")
        }
    }

    /// Brings the paywall window forward. Mirrors `openOnboarding()`:
    /// activate the app (so the window surfaces in front in this
    /// .accessory-policy app), then invoke the captured opener. Called
    /// from the hotkey entitlement gate.
    @MainActor
    static func openPaywall() {
        NSApp.activate(ignoringOtherApps: true)
        if let opener = requestOpenPaywall {
            opener()
        } else {
            // Same failure mode as openOnboarding's nil branch — should be
            // impossible once PaywallOpenerRegistrar mounts at launch, but
            // log loudly so a silent no-op (the user pressing record and
            // nothing happening) is diagnosable.
            Log.ui.error("openPaywall() called but requestOpenPaywall is nil — registrar didn't mount")
        }
    }

    /// Brings the trial email-capture window forward (Phase F). Mirrors
    /// `openPaywall()`. Called by AppState when a trial user's first server-funded
    /// generation needs an email verified.
    @MainActor
    static func openTrialEmailCapture() {
        NSApp.activate(ignoringOtherApps: true)
        if let opener = requestOpenTrialEmail {
            opener()
        } else {
            Log.ui.error("openTrialEmailCapture() called but requestOpenTrialEmail is nil — registrar didn't mount")
        }
    }

    /// Brings the dedicated "Activate your key" window forward. Mirrors
    /// `openPaywall()`: activate the app first (so the window surfaces in front in
    /// this .accessory-policy app), then invoke the captured opener. Called by the
    /// checkout-return deep link when an issued key is prefilled for explicit
    /// activation (E-01) — in place of opening the full paywall.
    @MainActor
    static func openActivateKey() {
        NSApp.activate(ignoringOtherApps: true)
        if let opener = requestOpenActivateKey {
            opener()
        } else {
            Log.ui.error("openActivateKey() called but requestOpenActivateKey is nil — registrar didn't mount")
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

// MARK: - PaywallOpenerRegistrar
//
// Phase A twin of OnboardingOpenerRegistrar. Captures `openWindow` into
// AppDelegate.requestOpenPaywall at launch so the hotkey gate can bring
// the paywall forward even though the Window scene's content (and its
// onAppear) only mounts when the window is actually on screen — and the
// paywall's scene is `.suppressed`, so it's never on screen at launch.
// Mounted in the MenuBarExtra label, the one always-present View.

private struct PaywallOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.requestOpenPaywall = {
                    openWindow(id: PaywallScene.windowID)
                }
                // Captured alongside the opener so the checkout-return deep link
                // can dismiss the paywall for an already-activated user (a
                // top-up) without standing up a second registrar.
                AppDelegate.requestDismissPaywall = {
                    dismissWindow(id: PaywallScene.windowID)
                }
            }
    }
}

// MARK: - TrialEmailOpenerRegistrar
//
// Phase F twin of PaywallOpenerRegistrar. Captures `openWindow` into
// AppDelegate.requestOpenTrialEmail at launch so AppState can bring the
// (suppressed-at-launch) trial email-capture window forward when a trial user's
// first server-funded generation needs email verification.

private struct TrialEmailOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.requestOpenTrialEmail = {
                    openWindow(id: TrialEmailScene.windowID)
                }
            }
    }
}

// MARK: - ActivateKeyOpenerRegistrar
//
// Twin of PaywallOpenerRegistrar for the dedicated "Activate your key" window.
// Captures `openWindow` into AppDelegate.requestOpenActivateKey at launch so the
// checkout-return deep link can bring the (suppressed-at-launch) window forward
// even though the Window scene's content (and its onAppear) only mounts when the
// window is actually on screen. Mounted in the MenuBarExtra label, the one
// always-present View.

private struct ActivateKeyOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.requestOpenActivateKey = {
                    openWindow(id: ActivateKeyScene.windowID)
                }
            }
    }
}

// MARK: - SettingsDismissRegistrar
//
// Captures `dismissWindow` for the Settings scene into
// AppDelegate.requestDismissSettings at launch — mirroring how
// PaywallOpenerRegistrar captures requestDismissPaywall. The checkout-return
// deep link's key-prefill branch calls it (a safe no-op when Settings isn't
// open) so a Settings window AppKit may have materialized on the reactivation is
// cleared, leaving only the Activate window. Mounted in the MenuBarExtra label,
// the one always-present View.

private struct SettingsDismissRegistrar: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.requestDismissSettings = {
                    dismissWindow(id: SettingsScene.windowID)
                }
            }
    }
}

// MARK: - SettingsMenuItem
//
// Phase 11 (revision 2): replaces the stock Settings menu item that the
// SwiftUI `Settings { ... }` scene installs for free. We need this
// custom item because the Settings scene was replaced with a regular
// Window — `.appSettings` is the menu command group keyed to ⌘, , and
// CommandGroup(replacing:.appSettings) keeps that shortcut alive while
// routing the click to openWindow(id:) for our custom Window.
//
// In an LSUIElement (accessory) app the main menu isn't visible by
// default, but the keyboard shortcut still registers when the app is
// foreground. The menu-bar dropdown's "Preferences…" row is the
// primary entry point; ⌘, works once a Zerro window has focus.

private struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SettingsScene.windowID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
