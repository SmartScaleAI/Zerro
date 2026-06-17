//
//  WindowRestoration.swift
//  Zerro
//
//  Hard-disables macOS window-state restoration for the menu-bar app's
//  transient utility windows (Settings, Paywall, Trial-email, Feedback).
//
//  Why this exists on top of `.restorationBehavior(.disabled)`:
//  Zerro is an LSUIElement/accessory app — those windows must appear ONLY when
//  explicitly opened via `openWindow(id:)`. macOS state restoration otherwise
//  re-opens whichever window was on screen at the last TERMINATE on the next
//  launch, independent of (and overriding) `.defaultLaunchBehavior(.suppressed)`.
//  Repro: open Settings, ⌘Q, then cold-launch via a `zerro://` deep link — the
//  Settings window comes back with the deep-link paywall stacked on top.
//
//  The SwiftUI `.restorationBehavior(.disabled)` scene modifier (macOS 15+) is
//  applied alongside this, but it only stops FUTURE state saves. This AppKit
//  clamp is belt-and-suspenders that ALSO drops any state a prior build already
//  persisted (`invalidateRestorableState`), so a one-time stale restore can't
//  slip a window back on screen on the very next launch. A cold launch is then
//  always just the menu-bar icon.
//
//  Independent of explicit `openWindow(id:)` — disabling restoration never
//  affects a window opened on purpose (the menu row, ⌘,, the hotkey gate, the
//  checkout-return deep link all keep working).
//

import AppKit
import SwiftUI

// MARK: - NSWindow introspection

/// Reaches the hosting `NSWindow` from a SwiftUI scene's root view (mirrors
/// `WindowConfigurator` in SettingsWindowChrome) and clamps restoration off.
/// The `DispatchQueue.main.async` hop gives SwiftUI time to attach the backing
/// view to its window before we look it up.
private struct WindowRestorationDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isRestorable = false
            // Drop any restorable state a previous build already wrote to disk,
            // so the first launch after this ships doesn't restore once.
            window.invalidateRestorableState()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - View wiring

extension View {
    /// Disables AppKit window-state restoration for the hosting window. Applied
    /// to the root view of each suppressed utility-window scene in
    /// `ZerroApp.body`, alongside the SwiftUI `.restorationBehavior(.disabled)`
    /// scene modifier. The window then appears only via explicit
    /// `openWindow(id:)` — never restored on relaunch.
    func disablesWindowRestoration() -> some View {
        background(WindowRestorationDisabler())
    }
}
