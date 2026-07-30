//
//  SettingsView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Phase 11 (revision 3) — Wispr-Flow-style sidebar Settings window.
//  Revision 2 was a single ScrollView stacking all seven sections;
//  revision 3 splits that surface into a left navigation sidebar +
//  swappable detail pane (the layout Wispr Flow's Settings uses). The
//  seven section views are unchanged — only how they're grouped and
//  navigated changed.
//
//  Layout:
//    SettingsView
//      └── HStack
//            ├── SettingsSidebar           (fixed 188pt — logo + 2 groups)
//            ├── hairline divider
//            └── detail pane:
//                  • a category pane → ScrollView of that category's
//                    section view(s)
//                  • History + route == .recentPrompts →
//                    SettingsSubpage(title: "Recent Results") wrapping
//                    RecentPromptsView, with a back chevron + Escape.
//
//  The five categories (SETTINGS / ACCOUNT groups) regroup the seven
//  sections; see `SettingsCategory`. Width is still hard-locked (now
//  880pt — widened from 720 so the sidebar doesn't crush each row's
//  description column) in three places: this view's .frame, plus
//  minSize/maxSize and setContentSize in applySettingsWindowChrome.
//
//  Why a custom HStack sidebar instead of NavigationSplitView: the
//  window is chromeless and width-hard-locked, and the sidebar needs the
//  app's own dark selection/hover treatment (not NavigationSplitView's
//  translucent system material + sidebar-toggle toolbar). A plain HStack
//  gives exact 188 / 1 / 531 width math and full styling control without
//  fighting the split view's defaults under `.hiddenTitleBar`.
//

import SwiftUI

// MARK: - Route

enum SettingsRoute: Equatable {
    case root
    case recentPrompts
}

// MARK: - Categories

/// The five sidebar categories, in two labeled groups. Each maps to the
/// section view(s) it shows in the detail pane (see `SettingsView.pane`).
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case history
    case advanced
    case accountBilling
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:        return "General"
        case .history:        return "History"
        case .advanced:       return "Advanced"
        case .accountBilling: return "Account & Billing"
        case .about:          return "About"
        }
    }

    /// Leading SF Symbol shown in the sidebar row.
    var icon: String {
        switch self {
        case .general:        return "slider.horizontal.3"
        case .history:        return "clock.arrow.circlepath"
        case .advanced:       return "gearshape.2"
        case .accountBilling: return "person.crop.circle"
        case .about:          return "info.circle"
        }
    }

    static let settingsGroup: [SettingsCategory] = [.general, .history, .advanced]
    static let accountGroup: [SettingsCategory] = [.accountBilling, .about]
}

// MARK: - Root

