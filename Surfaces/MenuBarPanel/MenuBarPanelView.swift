//
//  MenuBarPanelView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct MenuBarPanelView: View {
    enum DemoState: String, CaseIterable, Identifiable {
        case idle = "Idle"
        case recording = "Recording"
        case processing = "Processing"
        var id: String { rawValue }
    }

    @State private var demoState: DemoState = .idle

    var body: some View {
        VStack(spacing: 0) {
            // Dev-only state switcher — REMOVE before shipping
            Picker("Demo State", selection: $demoState) {
                ForEach(DemoState.allCases) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(VFSpacing.sm)
            .background(Color.black.opacity(0.4))

            Group {
                switch demoState {
                case .idle:       IdleStateView()
                case .recording:  RecordingStateView()
                case .processing: ProcessingStateView()
                }
            }
        }
        .frame(width: 280)
        .background(Color.vfPanelBackground)
    }
}

#Preview {
    MenuBarPanelView()
}
