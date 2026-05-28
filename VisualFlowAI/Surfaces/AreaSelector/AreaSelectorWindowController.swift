//
//  AreaSelectorWindowController.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/28/26.
//
//  Owns the borderless, full-screen, transparent NSWindow that
//  hosts the area-selector overlay. Mirrors PillWindowController's
//  contentView pattern (NSHostingView directly as contentView, no
//  custom event-handling NSView wrapper) — using a wrapper view
//  introduces autolayout/autoresizing coupling that can leave the
//  hosting view zero-sized in practice, manifesting as a window
//  that takes focus but never paints. Lifecycle differs from the
//  pill: present() builds a fresh window + state + event monitors
//  per session, dismiss() tears it all down. There is no morph and
//  no continuous observation to keep alive.
//
//  Event model: NSEvent.addLocalMonitorForEvents installed at
//  present time, removed at dismiss. Monitors are filtered to the
//  overlay window via `event.window === overlayWindow`, so other
//  app windows (menu bar dropdown, settings, onboarding) keep
//  their normal event flow. Returning `nil` from a monitor
//  consumes the event so SwiftUI never sees it; this is the actual
//  load-bearing mechanism that prevents the SwiftUI tree from
//  claiming interactions. The `.allowsHitTesting(false)` at the
//  SwiftUI root in `AreaSelectorRootView` is kept as defense in
//  depth (e.g. for any event type we don't monitor).
//
//  Coordinate conversion: NSEvent.locationInWindow is in window
//  points (bottom-left origin). NSHostingView and SwiftUI use
//  top-left. The monitor flips Y once: `y' = contentH - y`. This
//  is the only Y-flip site for area-selector events.
//

import AppKit
import SwiftUI

@MainActor
final class AreaSelectorWindowController {

    private var window: NSWindow?
    private var state: AreaSelectorState?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?

    /// Builds and shows the overlay on the screen containing the
    /// cursor. `onConfirm` fires when the user accepts a selection
    /// (Checkpoint 3); `onCancel` fires on ESC. Either callback is
    /// invoked exactly once per presentation; both implicitly
    /// dismiss the overlay before invocation.
    ///
    /// DEFERRED for Phase 7 handoff: multi-monitor coverage. Today
    /// we present a single overlay on the screen under the cursor;
    /// selections cannot span displays, and other displays remain
    /// undimmed. Full multi-display support would require one
    /// overlay window per NSScreen plus cross-window drag state —
    /// meaningful weight without a Phase 6 user need.
    func present(
        onConfirm: @escaping (SelectionRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        NSLog("[AreaSelector] present() called")

        // Guard against double-present (e.g. hotkey pressed twice).
        // Re-presenting on top of an existing overlay would leak
        // the prior window; cleanest behavior is to ignore.
        if window != nil { return }

        guard let screen = screenUnderCursor() ?? NSScreen.main else {
            onCancel()
            return
        }

        let state = AreaSelectorState()
        self.state = state

        state.onConfirm = { [weak self] rect in
            self?.dismiss()
            onConfirm(rect)
        }
        state.onCancel = { [weak self] in
            self?.dismiss()
            onCancel()
        }

        let win = makeOverlayWindow(on: screen, state: state)
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
        win.orderFrontRegardless()
        win.makeKey()

        installEventMonitors(for: win, state: state)
    }

    /// Tears down the overlay window, releases the state model, and
    /// removes the event monitors. Safe to call multiple times.
    func dismiss() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil

        window?.orderOut(nil)
        window = nil
        state = nil
    }

    // MARK: - Event monitors

