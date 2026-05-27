//
//  PillWindowController.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  Owns the borderless, always-on-top NSWindow that hosts the recording pill.
//  The window is created lazily on first show() and reused (hide() just orders
//  it out so we don't churn AppKit objects on every state transition).
//

import AppKit
import SwiftUI

@MainActor
final class PillWindowController {

    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = .floating
            win.isMovableByWindowBackground = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.ignoresMouseEvents = false

            let hostingView = NSHostingView(
                rootView: RecordingPillView()
                    .environment(appState)
            )
            win.contentView = hostingView
            win.setContentSize(hostingView.fittingSize)

            window = win
        }

        positionAtTopCenter()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func positionAtTopCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let originX = visible.midX - size.width / 2
        let originY = visible.maxY - 24 - size.height
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
