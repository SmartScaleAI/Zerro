//
//  HistorySection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 (revision 2) — History section of the redesigned Settings
//  layout. Two rows:
//    1. Recent Prompts — navigation row that swaps the Settings
//       content area to the in-window Recent Prompts view. Revision 2
//       changed this from opening a separate NSWindow to in-window
//       navigation (see SettingsView's route enum); the row's chevron
//       still signals "leads somewhere," but the destination renders
//       inside the same window now.
//    2. Clear History — destructive button behind an NSAlert
//       confirmation; calls RecentPromptStore.clear() on confirm.
//
//  The store itself is shared with the menu-bar surfaces, so a Clear
//  here also empties the Paste-last row and submenu.
//

import AppKit
import SwiftUI

struct HistorySection: View {
    @Environment(RecentPromptStore.self) private var recentPrompts

    /// Wired by the parent SettingsView to swap the route to
    /// `.recentPrompts`. Keeping the navigation as a callback (rather
    /// than reaching into the route enum here) keeps the section
    /// reusable in the same shape the rest of the codebase uses for
    /// cross-view actions.
    var onOpenRecentPrompts: () -> Void = {}

    var body: some View {
        SettingsSection("History") {
            SettingsNavigationRow(
                label: "Recent Prompts",
                description: "Browse and re-copy your last prompts."
            ) {
                onOpenRecentPrompts()
            }

            SettingsRowDivider()

            SettingsRow(
                label: "Clear History",
                description: "Permanently deletes every saved prompt. You'll be asked to confirm first."
            ) {
                Button("Clear History...", action: confirmAndClear)
                    .buttonStyle(SettingsDestructiveButtonStyle())
                    .disabled(recentPrompts.prompts.isEmpty)
            }
        }
    }

    private func confirmAndClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all saved prompts?"
        alert.informativeText = "This removes every prompt from your history. The change can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            recentPrompts.clear()
        }
    }
}

#Preview {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerro-history-section-preview-\(UUID().uuidString).json")
    let store = RecentPromptStore(fileURL: url)
    store.add(prompt: "Polish the Pulse login form.")
    return HistorySection()
        .environment(store)
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
