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
import SwiftUI

struct MenuBarPanelView: View {
    /// When `true`, the Recent Prompts row renders in its selected state.
    /// Used by the submenu-flyout `#Preview` to show the parent row
    /// highlighted while the submenu is open.
    var highlightRecentPrompts: Bool = false

    @Environment(AppState.self) private var appState

    #if DEBUG
    @Environment(OnboardingState.self) private var onboarding
    @Environment(PermissionsManager.self) private var permissions
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

            menuDivider

            MenuRow(label: "Open Zerro")
            MenuRow(label: "Check for updates\u{2026}")

            menuDivider

            PasteLastPromptRow()
            MenuRow(label: "Recent Prompts", trailing: .submenu, forceSelected: highlightRecentPrompts)

            menuDivider

            primaryRecordingRow
            MenuRow(label: "Microphone", trailing: .submenu)
            MenuRow(label: "Hotkey\u{2026}")

            menuDivider

            MenuRow(label: "Help Center")
            MenuRow(label: "Send feedback")

            menuDivider

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
            MenuRow(label: "Open Onboarding\u{2026}") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: OnboardingScene.windowID)
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
            PermissionsDebugSection()
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
                appState.startRecording()
            }
        }
    }

    // MARK: - Header row

    private var header: some View {
        HStack(spacing: VFSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.vfBrandAccent)
                Image("MenuBarLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(Color.vfOnBrand)
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

    private var menuDivider: some View {
        Divider()
            .overlay(Color.vfHairline)
            .padding(.vertical, 4)
    }
}

// MARK: - MenuBarExtraDismiss
//
// Programmatically hides the `MenuBarExtra(.window)` dropdown. The
// `.window` style hosts content in a persistent NSPanel that does NOT
// auto-dismiss when focus moves to another window (unlike the legacy
// NSMenu-style dropdown), so any row that navigates elsewhere — e.g.
// Preferences opening the Settings window — has to close the dropdown
// itself, otherwise it lingers on top of whatever just opened.
//
// Implementation notes:
// 1) We MUST match only the MenuBarExtra panel, NOT any window whose
//    class name merely contains "NSStatusBar" — the status-item BUTTON
//    is hosted in an NSStatusBarWindow too, and ordering THAT out
//    removes the menu bar icon itself (so clicking it no longer
//    shows the dropdown). Earlier iteration of this helper made
//    exactly that mistake.
// 2) We use `orderOut(_:)` rather than `close()`. `close()` can release
//    the panel and prevent SwiftUI from re-showing it; `orderOut(_:)`
//    just hides the panel so the next status-item click re-shows it
//    normally.
// 3) Match is intentionally narrow ("MenuBarExtra" substring). If a
//    future macOS renames the panel class, the failure mode is "the
//    dropdown stays open" — never "the icon disappears."

@MainActor
enum MenuBarExtraDismiss {
    static func dismiss() {
        for window in NSApp.windows {
            let className = String(describing: type(of: window))
            guard className.contains("MenuBarExtra") else { continue }
            window.orderOut(nil)
        }
    }
}

// MARK: - MenuRow

private enum RowTrailing {
    case none
    case hotkey(String)
    case submenu
}

private struct MenuRow: View {
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

// MARK: - PasteLastPromptRow
//
// The one row that breaks the uniform tight row height — main label
// plus a smaller dimmer secondary preview line below. Hotkey hint
// `⌃⌘V` is right-aligned on the main label row only. Phase 11: reads
// the most-recent entry from the RecentPromptStore in the environment;
// clicking copies that prompt's full body to the clipboard. When the
// history is empty the row renders disabled with a "No prompts yet"
// preview line.

private struct PasteLastPromptRow: View {
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

    private var hotkeyColor: Color {
        if isDisabled { return Color.vfTextTertiary.opacity(0.6) }
        return isActive ? Color.vfTextPrimary.opacity(0.75) : Color.vfTextTertiary
    }

    var body: some View {
        Button(action: copyToClipboard) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text("Paste last prompt")
                        .font(.system(size: 13))
                        .foregroundStyle(primaryColor)
                        .fixedSize()
                    Spacer(minLength: VFSpacing.lg)
                    Text("\u{2303}\u{2318}V")
                        .font(.system(size: 12))
                        .foregroundStyle(hotkeyColor)
                        .fixedSize()
                }
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
// "open a sibling NSMenu on hover" isn't available. This submenu still
// renders inline-via-#Preview in design previews; in production the
// row taps copy directly to the clipboard, which is the actual user
// goal anyway. A floating-panel implementation can come later if the
// hover-open shape becomes important.

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
    }
}

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
