//
//  MenuBarPanelView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct MenuBarPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch appState.state {
                case .idle:
                    IdleStateView()
                case .recording, .wrappingUp, .autoStopped, .processing, .done:
                    RecordingStateView()
                }
            }
        }
        .frame(width: 320)
        .background(Color.vfPanelBackground)
    }
}

#Preview {
    MenuBarPanelView()
        .environment(AppState())
}
