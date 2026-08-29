//
//  MenuBarPanelView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Configuration shelf hosted by `MenuBarExtra(.window)`. The panel reads
//  Recording starts only from the dedicated Ask/Dev global shortcuts; this
//  panel links directly to their Settings pane. Active timer / spinner UI
//  still lives in the pill. Styling targets a native-looking NSMenu: tight
//  rows, full-row accent-blue fill with white text on hover (instant, no
//  animation), hotkey hints as plain dimmed trailing text, hairline
//  dividers.
//

import AppKit
import SwiftUI

// MARK: - MenuBarBillingAction

/// The label + optional secondary nudge + paywall trigger for the single,
/// always-present menu-bar billing row, resolved from the live entitlement.
/// Pure + `Equatable` so the
/// state → (label, trigger) mapping is unit-tested without the view.
///
/// Rules:
///   • `.localTrial`        → "Upgrade"     (voluntaryUpgrade) — trial still works.
///   • `.localTrialExpired` → "Upgrade"     (blocked) — the gated wall.
///   • `.byok`              → "Manage License" (manage) — devices/billing only.
struct MenuBarBillingAction: Equatable {
    let label: String
    /// A quiet secondary line under the label. `nil` hides it.
    let secondary: String?
    let trigger: EntitlementStore.PaywallTrigger

    static func resolve(state: EntitlementState) -> MenuBarBillingAction {
        switch state {
        case .localTrial:
            return MenuBarBillingAction(label: "Upgrade", secondary: nil, trigger: .voluntaryUpgrade)
        case .localTrialExpired:
            return MenuBarBillingAction(label: "Upgrade", secondary: nil, trigger: .blocked)
        case .byok:
            return MenuBarBillingAction(label: "Manage License", secondary: nil, trigger: .manage)
        }
    }
}

struct MenuBarPanelView: View {
    /// When `true`, the Recent Prompts row renders in its selected state.
    /// Used by the submenu-flyout `#Preview` to show the parent row
    /// highlighted while the submenu is open.
    var highlightRecentPrompts: Bool = false

    @Environment(AppState.self) private var appState
    @Environment(PreferencesStore.self) private var preferences
    @Environment(RecentPromptStore.self) private var recentPrompts
    /// Read the entitlement so the dropdown can offer the Upgrade / Manage
    /// License row on official builds that are not yet licensed. The DEBUG
    /// entitlement picker below reads this same injected store.
    @Environment(EntitlementStore.self) private var entitlements

    /// Drives the Recent Prompts side panel (a trailing flyout). Opened on
    /// hover via `recentRowHovered` / `recentPanelHovered`.
    @State private var showRecentPrompts = false
    @State private var recentRowHovered = false
    @State private var recentPanelHovered = false
    /// Drives the Model picker side panel beside the Microphone picker.
    @State private var showModelPicker = false
    @State private var modelRowHovered = false
    @State private var modelPanelHovered = false
    /// Drives the Microphone picker side panel (a trailing flyout). Opened
    /// on hover via `micRowHovered` / `micPanelHovered`.
    @State private var showMicrophonePicker = false
    @State private var micRowHovered = false
    @State private var micPanelHovered = false
    /// Prefetched off the main actor when the menu opens. Keeping discovery out
    /// of `MicrophonePicker.onAppear` prevents AVFoundation enumeration from
    /// blocking the hover presentation and gives the flyout its full row count
    /// before its first size measurement in the common case.
    @State private var microphoneDevices: [MicDeviceList.Device] = []
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
        // Read the prefetched list while building this view so its arrival
        // invalidates the presenter and supplies a new, fully sized root view.
        let prefetchedMicrophoneDevices = microphoneDevices

