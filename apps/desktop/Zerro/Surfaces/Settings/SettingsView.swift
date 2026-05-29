//
//  SettingsView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Root of the native `Settings { … }` scene. Two tabs today —
//  General + Advanced — using SwiftUI's default macOS tab style,
//  which renders the standard Preferences toolbar buttons. Sidebar
//  style is intentionally avoided until we outgrow a flat tab bar.
//

import SwiftUI

struct SettingsView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    SettingsView()
        .environment(PreferencesStore())
}
