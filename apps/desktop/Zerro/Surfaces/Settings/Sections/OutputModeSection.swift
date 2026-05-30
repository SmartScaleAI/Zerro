//
//  OutputModeSection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — Output Mode section of the redesigned Settings layout.
//  Single row: a segmented control flipping between Instruct/Explain
//  plus a two-line caption below explaining what each mode produces.
//  The selection is persisted via PreferencesStore.defaultOutputMode;
//  Phase 17 will read this value to compose the right system-prompt
//  layer at generation time. Phase 11 only persists.
//

import SwiftUI

struct OutputModeSection: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        SettingsSection("Output Mode") {
            SettingsStackedRow(
                label: "Default Mode",
                trailing: {
                    Picker("Default Mode", selection: $preferences.defaultOutputMode) {
                        ForEach(OutputMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // .fixedSize() keeps the segmented control at the
                    // intrinsic width of its labels so its right edge
                    // lines up with the other trailing controls. A
                    // .frame(width:) slot would render the control
                    // leading-aligned inside an oversized slot, leaving
                    // visible gap before the card right edge.
                    .fixedSize()
                },
                below: {
                    captionBlock
                }
            )
        }
    }

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(captionLine(
                bold: "Instruct",
                rest: " \u{2014} tight, imperative steps an AI agent can act on."
            ))
            .font(.system(size: 12))
            Text(captionLine(
                bold: "Explain",
                rest: " \u{2014} adds reasoning and context for a human to review."
            ))
            .font(.system(size: 12))
        }
    }

    /// Builds the two-tone caption (bold prefix in primary, rest in
    /// secondary) as a single AttributedString. The `Text +` operator
    /// was deprecated in macOS 26 in favor of interpolation; this is
    /// the modern equivalent for runs with mixed weights/colors.
    private func captionLine(bold: String, rest: String) -> AttributedString {
        var boldRun = AttributedString(bold)
        boldRun.font = .system(size: 12, weight: .semibold)
        boldRun.foregroundColor = Color.vfTextPrimary
        var restRun = AttributedString(rest)
        restRun.font = .system(size: 12)
        restRun.foregroundColor = Color.vfTextSecondary
        return boldRun + restRun
    }
}

#Preview {
    OutputModeSection()
        .environment(PreferencesStore())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
