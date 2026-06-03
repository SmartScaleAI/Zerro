//
//  SettingsWindowChrome.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 (revision 2) — chrome plumbing for the custom Settings
//  window. Replaces the stock SwiftUI `Settings { ... }` scene's default
//  title bar with a chromeless surface where the dark background bleeds
//  up under the floating traffic-light buttons. The AppKit-level knobs
//  duplicate what `.windowStyle(.hiddenTitleBar)` already arranges, on
//  purpose — leaving them in protects us from SwiftUI defaults drifting
//  back over our settings in a future macOS update.
//
//  Constants here are referenced by both the window scene declaration
//  (in ZerroApp) and the menu-bar Preferences row, so the same id is
//  used for opening, activating, and the @SceneStorage-style window
//  lookup.
//

import AppKit
import SwiftUI

enum SettingsScene {
    /// The Window's `id`. openWindow(id:) and AppDelegate window-lookup
    /// both key off this string.
    static let windowID = "settings"

    /// Fixed window width. Revision 3 (sidebar layout) widened this from
    /// 720 → 880pt: the 188pt sidebar eats into the content area, so the
    /// detail pane needs the extra room to keep each row's label /
    /// description column readable (at 720 the description wrapped one
    /// word per line). Still hard-locked so the user can't drag-resize
    /// and break the card rhythm.
    static let preferredWidth: CGFloat = 880

    /// Default open height. Revision 3 trimmed this 720 → 600pt so the
    /// window opens more compact; the ScrollView in each pane handles
    /// anything below the fold.
    static let preferredHeight: CGFloat = 600

    /// Minimum acceptable height — below this the cards start
    /// stacking awkwardly. Width is hard-locked above this floor.
    static let minimumHeight: CGFloat = 400

    /// Fixed width of the left navigation sidebar. Chosen to match
    /// Wispr Flow's sidebar proportion while leaving the detail pane
    /// ~691pt (880 − 188 − 1pt divider) — enough room for the existing
    /// cards (originally laid out for ~720pt) plus a comfortable
    /// label/description column. The sidebar lives INSIDE the
    /// hard-locked window width.
    static let sidebarWidth: CGFloat = 188
}

// MARK: - WindowConfigurator

/// Lightweight NSViewRepresentable used as a `.background` on the
/// Settings root view to reach the hosting NSWindow and apply title-bar
/// / fullSizeContentView properties at the AppKit layer. Runs once per
/// window mount via `DispatchQueue.main.async`, which gives SwiftUI
/// time to attach the view to its window before we look it up.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Convenience wrapper that pushes the configurator into the view
    /// background so the rest of the layout stays unaffected. Applied
    /// once on the root Settings content view.
    func applySettingsWindowChrome() -> some View {
        background(
            WindowConfigurator { window in
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                // The dark surface should bleed up under the traffic
                // lights without an inset border; the explicit
                // backgroundColor handles cases where SwiftUI leaves the
                // window background nil (which renders as the system
                // window default, not our panel color).
                window.backgroundColor = NSColor(Color.vfPanelBackground)
                // Drag from anywhere in the chromeless surface — there's
                // no title bar to grab otherwise.
                window.isMovableByWindowBackground = true
                // Round 3: hard-lock the width at the AppKit level so
                // the user can't drag-resize past the design's 720pt
                // rhythm. Height can still grow if the user wants more
                // visible rows below the fold, but width is fixed.
                window.minSize = NSSize(
                    width: SettingsScene.preferredWidth,
                    height: SettingsScene.minimumHeight
                )
                window.maxSize = NSSize(
                    width: SettingsScene.preferredWidth,
                    height: .greatestFiniteMagnitude
                )
                // Round 5: force the initial size on every window
                // mount. `.defaultSize` on the Window scene + this
                // setContentSize together guarantee the open-Settings
                // action lands at the preferred dimensions even when
                // SwiftUI's idealHeight signal is dropped under
                // `.hiddenTitleBar` + `.contentSize` resizability.
                // Also clamp to the screen's visible height so the
                // window doesn't extend past the menu bar / dock on
                // smaller laptop displays.
                let visibleHeight = window.screen?.visibleFrame.height
                    ?? SettingsScene.preferredHeight
                let targetHeight = min(SettingsScene.preferredHeight, visibleHeight)
                window.setContentSize(
                    NSSize(
                        width: SettingsScene.preferredWidth,
                        height: targetHeight
                    )
                )
            }
        )
    }
}
