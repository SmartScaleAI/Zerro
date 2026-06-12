//
//  RecentPromptsView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 (revision 2) — in-window view for browsing & re-copying
//  past prompts. Used to be a standalone Window scene; revision 2
//  moved it into the Settings window's route-driven content area so
//  Settings stays a single Hub-style window (no second NSWindow
//  spawned when the user clicks Recent Prompts).
//
//  Layout: HSplitView with a sidebar of entries on the left (title +
//  relative timestamp) and a detail pane on the right (full prompt body
//  with Copy and Delete affordances). Empty state matches the spec.
//
//  Note on store wiring: the spec mentioned a `PromptHistoryStore`
//  reading from Phase 8 working dirs, but Phase 8 explicitly cleans up
//  those dirs after processing (per AppState.runProcessing) — they were
//  never a durable source. Phase 11's `RecentPromptStore` writes
//  prompts at the moment they're generated to Application Support,
//  which IS durable; we reuse it here instead of re-deriving from a
//  source that's been wiped.
//

import AppKit
import SwiftUI

struct RecentPromptsView: View {
    @Environment(RecentPromptStore.self) private var recentPrompts

    @State private var selectedID: RecentPrompt.ID?
    @State private var didCopyTickID: UUID?

    var body: some View {
        Group {
            if recentPrompts.prompts.isEmpty {
                emptyState
            } else {
                splitView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: ensureSelection)
        .onChange(of: recentPrompts.prompts) { _, _ in ensureSelection() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: VFSpacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Color.vfTextTertiary)
            Text("No prompts yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
            Text("Your recent prompts will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Split view

    private var splitView: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
                .frame(minWidth: 360, maxWidth: .infinity)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(recentPrompts.prompts) { entry in
                SidebarRow(entry: entry)
                    .tag(entry.id)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            DetailPane(
                entry: entry,
                didCopy: didCopyTickID == entry.id,
                onCopy: { copy(entry) },
                onDelete: { delete(entry) }
            )
        } else {
            VStack {
                Spacer()
                Text("Select a prompt")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Behavior

    private var selectedEntry: RecentPrompt? {
        guard let selectedID else { return nil }
        return recentPrompts.prompts.first(where: { $0.id == selectedID })
    }

    private func ensureSelection() {
        if let selectedID, recentPrompts.prompts.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = recentPrompts.prompts.first?.id
    }

    private func copy(_ entry: RecentPrompt) {
        // Phase 5: same per-type payload semantics as the live pill —
        // artifact body / chat text / raw fallback (RecentPrompt.copyPayload).
        Pasteboard.copy(entry.copyPayload)
        didCopyTickID = entry.id
        let tickID = entry.id
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                if didCopyTickID == tickID { didCopyTickID = nil }
            }
        }
    }

    private func delete(_ entry: RecentPrompt) {
        // Pre-pick the next selection so the detail pane doesn't flash
        // empty between the delete and @Observable's reconciliation.
        let nextID: RecentPrompt.ID? = {
            guard let idx = recentPrompts.prompts.firstIndex(where: { $0.id == entry.id }) else {
                return recentPrompts.prompts.first?.id
            }
            let after = idx + 1
            if after < recentPrompts.prompts.count {
                return recentPrompts.prompts[after].id
            }
            if idx > 0 { return recentPrompts.prompts[idx - 1].id }
            return nil
        }()
        recentPrompts.delete(id: entry.id)
        selectedID = nextID
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let entry: RecentPrompt

    var body: some View {
        // Phase 5: the artifact-type glyph (chat bubble for chat-only)
        // leads the row so the list scans by result kind at a glance.
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
            Image(systemName: entry.displayIconName)
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(Self.relative.localizedString(for: entry.timestamp, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Detail pane

private struct DetailPane: View {
    let entry: RecentPrompt
    let didCopy: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
                        Image(systemName: entry.displayIconName)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfTextTertiary)
                        Text(entry.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.vfTextPrimary)
                            .lineLimit(2)
                    }
                    Text(Self.absolute.string(from: entry.timestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfTextSecondary)
                }
                Spacer()
                actions
            }
            Divider().overlay(Color.vfHairline)
            ScrollView {
                Text(entry.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(VFSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actions: some View {
        HStack(spacing: VFSpacing.sm) {
            Button(action: onCopy) {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    // §2 per-type button label ("Copy to Agent", "Copy
                    // draft", …); plain "Copy" for chat-only/pre-v2 rows.
                    Text(didCopy ? "Copied" : (entry.resolvedArtifactType?.buttonLabel ?? "Copy"))
                }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(SettingsDestructiveButtonStyle())
            .help("Delete this prompt")
        }
    }

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

#Preview("Populated") {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerro-rp-preview-\(UUID().uuidString).json")
    let store = RecentPromptStore(fileURL: url)
    store.add(prompt: "## Context\nLogin form misaligned.\n\n## Request\nAlign the submit button with the password field.")
    store.add(prompt: "Debug the React hydration error on the dashboard route.")
    store.add(prompt: "Summarize Tuesday's standup.")
    return RecentPromptsView()
        .environment(store)
        .frame(width: 760, height: 480)
        .background(Color.vfPanelBackground)
}

#Preview("Empty") {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerro-rp-empty-\(UUID().uuidString).json")
    return RecentPromptsView()
        .environment(RecentPromptStore(fileURL: url))
        .frame(width: 760, height: 480)
        .background(Color.vfPanelBackground)
}
