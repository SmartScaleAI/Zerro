//
//  AppearanceSection.swift
//  Zerro
//
//  Created by Colin Breeding on 6/19/26.
//
//  Appearance section of the General settings page. Two toggles:
//    • Pulsing Ring Effect — controls whether the green pulsing ring is
//      drawn around the screen edges while a Dev Mode coding-agent run is
//      in progress. Backed by `PreferencesStore.pulsingRingEnabled`
//      (UserDefaults, ON by default). The ring controller observes that
//      pref live, so flipping it off fades the ring out immediately.
//    • Recording Cursor Highlight — controls whether a soft green glow is
//      drawn under the cursor while a Dev Mode recording is in progress
//      (the system cursor itself is left untouched). Backed by
//      `PreferencesStore.devCursorEnabled` (UserDefaults, ON by default).
//      `DevCursorWindowController` observes it live, so flipping it off
//      fades the glow out immediately.
//

import SwiftUI

struct AppearanceSection: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsSection("Appearance") {
            SettingsRow(
                label: "Pulsing Ring Effect",
                description: "Show a pulsing ring around the screen edges while the coding agent is making changes."
            ) {
                Toggle("Pulsing Ring Effect", isOn: $preferences.pulsingRingEnabled)
                    .labelsHidden()
                    .toggleStyle(VFSwitchToggleStyle())
            }
            SettingsRowDivider()
            SettingsRow(
                label: "Recording Cursor Highlight",
                description: "Show a green glow under the cursor while recording a Dev Mode clip."
            ) {
                Toggle("Recording Cursor Highlight", isOn: $preferences.devCursorEnabled)
                    .labelsHidden()
                    .toggleStyle(VFSwitchToggleStyle())
            }
        }
    }
}

#Preview {
    AppearanceSection()
        .environment(PreferencesStore())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
