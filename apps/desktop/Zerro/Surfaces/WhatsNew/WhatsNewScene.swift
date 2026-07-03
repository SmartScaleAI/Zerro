//
//  WhatsNewScene.swift
//  Zerro
//
//  Window-scene constants + chrome for the "What's New" changelog window.
//  Mirrors `FeedbackScene`: a fixed, non-resizable, chromeless window whose
//  dark surface bleeds up under the floating traffic-light buttons. The id
//  is shared by the Window scene declaration (ZerroApp), the launch-time
//  auto-pop, the Settings About "What's New" row, and
//  `DockIconController.qualifyingWindowIDs`.
//

import AppKit
import SwiftUI

enum WhatsNewScene {
    /// The Window's `id`. openWindow(id:) / dismissWindow(id:) key off this.
    static let windowID = "whats-new"

    /// Fixed window dimensions. Both axes are hard-locked at the AppKit layer
    /// (see `applyWhatsNewWindowChrome`) — the entry list scrolls inside; the
    /// window itself is a fixed panel, not a resizable document.
    static let preferredWidth: CGFloat = 520
    static let preferredHeight: CGFloat = 560

    /// One-shot handoff from ZerroApp's launch decision to the view's appear
    /// analytics: `true` while the window being mounted is the launch-time
    /// auto-pop (vs. the About row's manual open). Set alongside the
    /// `.present` decision, consumed (reset to false) by the view's first
    /// appear — a later manual reopen then correctly reports "manual".
    @MainActor static var autoPresentedThisLaunch = false
}

// MARK: - Window chrome

extension View {
    /// Chromeless, fixed-size treatment matching `applyFeedbackWindowChrome()`
    /// — locked on BOTH axes. Reuses the `WindowConfigurator` defined
    /// alongside the Settings chrome to reach the hosting NSWindow once per
    /// mount.
    func applyWhatsNewWindowChrome() -> some View {
        background(
            WindowConfigurator { window in
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                // Let the dark surface bleed under the traffic lights; set an
                // explicit backgroundColor for the case where SwiftUI leaves
                // the window background nil (renders as the system default).
                window.backgroundColor = NSColor(Color.vfPanelBackground)
                // No title bar to grab — drag from anywhere in the surface.
                window.isMovableByWindowBackground = true
                // Hard-lock to the preferred size so the user can't drag-resize
                // the panel out of its designed proportions.
                let size = NSSize(
                    width: WhatsNewScene.preferredWidth,
                    height: WhatsNewScene.preferredHeight
                )
                window.minSize = size
                window.maxSize = size
                window.setContentSize(size)
            }
        )
    }
}
