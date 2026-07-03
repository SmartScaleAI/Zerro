//
//  WhatsNewView.swift
//  Zerro
//
//  The "What's New" changelog window: a versioned list of curated release
//  notes (newest first, scrollable), auto-popped once per version update by
//  `WhatsNewPolicy` and reopenable any time from Settings → About & Support.
//  CleanShot-style layout retinted in Zerro's dark branding. Read-only over
//  `Changelog.entries` — the one live control is the footer's "Show
//  changelog after each update" switch, bound straight to PreferencesStore
//  so the auto-pop preference applies everywhere immediately.
//

import SwiftUI

struct WhatsNewView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sits below the floating traffic lights (top-left of the
            // chromeless surface) — same clearance rationale as the Settings
            // sidebar header's 28pt.
            Text("What\u{2019}s New")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
                .padding(.top, 28)
                .padding(.horizontal, VFSpacing.xl)
                .padding(.bottom, VFSpacing.lg)

            entryList

            footer
                .padding(VFSpacing.xl)
        }
        .frame(width: WhatsNewScene.preferredWidth, height: WhatsNewScene.preferredHeight)
        .background(Color.vfPanelBackground)
        .applyWhatsNewWindowChrome()
        .onAppear(perform: captureShown)
        .onChange(of: preferences.showWhatsNewOnUpdate) { _, enabled in
            Analytics.capture("whats_new_autoshow_toggled", ["enabled": enabled])
        }
    }

    // MARK: Entry list

    private var entryList: some View {
        ScrollView {
            WhatsNewEntryList()
                .padding(.horizontal, VFSpacing.xl)
                .padding(.vertical, VFSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    private var footer: some View {
        @Bindable var preferences = preferences
        return HStack(spacing: VFSpacing.md) {
            Toggle(isOn: $preferences.showWhatsNewOnUpdate) {
                Text("Show changelog after each update")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
            }
            .toggleStyle(VFSwitchToggleStyle())
            // Hug the label + switch so the Close button keeps the right edge
            // (the style's internal Spacer would otherwise spread them apart).
            .fixedSize()

            Spacer(minLength: 0)

            Button(action: close) {
                Text("Close")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfOnBrand)
                    .padding(.horizontal, VFSpacing.lg)
                    .padding(.vertical, VFSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                            .fill(Color.vfBrandAccent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private func captureShown() {
        // The launch auto-pop sets the one-shot flag right before this window
        // mounts; a manual open (About row) never does. Consume it so a later
        // reopen in the same session reports "manual".
        let trigger = WhatsNewScene.autoPresentedThisLaunch ? "auto" : "manual"
        WhatsNewScene.autoPresentedThisLaunch = false
        Analytics.capture(
            "whats_new_shown",
            [
                "version": Changelog.entries.first?.version ?? "none",
                "trigger": trigger,
            ]
        )
    }

    private func close() {
        dismissWindow(id: WhatsNewScene.windowID)
    }
}

// MARK: - Entry list content

/// The scrollable changelog body — every `Changelog` entry, newest first,
/// each a bold version header (+ optional date stamp) over em-dash bullets.
/// Split from `WhatsNewView` so it's renderable standalone (previews and the
/// ImageRenderer snapshot harness can't see inside a ScrollView).
struct WhatsNewEntryList: View {
    var body: some View {
        LazyVStack(alignment: .leading, spacing: VFSpacing.xxl) {
            if Changelog.entries.isEmpty {
                // Shouldn't happen in prod (the changelog ships bundled) —
                // but never render a blank scroll area.
                Text("You\u{2019}re up to date.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextSecondary)
            } else {
                ForEach(Changelog.entries) { entry in
                    entryView(entry)
                }
            }
        }
    }

    private func entryView(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: VFSpacing.md) {
                Text(entry.version)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: 0)
                if let date = entry.date {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextTertiary)
                }
            }

            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                ForEach(entry.highlights) { highlight in
                    HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
                        Text("\u{2014}")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.vfTextTertiary)
                        Text(highlight.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.vfTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// "Jul 2, 2026" — display-only stamp under the version header.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Preview

#Preview("What's New") {
    WhatsNewView()
        .environment(PreferencesStore(defaults: .ephemeralPreview()))
}
