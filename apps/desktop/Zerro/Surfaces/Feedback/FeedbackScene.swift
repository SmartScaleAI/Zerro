//
//  FeedbackScene.swift
//  Zerro
//
//  Created by Colin Breeding on 6/15/26.
//
//  Window-scene constants + chrome for the in-app feedback dialog. Mirrors
//  `SettingsScene` / `SettingsWindowChrome`: a fixed, non-resizable, chromeless
//  window whose dark surface bleeds up under the floating traffic-light buttons.
//  The id is shared by the Window scene declaration (ZerroApp), the menu-bar
//  "Send feedback" row, the Settings "Send Feedback" row, and
//  `DockIconController.qualifyingWindowIDs`.
//

import AppKit
import SwiftUI

enum FeedbackScene {
    /// The Window's `id`. openWindow(id:) / dismissWindow(id:) key off this.
    static let windowID = "feedback"

    /// Fixed window dimensions. Both axes are hard-locked at the AppKit layer
    /// (see `applyFeedbackWindowChrome`) so the dialog can't be drag-resized —
    /// it's a compact single-purpose surface, not a document window.
    static let preferredWidth: CGFloat = 460
    static let preferredHeight: CGFloat = 520
}

// MARK: - Window chrome

extension View {
    /// Chromeless, fixed-size treatment matching `applySettingsWindowChrome()`
    /// but locked on BOTH axes (Settings lets height grow; the feedback dialog
    /// stays one fixed size). Reuses the `WindowConfigurator` defined alongside
    /// the Settings chrome to reach the hosting NSWindow once per mount.
    func applyFeedbackWindowChrome() -> some View {
        background(
            WindowConfigurator { window in
                applyZerroBlackWindowAppearance(to: window)
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                // No title bar to grab — drag from anywhere in the surface.
                window.isMovableByWindowBackground = true
                // Hard-lock to the preferred size so the user can't drag-resize
                // the dialog out of its designed proportions.
                let size = NSSize(
                    width: FeedbackScene.preferredWidth,
                    height: FeedbackScene.preferredHeight
                )
                window.minSize = size
                window.maxSize = size
                window.setContentSize(size)
            }
        )
    }
}
