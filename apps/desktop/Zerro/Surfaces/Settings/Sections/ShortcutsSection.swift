//
//  ShortcutsSection.swift
//  Zerro
//
//  Independent global shortcuts for opening the capture overlay in Ask or
//  Dev Mode. KeyboardShortcuts owns persistence and live re-registration.
//

import KeyboardShortcuts
import SwiftUI

struct ShortcutsSection: View {
    var body: some View {
        SettingsSection("Shortcuts") {
            SettingsRow(
                label: "Ask Mode",
                description: "Open the recording overlay for an Ask request."
            ) {
                HotkeyDisplay(name: .askRecording)
            }

            SettingsRowDivider()

            SettingsRow(
                label: "Dev Mode",
                description: "Open the recording overlay for a coding-agent request."
            ) {
                HotkeyDisplay(name: .devRecording)
            }
        }
    }
}

#Preview {
    ShortcutsSection()
        .padding()
        .frame(width: 620)
        .background(Color.vfPanelBackground)
}