        VStack(spacing: 0) {
            header

            // Quiet "N days left" line. Shown while the local trial is
            // active; hidden once licensed or expired (the header status
            // carries those).
            if case .localTrial(let daysRemaining) = entitlements.state {
                localTrialStatusLine(daysRemaining: daysRemaining)
            }

            menuDivider

            // Recent Results reads RecentPromptStore directly and never
            // consults EntitlementStore.canGenerate — reading/copying past
            // prompts stays open in every entitlement state, `.localTrialExpired`
            // included. Only the recording START path (handleHotkey) gates;
            // do not add an entitlement check to this row.
            MenuRow(
                label: "Recent Results",
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

            MenuRow(label: "Shortcuts…") {
                MenuBarExtraDismiss.dismiss()
                AppDelegate.openSettings(to: .shortcuts)
            }
            MenuRow(
                label: "Model",
                trailing: .submenu,
                forceSelected: showModelPicker
            ) {
                showMicrophonePicker = false
                showModelPicker = true
            }
            .onHover { hovering in
                modelRowHovered = hovering
                if hovering { showMicrophonePicker = false }
                updatePanelVisibility(
                    hovered: modelRowHovered || modelPanelHovered,
                    isStillHovered: { modelRowHovered || modelPanelHovered },
                    setVisible: { showModelPicker = $0 }
                )
            }
            .submenuFlyout(isPresented: $showModelPicker) {
                ModelPicker()
                    .environment(preferences)
                    .environment(entitlements)
                    .onHover { hovering in
                        modelPanelHovered = hovering
                        updatePanelVisibility(
                            hovered: modelRowHovered || modelPanelHovered,
                            isStillHovered: { modelRowHovered || modelPanelHovered },
                            setVisible: { showModelPicker = $0 }
                        )
                    }
            }
            MenuRow(
                label: "Microphone",
                trailing: .submenu,
                forceSelected: showMicrophonePicker
            ) {
                showMicrophonePicker = true
            }
            .onHover { hovering in
                micRowHovered = hovering
                if hovering { showModelPicker = false }
                updatePanelVisibility(
                    hovered: micRowHovered || micPanelHovered,
                    isStillHovered: { micRowHovered || micPanelHovered },
                    setVisible: { showMicrophonePicker = $0 }
                )
            }
            // Same hover-opened trailing flyout as Recent Prompts — the
            // input device list with the current selection checked.
            .submenuFlyout(isPresented: $showMicrophonePicker) {
                MicrophonePicker(devices: prefetchedMicrophoneDevices)
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
                SupportEmail.open()
                MenuBarExtraDismiss.dismiss()
            }
            // Phase 14 / C3.4: Sparkle "Check for Updates…". Owns the
            // SPUStandardUpdaterController at app-launch lifetime (see
            // ZerroApp.updater @StateObject) — this view just reads it
            // out of the environment so the controller stays alive
            // when the dropdown closes.
            CheckForUpdatesView()
            // The billing entry point: label + paywall trigger vary by
            // state. Opens the (context-aware) paywall window. Shown only
            // while an official build has something to sell — hidden once
            // licensed (device management lives in Settings) and in community
            // builds (no license is required).
            if entitlements.enforcesLicensing && !entitlements.hasActiveLicense {
                billingActionRow
            }
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
            // in the side panel, then the recording hotkey (⌥Space by
            // default) to drive the
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
        .task {
            await refreshMicrophoneDevices()
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
                HStack(spacing: 6) {
                    Text("Zerro")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                        .fixedSize()
                    // Staging-only: amber "STAGING" pill in the dropdown header
                    // so it's obvious which build's menu is open. Absent from the
                    // production binary.
                    #if STAGING
                    StagingBadge(fontSize: 9)
                    #endif
                }
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
    /// `.localTrial` deliberately reads just "Ready": the dedicated trial line
    /// directly below the header carries the "N days left" count, so showing
    /// it here too would be redundant.
    private var headerStatusText: String {
        switch entitlements.state {
        case .localTrial, .byok:
            return "Ready"
        case .localTrialExpired:
            return "Trial complete"
        }
    }

    /// Status dot: green while usable, dimmed once the trial has ended so
    /// the header reads as "inactive" without being alarming (no red).
    private var headerStatusColor: Color {
        switch entitlements.state {
        case .localTrialExpired:
            return Color.vfTextTertiary
        case .localTrial, .byok:
            return Color.vfSuccessGreen
        }
    }

    // MARK: - Consolidated billing entry point

    /// The single billing row. Its label + secondary nudge + paywall trigger
    /// are resolved from the live entitlement (see `MenuBarBillingAction`).
    /// Click sets the trigger (so the paywall's dynamic copy matches) and
    /// opens the context-aware paywall window.
    private var billingActionRow: some View {
        let action = MenuBarBillingAction.resolve(state: entitlements.state)
        return BillingActionRow(label: action.label, secondary: action.secondary) {
            entitlements.paywallTrigger = action.trigger
            AppDelegate.openPaywall()
            MenuBarExtraDismiss.dismiss()
        }
    }

    private func localTrialStatusLine(daysRemaining: Int) -> some View {
        HStack(spacing: 0) {
            Text(Self.localTrialLineText(daysRemaining: daysRemaining))
                .font(.system(size: 11))
                .foregroundStyle(
                    daysRemaining <= 3 ? Color.vfWarningAmber : Color.vfTextSecondary
                )
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    /// The local trial is a clock, so the line shows the remaining whole days
    /// — the only thing that bounds it. Singular/plural handled explicitly.
    static func localTrialLineText(daysRemaining: Int) -> String {
        daysRemaining == 1
            ? "Free trial \u{00B7} 1 day left"
            : "Free trial \u{00B7} \(daysRemaining) days left"
    }

    /// Open/close delays for the hover-driven side panels (Recent Prompts,
    /// Model, Microphone). The open delay is a hover-intent guard so brushing past
    /// the row doesn't flash the panel open; the (shorter) close delay lets
    /// the cursor cross the arrow gap from the row into the panel without it
    /// snapping shut.
    private static let panelOpenDelayMS = 100
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

    /// AVFoundation device discovery can occasionally take long enough to make
    /// a hover-opened menu feel stuck. Run it away from the main actor and only
    /// publish the small Sendable display values back into SwiftUI.
    private func refreshMicrophoneDevices() async {
        let devices = await Task.detached(priority: .userInitiated) {
            MicDeviceList.liveDevices()
        }.value
        guard !Task<Never, Never>.isCancelled else { return }
        microphoneDevices = devices
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
// The single consolidated billing row's view. It can carry a smaller secondary
// line below the label (the folded-in past-due warning), so it breaks the
// uniform tight row height only when there's a nudge to show; otherwise it
// reads as an ordinary MenuRow.

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
        Text("No results yet")
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

// MARK: - ModelPicker

/// Global generation-model picker. Selection persists immediately so the next
/// Ask or Dev recording uses it without needing an overlay-local control.
private struct ModelPicker: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.submenuDismiss) private var dismiss

    var body: some View {
        let availableProviders = ProviderKeys.availableProviders()

        VStack(spacing: 0) {
            ForEach(ModelRegistry.enabled) { model in
                ModelPickerRow(
                    name: model.displayName,
                    secondary: secondaryText(for: model, availableProviders: availableProviders),
                    isSelected: effectiveSelectedModelID(
                        availableProviders: availableProviders
                    ) == model.id,
                    isDisabled: isBYOKGated(model, availableProviders: availableProviders),
                    showsLock: false
                ) {
                    select(model)
                }
            }
        }
        .frame(width: 286)
    }

    private func effectiveSelectedModelID(
        availableProviders: Set<ModelProvider>
    ) -> String {
        ModelSelectionPolicy.effectiveModelID(
            persistedModelID: preferences.selectedModelID,
            entitlement: entitlements.state,
            availableProviders: availableProviders
        )
    }

    private func isBYOKGated(
        _ model: ModelEntry,
        availableProviders: Set<ModelProvider>
    ) -> Bool {
        ModelSelectionPolicy.isBYOKGated(
            model,
            entitlement: entitlements.state,
            availableProviders: availableProviders
        )
    }

    private func secondaryText(
        for model: ModelEntry,
        availableProviders: Set<ModelProvider>
    ) -> String? {
        if isBYOKGated(model, availableProviders: availableProviders) {
            return "Add \(model.provider.displayName) key"
        }
        return model.recommended ? "Recommended" : nil
    }

    private func select(_ model: ModelEntry) {
        let previous = preferences.selectedModelID
        if previous != model.id {
            Analytics.capture("model_changed", [
                "from_model": previous,
                "to_model": model.id,
                "surface": "menu_bar",
            ])
            preferences.selectedModelID = model.id
        }
        dismiss()
    }

}

private struct ModelPickerRow: View {
    let name: String
    let secondary: String?
    let isSelected: Bool
    let isDisabled: Bool
    let showsLock: Bool
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

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundStyle(isDisabled ? Color.vfTextTertiary : Color.vfTextPrimary)
                        .lineLimit(1)
                    if let secondary {
                        Text(secondary)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.vfTextTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: VFSpacing.sm)

                if showsLock {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.vfTextTertiary)
                }
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered && !isDisabled ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
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

    let devices: [MicDeviceList.Device]

    var body: some View {
        VStack(spacing: 0) {
            row(id: "", name: "System Default")
            ForEach(devices, id: \.id) { device in
                row(id: device.id, name: device.name)
            }
        }
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
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
        let effective = devices.contains(where: { $0.id == stored }) ? stored : ""
        return effective == id
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
#Preview("Dropdown \u{00B7} Free trial") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            // An active local trial → the quiet "N days left" line.
            // In-memory; no real Keychain.
            .environment(EntitlementStore.preview(.localTrial(daysRemaining: 12)))
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
                .environment(EntitlementStore.preview(.localTrial(daysRemaining: 12)))
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

// Confirms the trial line changes on expiry.
#Preview("Dropdown \u{00B7} Trial expired") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            .environment(EntitlementStore.preview(.localTrialExpired))
            .environmentObject(UpdaterViewModel())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

// A licensed user has no trial line and no upsell row.
#Preview("Dropdown \u{00B7} Licensed") {
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
