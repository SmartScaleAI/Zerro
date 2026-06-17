//
//  MenuBarPanelView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Configuration shelf hosted by `MenuBarExtra(.window)`. The panel reads
//  `AppState` so the primary action row can flip between "Start Recording"
//  and "Stop Recording" (and grey out during processing) without holding
//  any local state of its own. Active timer / spinner UI still lives in
//  the pill, not here. Styling targets a native-looking NSMenu: tight
//  rows, full-row accent-blue fill with white text on hover (instant, no
//  animation), hotkey hints as plain dimmed trailing text, hairline
//  dividers.
//

import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

// MARK: - MenuBarBillingAction

/// The label + optional secondary nudge + paywall trigger for the single,
/// always-present menu-bar billing row, resolved from the live entitlement.
/// This is the consolidation of the old scattered prompts (trial-upgrade,
/// top-up, past-due, manage) into one row. Pure + `Equatable` so the
/// state → (label, trigger) mapping is unit-tested without the view.
///
/// Rules (decision §3):
///   • `.trial`            → "Upgrade"     (voluntaryUpgrade) — trial still works.
///   • `.expired`          → "Upgrade"     (blocked) — the gated wall.
///   • `.managed` past-due → "Manage Plan" (manage) + "update your card" nudge.
///   • `.managed` low      → "Add Credits" (topup) — lead with top-up packs.
///   • `.managed` healthy  → "Add more credits" (manage) — the portal is where
///     a paid-up Managed user tops up; label leads with that even though the
///     trigger is the general manage surface.
///   • `.byok`             → "Manage Plan" (manage) — nothing to upgrade/top up.
struct MenuBarBillingAction: Equatable {
    let label: String
    /// A quiet secondary line under the label (currently only the Managed
    /// past-due warning, folded in from the removed status nudge). `nil` hides it.
    let secondary: String?
    let trigger: EntitlementStore.PaywallTrigger

    static func resolve(state: EntitlementState, isPastDue: Bool, isLowBalance: Bool) -> MenuBarBillingAction {
        switch state {
        case .trial:
            return MenuBarBillingAction(label: "Upgrade", secondary: nil, trigger: .voluntaryUpgrade)
        case .expired:
            return MenuBarBillingAction(label: "Upgrade", secondary: nil, trigger: .blocked)
        case .byok:
            return MenuBarBillingAction(label: "Manage Plan", secondary: nil, trigger: .manage)
        case .managed:
            // Past-due is a payment problem → manage (update card), and it folds
            // in the warning the removed status nudge used to carry.
            if isPastDue {
                return MenuBarBillingAction(
                    label: "Manage Plan",
                    secondary: "Payment issue \u{2014} update your card",
                    trigger: .manage
                )
            }
            // Low balance (but paid up) → buy more credits.
            if isLowBalance {
                return MenuBarBillingAction(label: "Add Credits", secondary: nil, trigger: .topup)
            }
            // Healthy Managed → the manage portal (already top tier; no plan
            // ladder to sell), but lead the label with adding credits since
            // that's what a paid-up user comes here for.
            return MenuBarBillingAction(label: "Add more credits", secondary: nil, trigger: .manage)
        }
    }
}

struct MenuBarPanelView: View {
    /// When `true`, the Recent Prompts row renders in its selected state.
    /// Used by the submenu-flyout `#Preview` to show the parent row
    /// highlighted while the submenu is open.
    var highlightRecentPrompts: Bool = false

    /// Begins the recording flow — same entry point as the global hotkey, so
    /// it presents the area-selector overlay first (gating on onboarding /
    /// permissions) rather than recording immediately. Wired by ZerroApp;
    /// defaults to a no-op so previews compile.
    var onStartRecording: () -> Void = {}

    @Environment(AppState.self) private var appState
    @Environment(PreferencesStore.self) private var preferences
    @Environment(RecentPromptStore.self) private var recentPrompts
    /// Read the entitlement so the dropdown can show a quiet "N free
    /// generations left" line while `.trial` (hidden in every other state).
    /// Always available in production now — the DEBUG entitlement picker below
    /// reads this same injected store.
    @Environment(EntitlementStore.self) private var entitlements

    /// Drives the Recent Prompts side panel (a trailing flyout). Opened on
    /// hover via `recentRowHovered` / `recentPanelHovered`.
    @State private var showRecentPrompts = false
    @State private var recentRowHovered = false
    @State private var recentPanelHovered = false
    /// Drives the Microphone picker side panel (a trailing flyout). Opened
    /// on hover via `micRowHovered` / `micPanelHovered`.
    @State private var showMicrophonePicker = false
    @State private var micRowHovered = false
    @State private var micPanelHovered = false
    /// Bumped when the Settings recorder finishes a rebind so the
    /// Start/Stop Recording hotkey hint re-reads the current shortcut
    /// from KeyboardShortcuts (which persists to UserDefaults — there's
    /// no SwiftUI binding to subscribe to). Same mechanism as
    /// HotkeyDisplay, including its caveat: the notification name is
    /// the library's internal one, and the worst case if a future
    /// version renames it is a stale hint until the panel reopens.
    @State private var hotkeyRefreshTick: Int = 0

