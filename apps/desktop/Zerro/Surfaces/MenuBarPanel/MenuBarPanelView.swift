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
    #endif

    // `openSettings` is the modern (macOS 14+) idiomatic way to surface the
    // Settings scene. We're on macOS 26+, so no AppKit selector fallback is
    // shipped. NSApp.activate is paired with the call because LSUIElement
    // apps don't always come forward on their own when a window opens.
    @Environment(\.openSettings) private var openSettings

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
                openSettings()
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
                // run-through is one click away.
                onboarding.hasCompletedOnboarding = false
                onboarding.currentStep = .welcome
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: OnboardingScene.windowID)
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
// `⌃⌘V` is right-aligned on the main label row only.

private struct PasteLastPromptRow: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            // Phase 2.5: no behavior yet.
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text("Paste last prompt")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vfTextPrimary)
                        .fixedSize()
                    Spacer(minLength: VFSpacing.lg)
                    Text("\u{2303}\u{2318}V")
                        .font(.system(size: 12))
                        .foregroundStyle(isHovered ? Color.vfTextPrimary.opacity(0.75) : Color.vfTextTertiary)
                        .fixedSize()
                }
                Text("Polish the Pulse login form\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? Color.vfTextPrimary.opacity(0.85) : Color.vfTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

// MARK: - Recent Prompts submenu (preview-only)
//
// In production the submenu would be its own floating panel with native
// NSMenu interaction. For Phase 2.5 this struct is composed into a
// side-by-side `#Preview` to spec the visual shape.

struct RecentPromptsSubmenu: View {
    private let items: [String] = [
        "Polish the Pulse login form\u{2026}",
        "Debug the React hydration error\u{2026}",
        "Summarize Tuesday\u{2019}s standup",
        "Redesign the onboarding flow\u{2026}",
        "Fix the nav overflow bug\u{2026}"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                RecentPromptSubmenuRow(label: item)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280)
    }
}

private struct RecentPromptSubmenuRow: View {
    let label: String

    @State private var isHovered = false

    var body: some View {
        Button {
            // Phase 2.5: no behavior yet.
        } label: {
            HStack(spacing: 0) {
                Text(label)
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

#Preview("Dropdown") {
    MenuPanelChrome {
        MenuBarPanelView()
            .environment(AppState())
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Dropdown \u{00B7} Submenu open") {
    HStack(alignment: .top, spacing: 6) {
        MenuPanelChrome {
            MenuBarPanelView(highlightRecentPrompts: true)
                .environment(AppState())
        }

        // Native NSMenu aligns the submenu's top with the selected
        // parent row's top. The Recent Prompts row is the 6th
        // body item (after header, divider, Open, Check, divider,
        // Paste last prompt) — vertical offset approximates that.
        MenuPanelChrome {
            RecentPromptsSubmenu()
        }
        .padding(.top, 130)
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}
