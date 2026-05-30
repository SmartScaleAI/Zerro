//
//  SettingsHeader.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 (revision 2) — custom header for the chromeless Settings
//  window. Replaces what the stock macOS title bar would have shown:
//  the Zerro logo + the word "Zerro" (primary text) + " Settings"
//  (secondary text), centered horizontally.
//
//  Sits ABOVE the route content so it remains identical across the
//  root view and the pushed Recent Prompts view — the back chevron
//  for in-window navigation renders inside the content area, not on
//  the header.
//
//  The vertical padding accounts for the traffic-light buttons that
//  float on the chromeless surface — they sit roughly 14pt from the
//  top of the window, so the centered title clearing them needs ~24pt
//  of top breathing room.
//

import SwiftUI

struct SettingsHeader: View {
    var body: some View {
        // Round 5 (minimal-header pass): tightened from 56pt band +
        // 32pt gap to 44pt band + 16pt gap so the header reads as
        // chrome rather than its own visual region. 44pt still keeps
        // the content midline (y=22) close to the traffic-light
        // midline (~y=20) — chromeless surface still feels integrated
        // without the extra breathing room above/below the title.
        HStack(spacing: VFSpacing.sm) {
            logoTile
            HStack(spacing: 5) {
                Text("Zerro")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Text("Settings")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .padding(.bottom, 16)
    }

    /// Round 4: 24pt dark badge with the white Zerro mark inside per
    /// the design reference. This intentionally inverts the menu-bar
    /// dropdown's logo treatment (which uses a light badge on the
    /// dropdown's vibrancy panel) — on the Settings window's dark
    /// surface the dark-badge / white-mark inversion reads as more
    /// integrated chrome.
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
}

#Preview {
    SettingsHeader()
        .frame(width: 760)
        .background(Color.vfPanelBackground)
}