    private func installEventMonitors(for window: NSWindow, state: AreaSelectorState) {
        let mouseTypes: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseTypes) { [weak window, weak state] event in
            // Filter: only this window's events. Returning the event
            // unchanged lets other windows (menu bar dropdown, etc.)
            // dispatch normally.
            guard let window, event.window === window, let state else {
                return event
            }
            guard let contentView = window.contentView else { return event }

            let location = event.locationInWindow
            // Window-local (bottom-left) → contentView-local (top-left).
            // contentView fills the borderless window, so its bounds
            // height equals the window's content height.
            let point = CGPoint(
                x: location.x,
                y: contentView.bounds.height - location.y
            )

            switch event.type {
            case .leftMouseDown:
                state.beginDrag(at: point)
            case .leftMouseDragged:
                state.updateDrag(to: point)
            case .leftMouseUp:
                state.endDrag(at: point)
            default:
                break
            }
            // Consume so SwiftUI never receives the event.
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window, weak state] event in
            guard let window, event.window === window, let state else {
                return event
            }
            switch event.keyCode {
            case 53: // ESC
                state.cancel()
                return nil
            case 36, 76: // Return, Enter (keypad)
                self?.confirmCurrentSelection(window: window, state: state)
                return nil
            default:
                // Don't consume keys we don't handle — let them go
                // through normal dispatch so e.g. ⌘Q still quits.
                return event
            }
        }
    }

    /// Builds a `SelectionRect` in global AppKit screen coordinates
    /// from the current view-local drag rect and forwards it to the
    /// state's confirm callback. Zero-sized selections are a no-op
    /// (the overlay stays open) so an accidental Return without a
    /// real drag doesn't kick off a recording of nothing.
    private func confirmCurrentSelection(window: NSWindow, state: AreaSelectorState) {
        guard let viewLocal = state.selectionRect,
              viewLocal.width > 0, viewLocal.height > 0 else {
            return
        }
        guard let contentView = window.contentView else { return }

        // View-local (top-left, point) → window-local (bottom-left, point).
        // contentView fills the borderless window, so its bounds height
        // equals the window's content height.
        let h = contentView.bounds.height
        let windowLocal = CGRect(
            x: viewLocal.minX,
            y: h - (viewLocal.minY + viewLocal.height),
            width: viewLocal.width,
            height: viewLocal.height
        )
        // Window-local → global. The window's frame origin is already
        // in the global AppKit screen space (bottom-left of primary
        // display), so a simple offset lands us there.
        let global = windowLocal.offsetBy(
            dx: window.frame.minX,
            dy: window.frame.minY
        )
        let selection = SelectionRect(
            rect: global,
            screenLocalizedName: window.screen?.localizedName
        )
        state.confirm(with: selection)
    }

    // MARK: - Window construction

    private func makeOverlayWindow(
        on screen: NSScreen,
        state: AreaSelectorState
    ) -> NSWindow {
        // NSHostingController as contentViewController is the modern
        // pattern for a SwiftUI tree that should fill an AppKit window.
        // Unlike `NSHostingView` set as contentView, the controller
        // wires its preferredContentSize to the window and configures
        // the view's frame + autoresizing for us — eliminating the
        // "window takes focus but paints nothing" failure mode where a
        // GeometryReader-rooted SwiftUI tree (no intrinsic size)
        // collapses the hosting view to zero.
        //
        // topInset = menu-bar height in points. The overlay window
        // covers the entire screen.frame (above the menu bar), so the
        // SwiftUI tree needs this to position the instruction pill
        // below the menu bar (matching where the recording pill sits)
        // rather than 24pt down from the physical top of the display.
        let topInset = max(0, screen.frame.height - screen.visibleFrame.maxY)
        let hostingController = NSHostingController(
            rootView: AreaSelectorRootView(state: state, topInset: topInset)
        )

        let win = AreaSelectorWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // .screenSaver sits above .floating, .modalPanel, normal app
        // windows, and the menu bar — appropriate for a modal-feeling
        // capture overlay (matches macOS Screenshot's behavior).
        win.level = .screenSaver
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isExcludedFromWindowsMenu = true
        // No restoration — this is a transient modal-feeling surface.
        win.isReleasedWhenClosed = false
        win.contentViewController = hostingController
        // After contentViewController is set, the controller's view
        // becomes the window's contentView. Assert layer transparency
        // through that view — borderless transparent windows otherwise
        // show an opaque backing layer through any non-filled regions
        // of the SwiftUI tree. Pattern matches PillWindowController.
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView?.layer?.isOpaque = false
        // Pin to the screen explicitly — `contentRect:` is in global
        // screen coordinates, so for a non-primary display we have to
        // re-set the frame after construction to land the window on
        // the right screen at the right origin.
        win.setFrame(screen.frame, display: true)
        return win
    }

    /// Returns the screen whose frame contains the current mouse
    /// location, falling back to `NSScreen.main`. NSEvent.mouseLocation
    /// and NSScreen.frame share the same global AppKit coordinate
    /// space (origin bottom-left of the primary display).
    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }
}

// MARK: - AreaSelectorWindow

/// Borderless NSWindow subclass that allows itself to become key.
/// The default NSWindow refuses key status when `styleMask` is just
/// `.borderless`, which would block keyDown(ESC) from ever reaching
/// the responder chain. (Local monitors fire even for non-key
/// windows, but only when the app is active — for the cleanest
/// behavior in an .accessory-policy menu-bar app we still want the
/// overlay to be the key window.)
private final class AreaSelectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - AreaSelectorRootView

/// SwiftUI root for the overlay. Disables hit-testing for the entire
/// view tree at the root — defense in depth, since the local-monitor
/// pattern in the controller already consumes monitored events
/// before SwiftUI dispatch.
private struct AreaSelectorRootView: View {
    let state: AreaSelectorState
    let topInset: CGFloat

    var body: some View {
        AreaSelectorView(state: state, topInset: topInset)
            .allowsHitTesting(false)
    }
}
