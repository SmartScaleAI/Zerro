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
import SwiftUI

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

    /// Drives the Recent Prompts side panel (a trailing popover). Opened on
    /// hover via `recentRowHovered` / `recentPanelHovered`.
    @State private var showRecentPrompts = false
    @State private var recentRowHovered = false
    @State private var recentPanelHovered = false
    /// Drives the Microphone picker side panel (a trailing popover). Opened
    /// on hover via `micRowHovered` / `micPanelHovered`.
    @State private var showMicrophonePicker = false
    @State private var micRowHovered = false
    @State private var micPanelHovered = false

    #if DEBUG
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions
    /// Phase A: force any entitlement state from the menu-bar debug block.
    /// This is the always-reachable driver — the default dev state is
    /// `.trial`, so the paywall won't open on its own; forcing `.expired`
    /// here and pressing ⌘⇧R is how you open it the first time.
    @Environment(EntitlementStore.self) private var entitlements
    /// Drives the Entitlement picker side panel (a trailing popover),
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

            // Phase 17: transient indicator that the LAST result ran with a
            // pill-override mode rather than the selected one. Present only
            // while `effectiveOutputMode` is set (a Switch fired, until the
            // next return to idle), and scoped to "this one" so it never
            // reads as a change to the persisted default.
            if let effective = appState.effectiveOutputMode {
                modeOverrideIndicator(effective)
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
            // Side panel of recent prompts with per-row Copy buttons. A
            // trailing popover is the closest native shape to an NSMenu
            // submenu under MenuBarExtra(.window) (which can't host real
            // submenus). Opens on hover of the row or the panel; the content
            // reads RecentPromptStore from the environment, passed explicitly
            // so it resolves inside the popover's separate hosting context.
            .popover(isPresented: $showRecentPrompts, arrowEdge: .trailing) {
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
            // Same hover-opened trailing popover as Recent Prompts — the
            // input device list with the current selection checked.
            .popover(isPresented: $showMicrophonePicker, arrowEdge: .trailing) {
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

            MenuRow(label: "Send feedback")
            // Phase 14 / C3.4: Sparkle "Check for Updates…". Owns the
            // SPUStandardUpdaterController at app-launch lifetime (see
            // ZerroApp.updater @StateObject) — this view just reads it
            // out of the environment so the controller stays alive
            // when the dropdown closes.
            CheckForUpdatesView()
            MenuRow(label: "Preferences\u{2026}", trailing: .hotkey("\u{2318},")) {
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
            // Phase 17 manual trigger: arms the stub mode-switch detector
            // to "match" on the next recording's generation pass, so the
            // confirmation pill flow is testable end to end without real
            // detection. One-shot — consumed by that generation. The label
            // reflects the armed state (appState is @Observable).
            // DEFERRED Phase 18: real detection removes the need for this.
            MenuRow(label: appState.debugForceModeSwitchPill
                    ? "Mode-Switch Pill: Armed \u{2713}"
                    : "Force Mode-Switch Pill") {
                appState.debugForceModeSwitchPill = true
            }
            MenuRow(label: "Open Onboarding\u{2026}") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: OnboardingScene.windowID)
            }
            // Phase A: entitlement state forcing, collapsed into a single
            // hover-driven submenu (same shape as Recent Prompts /
            // Microphone) to keep the debug block compact. Force "Expired"
            // in the side panel, then ⌘⇧R (or Start Recording) to drive the
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
            .popover(isPresented: $showEntitlementPicker, arrowEdge: .trailing) {
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
        .padding(.vertical, 4)
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
    }

    // MARK: - Primary action row
    //
    // Single row that flips between "Start Recording" / "Stop Recording"
    // based on `AppState.isRecordingActive`, and disables itself during
    // `.processing` so the user can't kick off a new session while one
    // is in flight. The hotkey hint stays put — `⌘⇧R` is the binding
    // for both halves of the toggle.

    @ViewBuilder
    private var primaryRecordingRow: some View {
        if appState.isRecordingActive {
            MenuRow(label: "Stop Recording", trailing: .hotkey("\u{2318}\u{21E7}R")) {
                appState.stopRecording()
            }
        } else if appState.state == .processing {
            MenuRow(
                label: "Processing\u{2026}",
                trailing: .hotkey("\u{2318}\u{21E7}R"),
                isDisabled: true
            )
        } else {
            MenuRow(label: "Start Recording", trailing: .hotkey("\u{2318}\u{21E7}R")) {
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
                        .fill(Color.vfSuccessGreen)
                        .frame(width: 5, height: 5)
                    Text("Ready \u{00B7} 24 credits left")
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

    /// Phase 17 — transient "this result was switched" note. Echoes the
    /// confirmation pill's copy ("…for this one") and uses the same blue
    /// accent + double-arrow glyph so the two read as one signal. Cleared
    /// when `effectiveOutputMode` returns to nil on the next idle.
    private func modeOverrideIndicator(_ mode: OutputMode) -> some View {
        HStack(spacing: VFSpacing.sm) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vfAccentBlue)
            Text("Switched to \(mode.displayName) for this one")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }

    private func copyToClipboard() {
        guard let entry else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.prompt, forType: .string)
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
// row presents this view as a trailing `.popover` instead — the closest
// native shape to a submenu — and each row copies its prompt body to the
// clipboard, then dismisses the popover.

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
        .padding(.vertical, 4)
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

    @Environment(\.dismiss) private var dismiss
    @State private var isHovered = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 0) {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.prompt, forType: .string)
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
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        VStack(spacing: 0) {
            row(id: "", name: "System Default")
            ForEach(devices, id: \.uniqueID) { device in
                row(id: device.uniqueID, name: device.localizedName)
            }
        }
        .padding(.vertical, 4)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
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
// from `EntitlementStore.devStates` so this and the paywall dev panel stay
// in sync), the active one checkmarked. Selecting a state sets the shared
// store and dismisses the panel.

private struct EntitlementDebugPicker: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

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
        .padding(.vertical, 4)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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

#Preview("Dropdown") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
            .environment(previewRecentPromptStore())
            .environment(EntitlementStore())
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
                .environment(EntitlementStore())
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