    #if DEBUG
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions
    /// Drives the Entitlement picker side panel (a trailing flyout),
    /// opened on hover via `entitlementRowHovered` / `entitlementPanelHovered`
    /// — same hover-driven submenu shape as Recent Prompts / Microphone.
    @State private var showEntitlementPicker = false
    @State private var entitlementRowHovered = false
    @State private var entitlementPanelHovered = false
    /// Drives the debug "Poll continuously" toggle.
    @State private var isPolling = false
    #endif

    // Phase 11 (revision 2): the stock `Settings { ... }` scene was
    // replaced with a custom Window (see ZerroApp.body), so this row
    // routes through `openWindow(id:)` instead of `openSettings()`.
    // NSApp.activate is paired with the call because LSUIElement apps
    // don't always come forward on their own when a window opens.

    // `openWindow` is used by the DEBUG onboarding opener AND by the
    // production hotkey-gating path (registered into AppDelegate so the
    // global hotkey can re-present onboarding when a permission was
    // revoked). Same activation caveat as openSettings — LSUIElement
    // apps need NSApp.activate paired with the call.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header

            // Quiet "N free generations left" line. Shown while `.trial` with a
            // known credit balance; hidden on `.byok` / `.managed` / `.expired`,
            // and on a not-yet-granted trial (nil balance) — that user instead
            // sees the verify-email banner just below.
            if case .trial(let creditsRemaining) = entitlements.state, let creditsRemaining {
                trialStatusLine(creditsRemaining: creditsRemaining)
            }

            // Phase F: a tappable banner for a trial user who hasn't claimed
            // their free server-funded credits yet (existing users, or those who
            // took the onboarding infra-failure fallback). Opens the standalone
            // verification window.
            if entitlements.needsTrialEmailVerification {
                trialVerifyBanner()
            }

            menuDivider

            // Phase A library-stays-readable rule: "Copy last prompt" and
            // "Recent Prompts" read RecentPromptStore directly and never
            // consult EntitlementStore.canGenerate — reading/copying past
            // prompts stays open in every entitlement state, `.expired`
            // included. Only the recording START path (handleHotkey) gates;
            // do not add an entitlement check to these rows.
            CopyLastPromptRow()
            MenuRow(
                label: "Recent Prompts",
                trailing: .submenu,
                forceSelected: highlightRecentPrompts || showRecentPrompts
            ) {
                showRecentPrompts = true
            }
            .onHover { hovering in
                recentRowHovered = hovering
                updatePanelVisibility(
                    hovered: recentRowHovered || recentPanelHovered,
                    isStillHovered: { recentRowHovered || recentPanelHovered },
                    setVisible: { showRecentPrompts = $0 }
                )
            }
            // Side panel of recent prompts with per-row Copy buttons,
            // presented as a chromeless trailing flyout (SubmenuFlyout.swift)
            // styled like a native NSMenu submenu — MenuBarExtra(.window)
            // can't host real submenus, and the popover chrome (beak +
            // glass) read wrong. Opens on hover of the row or the panel; the
            // content reads RecentPromptStore from the environment, passed
            // explicitly so it resolves inside the flyout's separate hosting
            // context.
            .submenuFlyout(isPresented: $showRecentPrompts) {
                RecentPromptsSubmenu()
                    .environment(recentPrompts)
                    .onHover { hovering in
                        recentPanelHovered = hovering
                        updatePanelVisibility(
                            hovered: recentRowHovered || recentPanelHovered,
                            isStillHovered: { recentRowHovered || recentPanelHovered },
                            setVisible: { showRecentPrompts = $0 }
                        )
                    }
            }

            menuDivider

            primaryRecordingRow
            // The model is chosen on the capture toolbar's model chip (which
            // now persists the pick as the last-used model) — there is no
            // menu-bar Model row.
            MenuRow(
                label: "Microphone",
                trailing: .submenu,
                forceSelected: showMicrophonePicker
            ) {
                showMicrophonePicker = true
            }
            .onHover { hovering in
                micRowHovered = hovering
                updatePanelVisibility(
                    hovered: micRowHovered || micPanelHovered,
                    isStillHovered: { micRowHovered || micPanelHovered },
                    setVisible: { showMicrophonePicker = $0 }
                )
            }
            // Same hover-opened trailing flyout as Recent Prompts — the
            // input device list with the current selection checked.
            .submenuFlyout(isPresented: $showMicrophonePicker) {
                MicrophonePicker()
                    .environment(preferences)
                    .onHover { hovering in
                        micPanelHovered = hovering
                        updatePanelVisibility(
                            hovered: micRowHovered || micPanelHovered,
                            isStillHovered: { micRowHovered || micPanelHovered },
                            setVisible: { showMicrophonePicker = $0 }
                        )
                    }
            }

            menuDivider

