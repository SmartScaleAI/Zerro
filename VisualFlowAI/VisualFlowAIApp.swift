//
//  VisualFlowAIApp.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

@main
struct VisualFlowAIApp: App {
    @State private var appState = AppState()
    @State private var pillController = PillWindowController()

    var body: some Scene {
        MenuBarExtra("VisualFlow AI", systemImage: "waveform") {
            MenuBarPanelView()
                .environment(appState)
                // Observation pattern: a single .task running an async loop that
                // re-arms `withObservationTracking` after each change. Chosen over
                // `.onChange` because the MenuBarExtra's content view's `.onChange`
                // only fires while the dropdown is open, whereas this task is
                // started once when the content first mounts and then keeps
                // running across open/close cycles, so the pill window stays in
                // sync with state changes that happen while the menu is closed.
                .task {
                    while !Task.isCancelled {
                        syncPill(for: appState.state)

                        await withCheckedContinuation { continuation in
                            withObservationTracking {
                                _ = appState.state
                            } onChange: {
                                continuation.resume()
                            }
                        }
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func syncPill(for state: RecordingState) {
        switch state {
        case .recording, .wrappingUp, .autoStopped:
            pillController.show(appState: appState)
        case .idle, .processing, .done:
            pillController.hide()
        }
    }
}
