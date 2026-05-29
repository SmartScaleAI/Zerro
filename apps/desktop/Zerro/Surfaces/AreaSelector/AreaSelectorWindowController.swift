//
//  AreaSelectorWindowController.swift
//  Zerro
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
import AVFoundation
import SwiftUI

@MainActor
final class AreaSelectorWindowController {

    private var window: NSWindow?
    private var state: AreaSelectorState?
    private var preferences: PreferencesStore?
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
        preferences: PreferencesStore,
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

        self.preferences = preferences

        let state = AreaSelectorState()
        self.state = state

        // Seed the toolbar's mic picker from the connected devices and
        // the persisted selection so the chip shows the right label
        // immediately and a change here writes straight back to prefs.
        state.setMicrophones(
            Self.enumerateMicrophones(),
            selectedID: preferences.microphoneDeviceID
        )

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
        preferences = nil
    }

    // MARK: - Event monitors

    private func installEventMonitors(for window: NSWindow, state: AreaSelectorState) {
        // .mouseMoved is needed for the window-mode live hover; the
        // window also has to accept moved events for the monitor to
        // see them while it isn't tracking a drag.
        window.acceptsMouseMovedEvents = true
        let mouseTypes: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseTypes) { [weak self, weak window, weak state] event in
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

            // Floating toolbar (mic chip + Record button + mic dropdown)
            // — shared across modes. The SwiftUI tree is hit-test-disabled,
            // so the controller owns both the click hit-test and the hover
            // feedback by re-deriving the item frames from the same static
            // helpers the view renders with. Handled before the per-mode
            // drag/settle logic so a click on the toolbar acts on it rather
            // than re-dragging or re-settling underneath it.
            let size = contentView.bounds.size
            let selectionRect = state.confirmableSelectionRect
            let recordFrame = selectionRect.map {
                AreaSelectorView.recordButtonFrame(forSelection: $0, in: size)
            }
            let micFrame = selectionRect.map {
                AreaSelectorView.micChipFrame(forSelection: $0, in: size)
            }

            if event.type == .mouseMoved {
                state.setRecordButtonHovered(recordFrame?.contains(point) ?? false)
                state.setMicChipHovered(micFrame?.contains(point) ?? false)
                if state.isMicMenuOpen, let rect = selectionRect {
                    state.setHighlightedMicIndex(AreaSelectorView.micMenuRowIndex(
                        at: point, forSelection: rect, in: size,
                        itemCount: state.micMenuItems.count
                    ))
                }
            }

            if event.type == .leftMouseDown {
                // Record button — start recording.
                if let recordFrame, recordFrame.contains(point) {
                    self?.confirmCurrentSelection(window: window, state: state)
                    return nil
                }
                // Mic chip — open/close the dropdown.
                if let micFrame, micFrame.contains(point) {
                    state.toggleMicMenu()
                    return nil
                }
                // Dropdown open — a click selects the row under the cursor
                // (persisting to prefs) or, if outside, dismisses. Either
                // way the click is consumed so it never starts a new drag.
                if state.isMicMenuOpen {
                    if let rect = selectionRect,
                       let idx = AreaSelectorView.micMenuRowIndex(
                        at: point, forSelection: rect, in: size,
                        itemCount: state.micMenuItems.count
                       ) {
                        let id = state.micMenuItems[idx].id
                        self?.preferences?.microphoneDeviceID = id
                        state.selectMicrophone(id: id)
                    }
                    state.closeMicMenu()
                    return nil
                }
            }

            switch state.mode {
            case .area:
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
            case .window:
                switch event.type {
                case .mouseMoved, .leftMouseDragged:
                    state.hoverWindow(at: point)
                case .leftMouseDown:
                    state.settleWindow(at: point)
                default:
                    break
                }
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
                // ESC closes the mic dropdown first if it's open, so the
                // first press dismisses the menu and only a second press
                // cancels the whole overlay.
                if state.isMicMenuOpen {
                    state.closeMicMenu()
                    return nil
                }
                state.cancel()
                return nil
            case 49: // Space — toggle area/window mode
                self?.toggleMode(window: window, state: state)
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

    /// Flips between area and window mode in response to Space. When
    /// entering window mode we (re)enumerate on-screen windows for the
    /// overlay's display and seed the hover with whatever sits under
    /// the cursor right now, so the highlight appears immediately
    /// rather than only after the first mouse move.
    private func toggleMode(window: NSWindow, state: AreaSelectorState) {
        switch state.mode {
        case .area:
            let candidates = enumerateWindows(on: window)
            state.enterWindowMode(windows: candidates)
            if let contentView = window.contentView {
                let mouse = NSEvent.mouseLocation
                let windowPoint = window.convertPoint(fromScreen: mouse)
                state.hoverWindow(at: CGPoint(
                    x: windowPoint.x,
                    y: contentView.bounds.height - windowPoint.y
                ))
            }
        case .window:
            state.enterAreaMode()
        }
    }

    /// Builds a `SelectionRect` in global AppKit screen coordinates
    /// from the current view-local drag rect and forwards it to the
    /// state's confirm callback. Selections below
    /// `AreaSelectorState.minimumSelectionSize` on either axis (including
    /// zero-size) are a no-op — the overlay stays open — so an accidental
    /// Return without a real drag doesn't kick off a recording of nothing
    /// (or of a too-small region).
    private func confirmCurrentSelection(window: NSWindow, state: AreaSelectorState) {
        switch state.mode {
        case .area:
            confirmAreaSelection(window: window, state: state)
        case .window:
            confirmWindowSelection(window: window, state: state)
        }
    }

    private func confirmAreaSelection(window: NSWindow, state: AreaSelectorState) {
        guard let viewLocal = state.selectionRect,
              viewLocal.width >= AreaSelectorState.minimumSelectionSize,
              viewLocal.height >= AreaSelectorState.minimumSelectionSize else {
            return
        }
        let global = viewLocalToGlobal(viewLocal, window: window)
        let selection = SelectionRect(
            rect: global,
            screenLocalizedName: window.screen?.localizedName,
            target: .area
        )
        state.confirm(with: selection)
    }

    /// Confirms the window the user has acted on (settled by click, or
    /// merely hovered). No-op if nothing is targeted, so a stray Return
    /// keeps the overlay open. The rect we pass is the window's frame
    /// in global AppKit space — capture uses the `.window` target's id
    /// for a clean per-window filter and falls back to cropping this
    /// rect only if the window has closed by the time recording starts.
    private func confirmWindowSelection(window: NSWindow, state: AreaSelectorState) {
        guard let candidate = state.activeWindow else { return }
        let global = viewLocalToGlobal(candidate.frame, window: window)
        let selection = SelectionRect(
            rect: global,
            screenLocalizedName: window.screen?.localizedName,
            target: .window(id: candidate.id, title: candidate.title)
        )
        state.confirm(with: selection)
    }

    /// View-local (top-left, point) → global AppKit (bottom-left, point).
    /// contentView fills the borderless window, so its bounds height
    /// equals the window's content height; the window's frame origin is
    /// already in the global AppKit space, so a Y-flip plus an offset
    /// lands us there. Shared by area and window confirm paths.
    private func viewLocalToGlobal(_ viewLocal: CGRect, window: NSWindow) -> CGRect {
        let h = window.contentView?.bounds.height ?? window.frame.height
        let windowLocal = CGRect(
            x: viewLocal.minX,
            y: h - (viewLocal.minY + viewLocal.height),
            width: viewLocal.width,
            height: viewLocal.height
        )
        return windowLocal.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
    }

    // MARK: - Microphone picker
    //
    // Mirrors GeneralSettingsView's discovery (.microphone + .external,
    // audio). The empty-string id is the "System Default" sentinel that
    // PreferencesStore persists. We don't filter to currently-resolvable
    // devices here — the chip label falls back to "System Default" when
    // the stored id no longer resolves, same as Settings.
    private static func enumerateMicrophones() -> [AreaSelectorState.AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { .init(id: $0.uniqueID, name: $0.localizedName) }
    }

    // MARK: - Window enumeration

    /// On-screen windows for the overlay's display, front-to-back, with
    /// frames converted into the overlay's view-local (top-left) space.
    ///
    /// `CGWindowListCopyWindowInfo` returns bounds in Quartz global
    /// coordinates (top-left origin of the main display, y down). The
    /// overlay's display origin in that same space is `CGDisplayBounds`,
    /// so subtracting it yields a top-left point relative to the display
    /// — which is exactly the overlay's view-local space.
    ///
    /// We filter to "real" windows: our own overlay is excluded, as are
    /// menu-bar/dock layer windows (layer != 0), fully transparent
    /// windows, and anything not intersecting this display.
    private func enumerateWindows(on window: NSWindow) -> [AreaSelectorState.WindowCandidate] {
        guard let screen = window.screen,
              let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return []
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let displayBounds = CGDisplayBounds(displayID)

        let ownWindowNumber = CGWindowID(window.windowNumber)

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var candidates: [AreaSelectorState.WindowCandidate] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID,
                  windowNumber != ownWindowNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let quartzBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // Skip effectively invisible windows.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
                continue
            }
            // Only windows on this display.
            guard quartzBounds.intersects(displayBounds) else { continue }

            let viewLocal = CGRect(
                x: quartzBounds.minX - displayBounds.minX,
                y: quartzBounds.minY - displayBounds.minY,
                width: quartzBounds.width,
                height: quartzBounds.height
            )
            // Ignore degenerate / tiny windows that can't carry context.
            guard viewLocal.width >= 40, viewLocal.height >= 40 else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String
            let name = info[kCGWindowName as String] as? String
            let title = [name, owner].compactMap { $0 }.first(where: { !$0.isEmpty })

            candidates.append(
                .init(id: windowNumber, frame: viewLocal, title: title)
            )
        }
        return candidates
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
