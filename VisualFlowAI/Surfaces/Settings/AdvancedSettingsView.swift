//
//  AdvancedSettingsView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  Placeholder for the Advanced tab. Scaffolded now so later phases —
//  hotkey binding, model selection, output preferences — have an
//  obvious home without forcing a redesign.
//

import SwiftUI

struct AdvancedSettingsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("More options coming soon.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    AdvancedSettingsView()
        .frame(width: 480, height: 320)
}