            MenuRow(label: "Send feedback") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: FeedbackScene.windowID)
                MenuBarExtraDismiss.dismiss()
            }
            // Phase 14 / C3.4: Sparkle "Check for Updates…". Owns the
            // SPUStandardUpdaterController at app-launch lifetime (see
            // ZerroApp.updater @StateObject) — this view just reads it
            // out of the environment so the controller stays alive
            // when the dropdown closes.
            CheckForUpdatesView()
            // The single, always-present billing entry point (consolidation
            // target): label + paywall trigger vary by state, replacing the
            // scattered trial-upgrade / top-up / past-due CTAs. Opens the
            // (context-aware) paywall window.
            billingActionRow
            MenuRow(label: "Settings\u{2026}", trailing: .hotkey("\u{2318},")) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SettingsScene.windowID)
                MenuBarExtraDismiss.dismiss()
            }
            MenuRow(label: "Quit Zerro", trailing: .hotkey("\u{2318}Q")) {
                NSApplication.shared.terminate(nil)
            }

            #if DEBUG
            // Phase 5 debug surface. Single `#if DEBUG` block in the
            // menu-bar panel — the natural anchor for developer
            // affordances on a menu-bar-only app. Replaced by the
            // onboarding dev panel when that ships.
            menuDivider
            // Single header over the whole debug block (permission status,
            // manual triggers, onboarding resets, and the probe actions).
            debugSectionTitle
            // Permission status rows lead the debug list.
            PermissionsDebugSection()
            MenuRow(label: "Open Onboarding\u{2026}") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: OnboardingScene.windowID)
            }
            // Phase A: entitlement state forcing, collapsed into a single
            // hover-driven submenu (same shape as Recent Prompts /
            // Microphone) to keep the debug block compact. Force "Expired"
            // in the side panel, then the recording hotkey (⌘⌃R by
            // default, or Start Recording) to drive the
            // paywall gate; the paywall window's own dev panel can flip
            // between states once it's open.
            MenuRow(
                label: "Entitlement",
                trailing: .submenu,
                forceSelected: showEntitlementPicker
            ) {
                showEntitlementPicker = true
            }
            .onHover { hovering in
                entitlementRowHovered = hovering
                updatePanelVisibility(
                    hovered: entitlementRowHovered || entitlementPanelHovered,
                    isStillHovered: { entitlementRowHovered || entitlementPanelHovered },
                    setVisible: { showEntitlementPicker = $0 }
                )
            }
            .submenuFlyout(isPresented: $showEntitlementPicker) {
                EntitlementDebugPicker()
                    .environment(entitlements)
                    .onHover { hovering in
                        entitlementPanelHovered = hovering
                        updatePanelVisibility(
                            hovered: entitlementRowHovered || entitlementPanelHovered,
                            isStillHovered: { entitlementRowHovered || entitlementPanelHovered },
                            setVisible: { showEntitlementPicker = $0 }
                        )
                    }
            }
            // Refill the displayed credit balance to full (managed plan
            // allowance or trial grant limit) so the credits line, low-balance
            // nudge, and out-of-credits gate can be re-tested without burning
            // real generations. Display-only — a real /entitlement refresh
            // restores the true balance.
            MenuRow(label: "Reset Credits") {
                entitlements.devResetCredits()
            }
            // Trial dev control. The trial is now a pure credit pool (no clock),
            // so forcing trial/expired is done via the Entitlement picker above;
            // what remains is wiping the local Phase F email-verification cache
            // so the onboarding email step re-runs against the server.
            MenuRow(label: "Reset Trial Verification") {
                entitlements.devResetTrialVerification()
            }
            MenuRow(label: "Reset Onboarding") {
                // Clear both persisted flags in-process; no relaunch
                // needed. Opens the window immediately so the next
                // run-through is one click away. Also clears the
                // PermissionsManager "has requested" tracking so the
                // screen-recording step's dev-drift CGWindowList
                // fallback doesn't false-positive into the allowed
                // view before the user has been prompted (the TCC
                // grant itself still lives in the OS — use "Reset
                // Permissions & Quit" below for that).
                onboarding.hasCompletedOnboarding = false
                onboarding.currentStep = .welcome
                permissions.resetRequestFlags()
                // Phase F: also clear locally-cached trial email-verification
                // state (token + credits + remembered email) so the email step
                // returns to its unverified first-run state — otherwise it would
                // read "Email verified" from the local cache even after the
                // server grant was deleted.
                entitlements.devResetTrialVerification()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: OnboardingScene.windowID)
            }
            MenuRow(label: "Reset Permissions & Quit") {
                // Resets the actual TCC grants (ScreenCapture +
                // Microphone + Accessibility) for this bundle ID via
                // `tccutil`, so the next launch sees the system in the
                // same state a fresh install would — onboarding's
                // permission prompts will fire for real. Also clears
                // the onboarding-completed flag so relaunching lands
                // directly on the onboarding window. We terminate
                // because macOS caches authorization per-process: a
                // new prompt only fires for a freshly-launched binary;
                // staying in-process would see the cached grant rather
                // than the cleared one.
                permissions.resetTCCGrants()
                onboarding.hasCompletedOnboarding = false
                onboarding.currentStep = .welcome
                NSApplication.shared.terminate(nil)
            }
            // Permission probe/refresh actions, styled as regular menu rows.
            MenuRow(label: "Refresh statuses") {
                permissions.refreshStatuses()
            }
            MenuRow(label: "Probe via WindowList") {
                // CGWindowListCopyWindowInfo on kCGWindowName — popup-free if
                // permission is granted; spawns the "Open System Settings"
                // popup once if not. Cheap dev-drift detector for ad-hoc-
                // signed builds.
                permissions.refreshScreenRecordingViaWindowList()
            }
            MenuRow(label: "Probe via Shareable") {
                // SCShareableContent.current — slowest but most reliable
                // dev-drift detector. Always spawns the popup if not actually
                // granted, so save it for cases where WindowList missed.
                Task { await permissions.refreshScreenRecordingViaShareable() }
            }
            debugPollRow
            #endif
        }
        .padding(.vertical, MenuMetrics.containerVerticalPadding)
        .frame(width: 260)
        .onAppear {
            // Register the SwiftUI openWindow action with the AppDelegate
            // so the global hotkey can re-present onboarding from outside
            // any view (e.g. when a required permission is revoked after
            // initial completion). The first time the user opens the
            // menu-bar dropdown captures this; idempotent on later
            // re-renders.
            AppDelegate.requestOpenOnboarding = {
                openWindow(id: OnboardingScene.windowID)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(rawValue: "KeyboardShortcuts_recorderActiveStatusDidChange")
            )
        ) { note in
            // Recorder finished (success or cancel) — re-read the binding
            // so the hotkey hint reflects a rebind made while this panel
            // is alive, without waiting for a relaunch.
            if let isActive = note.userInfo?["isActive"] as? Bool, !isActive {
                hotkeyRefreshTick &+= 1
            }
        }
    }

    // MARK: - Primary action row
    //
    // Single row that flips between "Start Recording" / "Stop Recording"
    // based on `AppState.isRecordingActive`, and disables itself during
    // `.processing` so the user can't kick off a new session while one
    // is in flight. The hotkey hint stays put — the toggleRecording
    // binding (⌘⌃R by default, user-rebindable) covers both halves of
    // the toggle.

    /// Trailing hint for the Start/Stop Recording rows, derived from the
    /// user's current toggleRecording binding rather than a hardcoded
    /// string. `.none` (no hint) when the user has cleared the shortcut.
    private var recordingHotkeyTrailing: RowTrailing {
        // Read the tick so a recorder-finished bump invalidates this view
        // and the hint re-reads the new binding.
        _ = hotkeyRefreshTick
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) else {
            return .none
        }
        return .hotkey(shortcut.symbolsDisplay)
    }

    @ViewBuilder
    private var primaryRecordingRow: some View {
        if appState.isRecordingActive {
            MenuRow(label: "Stop Recording", trailing: recordingHotkeyTrailing) {
                appState.stopRecording()
            }
        } else if appState.state == .processing {
            MenuRow(
                label: "Processing\u{2026}",
                trailing: recordingHotkeyTrailing,
                isDisabled: true
            )
        } else {
            MenuRow(label: "Start Recording", trailing: recordingHotkeyTrailing) {
                // Route through the same entry point as the global hotkey so
                // the area-selector overlay (with its mode toggle + mic
                // picker) is presented first — recording starts on confirm,
                // not on this click. Close the dropdown so the overlay isn't
                // behind it.
                MenuBarExtraDismiss.dismiss()
                onStartRecording()
            }
        }
    }

    // MARK: - Header row

    private var header: some View {
        HStack(spacing: VFSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black)
                Image("MenuBarLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(Color.white)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("Zerro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize()
                HStack(spacing: 4) {
                    Circle()
                        .fill(headerStatusColor)
                        .frame(width: 5, height: 5)
                    Text(headerStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfTextSecondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Header subtitle, driven by the live `EntitlementState`.
    ///
    /// `.trial` deliberately reads just "Ready": the dedicated trial line
    /// directly below the header carries the "N free generations left" count,
    /// so showing it here too would be redundant. Managed shows its own
    /// monthly credit count (BYOK funds via the user's own key).
    private var headerStatusText: String {
        switch entitlements.state {
        case .trial:
            return "Ready"
        case .byok:
            return "Ready"
        case .managed:
            // Credits are display-only (the server is the spend authority,
            // Phase E) and read from the live snapshot — so the count is
            // omitted until the first `/entitlement` refresh lands, rather than
            // flashing a placeholder.
            guard let snapshot = entitlements.managedSnapshot else { return "Ready" }
            if snapshot.isOutOfCredits { return "Out of credits" }
            let credits = snapshot.creditsRemaining == 1 ? "1 credit left" : "\(snapshot.creditsRemaining) credits left"
            return "Ready \u{00B7} \(credits)"
        case .expired:
            return "Trial ended"
        }
    }

    /// Status dot: green while usable, dimmed once the trial has ended so
    /// the header reads as "inactive" without being alarming (no red).
    private var headerStatusColor: Color {
        switch entitlements.state {
        case .expired:
            return Color.vfTextTertiary
        case .trial, .byok, .managed:
            return Color.vfSuccessGreen
        }
    }

    // MARK: - Consolidated billing entry point

    /// The single, always-present billing row. Its label + secondary nudge +
    /// paywall trigger are resolved from the live entitlement (see
    /// `MenuBarBillingAction`), so one row covers the old trial-upgrade, top-up,
    /// past-due, and manage prompts. Click sets the trigger (so the paywall's
    /// dynamic copy matches) and opens the context-aware paywall window.
    private var billingActionRow: some View {
        let action = MenuBarBillingAction.resolve(
            state: entitlements.state,
            isPastDue: entitlements.managedSnapshot?.isPastDue == true,
            isLowBalance: isBalanceLow
        )
        return BillingActionRow(label: action.label, secondary: action.secondary) {
            entitlements.paywallTrigger = action.trigger
            AppDelegate.openPaywall()
            MenuBarExtraDismiss.dismiss()
        }
    }

    /// Phase F — tappable "verify your email to start your free trial" banner.
    /// Understated amber treatment like the managed nudge; opens the standalone
    /// verification window and closes the dropdown.
    private func trialVerifyBanner() -> some View {
        HStack(spacing: 0) {
            Text("Verify your email to start your free trial")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfBrandAccent)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            MenuBarExtraDismiss.dismiss()
            AppDelegate.openTrialEmailCapture()
        }
    }

    private func trialStatusLine(creditsRemaining credits: Int) -> some View {
        HStack(spacing: 0) {
            Text(Self.trialLineText(credits: credits))
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    /// The trial is a pool of server-funded CREDITS with no time limit, so the
    /// line shows the remaining balance — the only thing that bounds it. The
    /// unit is credits, never a flat generation count (§1.5): a generation's
    /// cost varies by model, so "N generations" would mislead.
    private static func trialLineText(credits: Int) -> String {
        credits == 1
            ? "1 free trial credit left"
            : "\(credits) free trial credits left"
    }

    // MARK: - Low-balance top-up / upgrade (multi-model 6B.4)

    /// True when the spendable balance has dropped to the low-balance nudge
    /// threshold (price-agnostic — charging is metered server-side). Managed
    /// reads the snapshot's combined plan+top-up balance (F4 — the same number
    /// the server's spend gate checks); BYOK/expired have no balance to nudge on.
    private var isBalanceLow: Bool {
        switch entitlements.state {
        case .managed:
            guard let snapshot = entitlements.managedSnapshot else { return false }
            return CreditDisplay.isLowBalance(balance: snapshot.creditsRemaining)
        case .trial(let credits):
            guard let credits else { return false }
            return CreditDisplay.isLowBalance(balance: credits)
        case .byok, .expired:
            return false
        }
    }

    /// Open/close delays for the hover-driven side panels (Recent Prompts,
    /// Microphone). The open delay is a hover-intent guard so brushing past
    /// the row doesn't flash the panel open; the (shorter) close delay lets
    /// the cursor cross the arrow gap from the row into the panel without it
    /// snapping shut.
    private static let panelOpenDelayMS = 250
    private static let panelCloseDelayMS = 180

    /// Debounced show/hide for a hover side panel. `hovered` is the desired
    /// state captured at call time (row OR panel hovered); after the matching
    /// delay it commits only if the live hover state still agrees — so a
    /// quick brush-past neither opens the panel nor leaves it lingering.
    private func updatePanelVisibility(
        hovered: Bool,
        isStillHovered: @escaping () -> Bool,
        setVisible: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(hovered ? Self.panelOpenDelayMS : Self.panelCloseDelayMS)
            )
            if isStillHovered() == hovered {
                setVisible(hovered)
            }
        }
    }

    private var menuDivider: some View {
        Divider()
            .overlay(Color.vfHairline)
            .padding(.vertical, 4)
    }

    #if DEBUG
    /// Header for the debug-only block. Styled like the other small section
    /// eyebrows; left-aligned full width.
    private var debugSectionTitle: some View {
        HStack(spacing: 0) {
            Text("DEBUG")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Continuous-polling toggle. A toggle can't ride a `MenuRow` (its
    /// trailing slot only does hotkey/submenu), so this row matches the
    /// MenuRow label font + leading inset (16 = 6 outer + 10 inner) by hand.
    private var debugPollRow: some View {
        HStack(spacing: 0) {
            Text("Poll continuously")
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
            Spacer(minLength: VFSpacing.lg)
            Toggle("", isOn: $isPolling)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isPolling) { _, newValue in
                    if newValue { permissions.startPolling() }
                    else { permissions.stopPolling() }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
    #endif
}

// MARK: - MenuBarExtraDismiss
//
// Programmatically closes the `MenuBarExtra(.window)` dropdown. The
// `.window` style hosts content in a persistent NSPanel that does NOT
// auto-dismiss when focus moves to another window (unlike the legacy
// NSMenu-style dropdown), so any row that navigates elsewhere — e.g.
// Preferences opening the Settings window, or a Copy action — has to
// close the dropdown itself, otherwise it lingers on top of whatever
// just opened.
//
// We close it by clicking the STATUS-ITEM BUTTON rather than ordering the
// panel out. `orderOut` hides the panel but leaves SwiftUI's own
// presented-state toggle "on" (and the button highlighted) — so the icon
// stays selected and the next click just toggles back "off", needing a
// second click to re-open. `performClick` goes through the same path a
// real click would, so SwiftUI's state and the button highlight both
// reset and a single click re-opens the menu as expected.

@MainActor
enum MenuBarExtraDismiss {
    static func dismiss() {
        // Only act when the dropdown is actually open — otherwise clicking
        // the status button would OPEN it.
        let isOpen = NSApp.windows.contains {
            String(describing: type(of: $0)).contains("MenuBarExtra") && $0.isVisible
        }
        guard isOpen else { return }

        if let button = statusItemButton() {
            button.performClick(nil)
        } else {
            // Fallback: hide the panel directly. The double-click-to-reopen
            // quirk may return, but the dropdown still closes. Match is
            // narrow ("MenuBarExtra") so we never order the status-item
            // window out and lose the icon.
            for window in NSApp.windows
            where String(describing: type(of: window)).contains("MenuBarExtra") {
                window.orderOut(nil)
            }
        }
    }

    /// The MenuBarExtra's status-item button, searched across the app's
    /// windows (it lives in an NSStatusBarWindow). The app has exactly one
    /// status item, so the first match is the right one.
    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = firstStatusButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func firstStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = firstStatusButton(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - MenuMetrics

/// Shared layout metrics for every hover-highlightable row in the
/// menu-bar dropdown AND its trailing submenu flyouts (Model /
/// Microphone / Recent Prompts / Entitlement), so all row variants
/// render an identical highlight.
///
/// Concentric-corner rule: the row highlight's curve should follow the
/// container's curve with even margin, i.e. innerRadius =
/// containerRadius − inset. The highlight radius is derived from the
/// self-drawn flyout chrome (10pt − 5pt inset = 5pt) and shared by the
/// main panel's rows so the two surfaces read as one menu system.
/// `containerVerticalPadding` matches the horizontal inset so the
/// first/last row highlights nest into the chrome's curved corners
/// instead of clashing with them.
enum MenuMetrics {
    /// Measured chrome radius of the MenuBarExtra(.window) panel
    /// (probe-measured on macOS 26 by fitting the window alpha-mask
    /// boundary). Used by the preview chrome stand-in.
    static let panelCornerRadius: CGFloat = 16
    /// Gap between the container edge and the highlight edge.
    static let rowHorizontalInset: CGFloat = 5
    /// Corner radius of the self-drawn flyout container (SubmenuChrome
    /// / .submenuFlyout — a chromeless child panel styled like a native
    /// NSMenu, so this radius is ours to pick, unlike the OS-drawn
    /// panel chrome above).
    static let submenuCornerRadius: CGFloat = 10
    /// Row highlight radius, concentric inside the flyout chrome
    /// (submenuCornerRadius − rowHorizontalInset). The main panel's
    /// rows deliberately use the same value as the flyout rows.
    static let rowCornerRadius: CGFloat = submenuCornerRadius - rowHorizontalInset
    /// Padding between the highlight edge and the row content. Chosen
    /// so content stays 16pt from the container edge (the pre-metrics
    /// 6pt inset + 10pt padding).
    static let rowHorizontalPadding: CGFloat = 16 - rowHorizontalInset
    static let rowVerticalPadding: CGFloat = 5
    /// Top/bottom padding of the container content stack; equals the
    /// horizontal inset so corner nesting is uniform.
    static let containerVerticalPadding: CGFloat = rowHorizontalInset
}

// MARK: - MenuRow

enum RowTrailing {
    case none
    case hotkey(String)
    case submenu
}

struct MenuRow: View {
    let label: String
    var trailing: RowTrailing = .none
    var forceSelected: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void = {}

    @State private var isHovered = false

    private var isSelected: Bool { !isDisabled && (isHovered || forceSelected) }

    private var labelColor: Color {
        if isDisabled { return Color.vfTextTertiary }
        return Color.vfTextPrimary
    }

    private var trailingColor: Color {
        if isDisabled { return Color.vfTextTertiary.opacity(0.6) }
        return isSelected ? Color.vfTextPrimary.opacity(0.75) : Color.vfTextTertiary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(labelColor)
                    .fixedSize()

                Spacer(minLength: VFSpacing.lg)

                trailingView
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .hotkey(let symbols):
            Text(symbols)
                .font(.system(size: 12))
                .foregroundStyle(trailingColor)
                .fixedSize()
        case .submenu:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(trailingColor)
        }
    }
}

// MARK: - BillingActionRow
//
// The single consolidated billing row's view. Like CopyLastPromptRow it can
// carry a smaller secondary line below the label (the folded-in past-due
// warning), so it breaks the uniform tight row height only when there's a
// nudge to show; otherwise it reads as an ordinary MenuRow.

private struct BillingActionRow: View {
    let label: String
    var secondary: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfWarningAmber)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - CopyLastPromptRow
//
// The one row that breaks the uniform tight row height — main label
// plus a smaller dimmer secondary preview line below showing which
// prompt will be copied. Phase 11: reads the most-recent entry from the
// RecentPromptStore in the environment; clicking copies that prompt's
// full body to the clipboard. When the history is empty the row renders
// disabled with a "No prompts yet" preview line.

private struct CopyLastPromptRow: View {
    @Environment(RecentPromptStore.self) private var recentPrompts
    @State private var isHovered = false

    private var entry: RecentPrompt? { recentPrompts.mostRecent }

    private var isDisabled: Bool { entry == nil }
    private var isActive: Bool { isHovered && !isDisabled }

    private var primaryColor: Color {
        isDisabled ? Color.vfTextTertiary : Color.vfTextPrimary
    }

    private var secondaryColor: Color {
        if isDisabled { return Color.vfTextTertiary.opacity(0.7) }
        return isActive ? Color.vfTextPrimary.opacity(0.85) : Color.vfTextSecondary
    }

    var body: some View {
        Button(action: copyToClipboard) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Copy last prompt")
                    .font(.system(size: 13))
                    .foregroundStyle(primaryColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry?.title ?? "No prompts yet")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isActive ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }

    private func copyToClipboard() {
        guard let entry else { return }
        // Phase 5: per-type payload, same semantics as the live pill —
        // artifact body / chat text / raw fallback.
        Pasteboard.copy(entry.copyPayload)
        // Close the dropdown once the prompt is on the clipboard.
        MenuBarExtraDismiss.dismiss()
    }
}

// MARK: - Recent Prompts submenu
//
// Real submenu wiring landed in Phase 11. The view reads the
// RecentPromptStore from the environment and renders the most recent
// entries (capped at `displayCap` to keep the floating panel scannable —
// older entries are still available in the Settings History tab). Each
// row copies the underlying prompt body to the clipboard on click.
//
// Note on the `MenuBarExtra(.window)` constraint: `MenuBarExtra` with
// `.window` style hosts a SwiftUI panel, not a real NSMenu, so genuine
// "open a sibling NSMenu on hover" isn't available. The Recent Prompts
// row presents this view as a trailing `.submenuFlyout` instead — a
// chromeless child panel styled like an NSMenu submenu (see
// SubmenuFlyout.swift) — and each row copies its prompt body to the
// clipboard, then dismisses the flyout.

struct RecentPromptsSubmenu: View {
    @Environment(RecentPromptStore.self) private var recentPrompts

    /// Cap on items rendered in the submenu. The Settings History tab
    /// is the full-list surface; this is the quick-access affordance.
    private static let displayCap = 8

    private var items: [RecentPrompt] {
        Array(recentPrompts.prompts.prefix(Self.displayCap))
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                RecentPromptsEmptyState()
            } else {
                ForEach(items) { entry in
                    RecentPromptSubmenuRow(entry: entry)
                }
            }
        }
        .frame(width: 280)
    }
}

private struct RecentPromptsEmptyState: View {
    var body: some View {
        Text("No prompts yet")
            .font(.system(size: 12))
            .foregroundStyle(Color.vfTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

private struct RecentPromptSubmenuRow: View {
    let entry: RecentPrompt

    @Environment(\.submenuDismiss) private var dismiss
    @State private var isHovered = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 0) {
                // Phase 5: artifact-type glyph (chat bubble for chat-only)
                // so the submenu scans by result kind.
                Image(systemName: entry.displayIconName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    // Gutter sized to contain the WIDEST glyph (the `</>`
                    // snippet symbol overflows a 16pt slot), with a dedicated
                    // gap before the title so no glyph butts against the text.
                    .frame(width: 18, alignment: .leading)
                    .padding(.trailing, VFSpacing.sm)

                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: VFSpacing.lg)

                Text("Copy")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? Color.vfTextPrimary.opacity(0.75) : Color.vfTextTertiary)
                    .fixedSize()
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func copy() {
        // Phase 5: per-type payload, same semantics as the live pill.
        Pasteboard.copy(entry.copyPayload)
        // Close the side panel, then the whole dropdown, once the prompt is
        // on the clipboard.
        dismiss()
        MenuBarExtraDismiss.dismiss()
    }
}

// MARK: - MicrophonePicker
//
// Input-device picker presented as the Microphone row's trailing popover.
// Mirrors the Settings Capture picker's enumeration (.microphone +
// .external, audio) and writes the selection straight to
// PreferencesStore.microphoneDeviceID — empty string is the "System
// Default" sentinel. Selecting a device dismisses the panel.

private struct MicrophonePicker: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.submenuDismiss) private var dismiss

    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        VStack(spacing: 0) {
            row(id: "", name: "System Default")
            ForEach(devices, id: \.uniqueID) { device in
                row(id: device.uniqueID, name: device.localizedName)
            }
        }
        .frame(width: 260)
        .onAppear(perform: refreshDevices)
    }

    private func row(id: String, name: String) -> some View {
        MicrophonePickerRow(name: name, isSelected: isSelected(id)) {
            preferences.microphoneDeviceID = id
            dismiss()
        }
    }

    /// True when `id` is the active selection. A stored id that no longer
    /// resolves to a connected device falls back to "System Default",
    /// matching the Settings picker's behavior.
    private func isSelected(_ id: String) -> Bool {
        let stored = preferences.microphoneDeviceID
        let effective = devices.contains(where: { $0.uniqueID == stored }) ? stored : ""
        return effective == id
    }

    private func refreshDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = session.devices
    }
}

private struct MicrophonePickerRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#if DEBUG
// MARK: - EntitlementDebugPicker
//
// Phase A debug surface, presented as the Entitlement row's trailing
// popover — the same hover-driven submenu shape as Recent Prompts and the
// Microphone picker. One row per forceable `EntitlementState` (sourced
// from `EntitlementStore.devStates`), the active one checkmarked. This is
// the ONLY force-entitlement surface — the paywall's copy was removed as
// redundant. Selecting a state sets the shared store and dismisses the
// panel.

private struct EntitlementDebugPicker: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.submenuDismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ForEach(EntitlementStore.devStates, id: \.label) { item in
                EntitlementDebugRow(
                    name: item.label,
                    isSelected: entitlements.devMatches(item.state)
                ) {
                    entitlements.devSetState(item.state)
                    dismiss()
                }
            }
            // Phase E: overlay a `past_due` snapshot on the current Managed
            // state so the "update your card" nudge (§9.1) is testable.
            EntitlementDebugRow(
                name: "Managed · Past due",
                isSelected: entitlements.managedSnapshot?.isPastDue == true
            ) {
                entitlements.devForceManagedPastDue()
                dismiss()
            }
        }
        .frame(width: 220)
    }
}

