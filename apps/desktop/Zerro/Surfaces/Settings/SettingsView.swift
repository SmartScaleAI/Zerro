//
//  SettingsView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Phase 11 (revision 2) — single Hub-style Settings window matching
//  Wispr Flow's pattern: one chromeless window with in-window
//  navigation between sub-pages (Settings root ↔ Recent Prompts ↔ …).
//  Revision 2 replaced the stock SwiftUI `Settings { ... }` scene with
//  a custom Window (see ZerroApp + SettingsWindowChrome) so the dark
//  surface can bleed under the traffic-light buttons.
//
//  Layout:
//    SettingsView
//      ├── SettingsHeader              (always visible, centered)
//      └── route-driven content area:
//            • .root          → SettingsRootView (ScrollView of sections)
//            • .recentPrompts → SettingsSubpage(title: "Recent Prompts")
//                                  wrapping RecentPromptsView, with a
//                                  back chevron in the top-left of
//                                  the content area.
//
//  Why a route enum instead of NavigationStack: the spec accepts
//  either; the route enum gives us full control over back-button
//  placement and transition style without fighting NavigationStack's
//  built-in toolbar behavior in a window where we've already hidden
//  the title bar.
//

import SwiftUI

// MARK: - Route

enum SettingsRoute: Equatable {
    case root
    case recentPrompts
}

// MARK: - Root

struct SettingsView: View {
    @State private var route: SettingsRoute = .root

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()

            // Route-driven content area. Slide-in transition keeps the
            // navigation feeling like a push rather than a hard swap.
            Group {
                switch route {
                case .root:
                    SettingsRootView(route: $route)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .recentPrompts:
                    SettingsSubpage(title: "Recent Prompts") {
                        route = .root
                    } content: {
                        RecentPromptsView()
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: route)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Width is HARD-locked at the SwiftUI layer (all three of
        // min/ideal/max set to preferredWidth); NSWindow.minSize /
        // maxSize in applySettingsWindowChrome() enforces the same
        // floor at the AppKit layer so a drag never tries to widen the
        // window past 720pt. Height stays idealized — content scrolls
        // when there's more than the window can show.
        .frame(
            minWidth: SettingsScene.preferredWidth,
            idealWidth: SettingsScene.preferredWidth,
            maxWidth: SettingsScene.preferredWidth,
            minHeight: SettingsScene.minimumHeight,
            idealHeight: SettingsScene.preferredHeight
        )
        .background(Color.vfPanelBackground)
        .applySettingsWindowChrome()
    }
}

// MARK: - Root sections

private struct SettingsRootView: View {
    @Binding var route: SettingsRoute

    var body: some View {
        ScrollView {
            // Round 4: dropped the .padding(.top, 4) — the 32pt gap
            // between header and first section is now owned entirely
            // by SettingsHeader's .padding(.bottom, 32) so the spacing
            // doesn't drift if the route swaps.
            //
            // 28pt between sections + 32pt bottom padding (footer
            // breathes against the window edge). Outer horizontal
            // padding 24pt per the design rhythm.
            VStack(alignment: .leading, spacing: 28) {
                APIAuthSection()
                BillingSection()
                CaptureSection()
                OutputModeSection()
                HistorySection(onOpenRecentPrompts: { route = .recentPrompts })
                AppBehaviorSection()
                AboutSupportSection()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .padding(.top, 4)
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

#Preview("Root") {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerro-settings-preview-\(UUID().uuidString).json")
    let store = RecentPromptStore(fileURL: url)
    store.add(prompt: "Polish the Pulse login form.")
    return SettingsView()
        .environment(PreferencesStore())
        .environment(PermissionsManager())
        .environment(OnboardingState())
        .environment(LaunchAtLoginController())
        // Phase C: the Billing section reads the entitlement from the
        // environment. In-memory deps so the preview never touches the real
        // Keychain or network.
        .environment(EntitlementStore(trialManager: .inMemory(), licenseService: .inMemory()))
        .environment(store)
        .frame(width: 760, height: 820)
}