struct SettingsView: View {
    @State private var selection: SettingsCategory = .general
    @State private var route: SettingsRoute = .root

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: SettingsScene.sidebarWidth)

            // Hairline between the sidebar and the detail pane. Both
            // surfaces share vfPanelBackground, so this 0.5pt line is the
            // only visual seam — consistent with the card hairlines.
            Rectangle()
                .fill(Color.vfHairline)
                .frame(width: 1)

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Only the Recent Prompts push/pop animates; switching
                // categories is an instant swap (driven by `.id` below).
                .animation(.easeInOut(duration: 0.22), value: route)
        }
        // Width is HARD-locked at the SwiftUI layer (all three of
        // min/ideal/max set to preferredWidth); NSWindow.minSize /
        // maxSize in applySettingsWindowChrome() enforces the same
        // floor at the AppKit layer so a drag never tries to widen the
        // window past preferredWidth. Height stays idealized — content
        // scrolls when there's more than the window can show.
        .frame(
            minWidth: SettingsScene.preferredWidth,
            idealWidth: SettingsScene.preferredWidth,
            maxWidth: SettingsScene.preferredWidth,
            minHeight: SettingsScene.minimumHeight,
            idealHeight: SettingsScene.preferredHeight
        )
        .background(Color.vfPanelBackground)
        .applySettingsWindowChrome()
        // Leaving the History pane (or any category swap) drops any
        // pushed subpage so the new pane always opens at its root.
        .onChange(of: selection) { _, _ in route = .root }
        // Deep-link preselect: a caller (e.g. the BYOK purchase-success "Open
        // Settings" button) can stash a category to land on. Read + clear it once
        // when the window appears.
        .onAppear {
            if let pending = AppDelegate.pendingSettingsCategory {
                AppDelegate.pendingSettingsCategory = nil
                selection = pending
            }
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailContent: some View {
        if selection == .history && route == .recentPrompts {
            SettingsSubpage(title: "Recent Results") {
                route = .root
            } content: {
                RecentPromptsView()
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            pane
                // New identity per category resets the ScrollView's
                // scroll position when the user switches categories.
                .id(selection)
        }
    }

    /// The scrolling content for the currently-selected category. Same
    /// composition the old single-pane root used (28pt between sections,
    /// 24pt horizontal / 32pt bottom rhythm), sliced into five stacks.
    @ViewBuilder
    private var pane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch selection {
                case .general:
                    CaptureSection()
                    AppearanceSection()
                case .history:
                    HistorySection(onOpenRecentPrompts: { route = .recentPrompts })
                case .advanced:
                    AppBehaviorSection()
                case .accountBilling:
                    // Multi-model 6E: ONE mode at a time (Managed or BYOK)
                    // with a switch link — never the old API-key + license
                    // stack. The pane owns its internal section rhythm.
                    AccountBillingPane()
                case .about:
                    AboutSupportSection()
                }
            }
            // No full-width header bar above the pane anymore (the logo
            // moved into the sidebar), so the pane owns its own top
            // breathing room.
            .padding(.top, 24)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                // ~28pt top clearance keeps the logo clear of the
                // traffic-light buttons floating over the chromeless
                // surface (which sit over the sidebar's top-left).
                .padding(.top, 28)
                .padding(.horizontal, 16)
                .padding(.bottom, 22)

            group("Settings", items: SettingsCategory.settingsGroup)

            group("Account", items: SettingsCategory.accountGroup)
                .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.vfPanelBackground)
    }

    /// Wispr-style logo + wordmark anchored at the top of the sidebar
    /// (replaces the old centered full-width SettingsHeader bar).
    private var sidebarHeader: some View {
        HStack(spacing: VFSpacing.sm) {
            logoTile
            Text("Zerro")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
        }
    }

    /// 24pt dark badge with the white Zerro mark — matches the treatment
    /// the old SettingsHeader used on this dark surface.
    private var logoTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.vfPillBackground)
            Image("MenuBarLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.vfTextPrimary)
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private func group(_ title: String, items: [SettingsCategory]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Same treatment as SettingsSection headers: 11pt semibold,
            // 0.88 tracking, uppercase, secondary text.
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.88)
                .foregroundStyle(Color.vfTextSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            ForEach(items) { item in
                SidebarRow(
                    category: item,
                    isSelected: selection == item
                ) {
                    selection = item
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct SidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.vfTextPrimary : Color.vfTextSecondary)
                    .frame(width: 18)
                Text(category.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.vfTextPrimary : Color.vfTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // Selection / hover treatment consistent with
            // SettingsNavigationRow's white-opacity fills.
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fillColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var fillColor: Color {
        if isSelected { return Color.vfControlBackground }
        if isHovered { return Color.white.opacity(0.03) }
        return Color.clear
    }
}

// MARK: - Subpage chrome
//
// Common chrome for any pushed sub-page: a custom back chevron rendered
// in the top-left of the content area (not the title bar), an inline
// page title next to it, then the page's content below. Callers supply
// the title, the dismiss action (route = .root), and the body view.

struct SettingsSubpage<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: VFSpacing.sm) {
                BackChevron(action: onBack)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer()
            }
            .padding(.horizontal, VFSpacing.xxl)
            .padding(.top, VFSpacing.xl)
            .padding(.bottom, VFSpacing.md)

            content()
                .padding(.horizontal, VFSpacing.lg)
                .padding(.bottom, VFSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BackChevron: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.vfTextPrimary : Color.vfTextSecondary)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Back to Settings")
        .keyboardShortcut(.escape, modifiers: [])
    }
}

// MARK: - Preview

#Preview("Sidebar") {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerro-settings-preview-\(UUID().uuidString).json")
    let store = RecentPromptStore(fileURL: url)
    store.add(prompt: "Polish the Pulse login form.")
    return SettingsView()
        .environment(PreferencesStore())
        .environment(LocalModelManager(preferences: PreferencesStore()))
        .environment(ProviderKeyPresence())
        .environment(PermissionsManager())
        .environment(OnboardingState())
        .environment(LaunchAtLoginController())
        // Phase C: the Billing section reads the entitlement from the
        // environment. In-memory deps so the preview never touches the real
        // Keychain or network.
        .environment(EntitlementStore(licenseService: .inMemory()))
        .environment(store)
        .frame(width: SettingsScene.preferredWidth, height: SettingsScene.preferredHeight)
}