private struct EntitlementDebugRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#endif

// MARK: - Previews
//
// Both previews wrap the panel(s) in a vibrancy material + hairline +
// rounded corners so the surface reads like an NSMenu in isolation.
// In production, `MenuBarExtra(.window)` provides this chrome from the
// OS — the panel content itself stays naked.

private struct MenuPanelChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MenuMetrics.panelCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MenuMetrics.panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// Pre-seeded history used by the previews so the submenu/Paste-last
/// row render with realistic data without writing to the user's actual
/// Application Support directory.
@MainActor
private func previewRecentPromptStore() -> RecentPromptStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerro-preview-history-\(UUID().uuidString).json")
    let store = RecentPromptStore(fileURL: url)
    store.add(prompt: "Polish the Pulse login form so the password field aligns with the submit button.")
    store.add(prompt: "Debug the React hydration error firing on the dashboard route.")
    store.add(prompt: "Summarize Tuesday\u{2019}s standup into three bullets.")
    store.add(prompt: "Redesign the onboarding flow to land the user in the editor faster.")
    store.add(prompt: "Fix the nav overflow bug at the 768px breakpoint.")
    return store
}

// `EntitlementStore.preview` pins the state via the dev override (DEBUG-only),
// so these previews are `#if DEBUG`-guarded — `#Preview` bodies otherwise
// compile in Release too.
#if DEBUG
#Preview("Dropdown \u{00B7} Trial") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            // A trial with 12 server-funded generations left → the quiet
            // "12 free generations left" line. In-memory; no real Keychain.
            .environment(EntitlementStore.preview(.trial(creditsRemaining: 12)))
            .environmentObject(UpdaterViewModel())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Dropdown \u{00B7} Submenu open") {
    HStack(alignment: .top, spacing: 6) {
        MenuPanelChrome {
            MenuBarPanelView(highlightRecentPrompts: true)
                .environment(AppState())
                .environment(previewRecentPromptStore())
                .environment(EntitlementStore.preview(.trial(creditsRemaining: 12)))
                .environmentObject(UpdaterViewModel())
        }

        // Native NSMenu aligns the submenu's top with the selected
        // parent row's top. The Recent Prompts row is the 6th
        // body item (after header, divider, Open, Check, divider,
        // Paste last prompt) — vertical offset approximates that.
        MenuPanelChrome {
            RecentPromptsSubmenu()
                .environment(previewRecentPromptStore())
        }
        .padding(.top, 130)
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

// Confirms the trial line is HIDDEN outside `.trial`.
#Preview("Dropdown \u{00B7} Expired (no trial line)") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            .environment(EntitlementStore.preview(.expired))
            .environmentObject(UpdaterViewModel())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Dropdown \u{00B7} Trial last generation") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            // One credit left → verifies the singular "1 free generation left" copy.
            .environment(EntitlementStore.preview(.trial(creditsRemaining: 1)))
            .environmentObject(UpdaterViewModel())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

// Header subtitle reconciliation: Managed is the only state with a real
// credit count; BYOK shows just "Ready" (no credits concept).
#Preview("Dropdown \u{00B7} Managed (credits)") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            .environment(EntitlementStore.preview(
                .managed(creditsRemaining: 142, resetDate: .now)
            ))
            .environmentObject(UpdaterViewModel())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Dropdown \u{00B7} BYOK (no credits)") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            .environment(EntitlementStore.preview(.byok))
            .environmentObject(UpdaterViewModel())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}
#endif
