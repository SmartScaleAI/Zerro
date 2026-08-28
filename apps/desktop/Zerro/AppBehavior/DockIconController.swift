//
//  DockIconController.swift
//  Zerro
//
//  Created by Colin Breeding on 6/11/26.
//
//  Runtime Dock-icon management for an LSUIElement app. Zerro LAUNCHES
//  with no Dock icon (INFOPLIST_KEY_LSUIElement stays YES), but while a
//  real window is open — Settings, Onboarding, Paywall, Trial email —
//  the app should behave like a regular app: visible in the Dock and
//  the ⌘Tab switcher. The moment the LAST such window closes, the icon
//  must disappear again.
//
//  Mechanism: flip NSApp's activation policy at runtime. `.regular`
//  when the first qualifying window shows, back to `.accessory` when
//  the set of visible qualifying windows empties. Counted via a Set of
//  window IDs (not a boolean) so Settings staying open while Onboarding
//  closes keeps the icon.
//
//  Scope: ONLY the SwiftUI Window scenes listed below participate. The pill,
//  the recording-focus window, the area-selector overlay, and the
//  MenuBarExtra panel/flyouts never touch the policy — a recording
//  started with no windows open must never flash a Dock icon.
//
//  Close detection is belt-and-suspenders: the `.dockIconVisibility`
//  modifier's `.onDisappear` AND a global NSWindow.willCloseNotification
//  observer (matched to the scene by NSWindow.identifier) both report a
//  close, so the red traffic-light button, ⌘W, and programmatic
//  dismissWindow(id:) are all covered even if SwiftUI skips one of the
//  callbacks. Set.remove makes the double-report a no-op.
//

import AppKit
import os
import SwiftUI

@MainActor
final class DockIconController {
    static let shared = DockIconController()

    /// The window scenes that warrant a Dock icon while visible.
    private static let qualifyingWindowIDs: Set<String> = [
        SettingsScene.windowID,
        OnboardingScene.windowID,
        PaywallScene.windowID,
        ActivateKeyScene.windowID,
        WhatsNewScene.windowID,
    ]

    /// IDs of qualifying windows currently on screen. Set semantics give
    /// the double-decrement guard for free: each scene is single-instance,
    /// so a second show is an idempotent insert and the second of the two
    /// close reports (onDisappear + willClose) removes nothing.
    private var visibleWindowIDs: Set<String> = []

    private var willCloseObserver: NSObjectProtocol?

    private init() {
        // One global observer instead of per-window bookkeeping: SwiftUI
        // owns the NSWindow lifetimes (it may recreate them per open), so
        // matching by identifier on each close is the wiring that can't
        // go stale across open → close → reopen cycles.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if let id = Self.qualifyingID(for: window) {
                    DockIconController.shared.windowDidClose(id)
                }
            }
        }
    }

    // MARK: - Show / close

    /// Reported by `.dockIconVisibility`'s `.onAppear` when a qualifying
    /// window's root view mounts (Window scenes only mount content when
    /// the window is actually presented).
    func windowDidShow(_ id: String) {
        visibleWindowIDs.insert(id)
        guard NSApp.activationPolicy() == .accessory else { return }
        Log.ui.notice("dock icon: first qualifying window (\(id, privacy: .public)) — promoting to .regular")
        NSApp.setActivationPolicy(.regular)
        // Promoting to .regular while already frontmost doesn't reliably
        // attach the menu bar / Dock state; re-activating does.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reported by `.onDisappear` AND the willClose observer — whichever
    /// fires first wins; the other is a no-op (`remove` returns nil).
    func windowDidClose(_ id: String) {
        guard visibleWindowIDs.remove(id) != nil else { return }
        guard visibleWindowIDs.isEmpty else { return }
        // Demote on the next runloop tick, after AppKit finishes the
        // window teardown — demoting synchronously inside a close
        // callback can drop key-window status mid-teardown.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Re-check: a window reopened (or another one showed)
                // between the close and this tick keeps the icon.
                guard DockIconController.shared.visibleWindowIDs.isEmpty,
                      NSApp.activationPolicy() == .regular else { return }
                Log.ui.notice("dock icon: last qualifying window closed — demoting to .accessory")
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Dock-icon click / ⌘Tab reopen

    /// Brings the visible qualifying window(s) forward. Called from
    /// `applicationShouldHandleReopen` so clicking the Dock icon (or
    /// ⌘Tab-ing to Zerro and releasing on it) raises the open window
    /// instead of doing nothing.
    func bringVisibleWindowsToFront() {
        guard !visibleWindowIDs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible {
            if let id = Self.qualifyingID(for: window), visibleWindowIDs.contains(id) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Window matching

    /// Maps an NSWindow back to its scene's windowID via the identifier
    /// SwiftUI assigns to scene-owned windows — exactly the id for a
    /// single-instance `Window`, "<id>-..." suffixed forms otherwise.
    /// The app's manual NSWindows/NSPanels (pill, area selector,
    /// recording focus, menu-bar panel) never carry these identifiers,
    /// so they can never match.
    private static func qualifyingID(for window: NSWindow) -> String? {
        guard let raw = window.identifier?.rawValue else { return nil }
        if qualifyingWindowIDs.contains(raw) { return raw }
        return qualifyingWindowIDs.first { raw.hasPrefix($0 + "-") }
    }
}

// MARK: - View wiring

extension View {
    /// Attached to the ROOT view of each qualifying Window scene (in
    /// ZerroApp.body). `.onAppear`/`.onDisappear` on the root view track
    /// the window's presence: scene content mounts only while the window
    /// is on screen, and unmounts on close however the close happens
    /// (traffic light, ⌘W, dismissWindow). The controller's global
    /// willClose observer backs this up.
    func dockIconVisibility(windowID: String) -> some View {
        self
            .onAppear { DockIconController.shared.windowDidShow(windowID) }
            .onDisappear { DockIconController.shared.windowDidClose(windowID) }
    }
}
