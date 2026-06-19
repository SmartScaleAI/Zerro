//
//  DeveloperSection.swift
//  Zerro
//
//  Created by Colin Breeding on 6/19/26.
//
//  Developer page of the redesigned Settings layout. One toggle:
//    • Pulsing Ring Effect — controls whether the green pulsing ring is
//      drawn around the screen edges while a Dev Mode coding-agent run is
//      in progress. Backed by `PreferencesStore.pulsingRingEnabled`
//      (UserDefaults, ON by default). The ring controller observes that
//      pref live, so flipping it off fades the ring out immediately.
//

import SwiftUI

struct DeveloperSection: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsSection("Developer") {
            SettingsRow(
                label: "Pulsing Ring Effect",
                description: "Show a pulsing ring around the screen edges while the coding agent is making changes."
            ) {
                Toggle("Pulsing Ring Effect", isOn: $preferences.pulsingRingEnabled)
                    .labelsHidden()
                    .toggleStyle(VFSwitchToggleStyle())
            }
        }
    }
}

#Preview {
    DeveloperSection()
        .environment(PreferencesStore())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
