//
//  DevCursorWindowController.swift
//  Zerro
//
//  Created by Colin Breeding on 6/19/26.
//
//  Owns the borderless, click-through overlay(s) that draw a soft Dev-Mode green
//  (`vfDevAccent` #34E27A) glow UNDER the default macOS cursor while a Dev Mode
//  RECORDING is in progress. The cursor analogue of `DevRingWindowController`'s
//  pulsing screen-edge ring: the same "Dev Mode is active right now" signal, the
//  same opt-out pattern. Shown screen-wide for the full duration of the recording;
//  fades out the instant the recording stops, fails, or auto-stops.
//
//  The system cursor is left UNTOUCHED — we never hide it, never draw a
//  replacement arrow. The overlay is a pure decoration that follows the pointer,
//  so there's no "restore the cursor" risk at all (the earlier custom-cursor
//  approach hid the OS pointer; this one doesn't). The white arrow stays exactly
//  as macOS draws it, with our green halo sitting beneath its body.
//
//  Self-observation: mirrors DevRingWindowController exactly. The controller owns
//  an observation loop over `AppState.devCursorActive` (true iff a recording is
//  active AND it's a Dev Mode session) and the user's `devCursorEnabled` opt-in,
//  and shows/hides itself — rather than being driven from a SwiftUI view that may
//  not be mounted (the MenuBarExtra content unmounts when its dropdown closes).
//
//  Window config is identical to DevRing: borderless, transparent, `.screenSaver`
//  level (floats above app windows + fullscreen apps), `ignoresMouseEvents = true`
//  (purely decorative, never eats a click), `.canJoinAllSpaces`/`.fullScreenAuxiliary`/
//  `.stationary`, one window per `NSScreen`, rebuilt on
//  `didChangeScreenParametersNotification` while active. Only the window whose
//  screen currently contains the pointer renders the glow (the others draw
//  nothing), so a multi-display setup never shows duplicate glows.
//
//  Tracking: an event-driven global + local `NSEvent` monitor for mouse-move /
//  drag updates the rendered position from `NSEvent.mouseLocation` (global,
//  bottom-left origin) at the system's native event rate — glued to the real
//  pointer with no perceptible lag and zero idle cost when the cursor is still
//  (a stationary cursor needs no reposition). A permission-free global mouse
//  read, same philosophy as `CursorTracker` (but that 30Hz sampler is too slow
//  for live rendering, so it is not reused here).
//
//  Performance: the glow is a couple of blurred circles flattened with
//  `.drawingGroup()` (rasterized once); nothing animates a blur/shadow radius —
//  the same lesson the DevRing header calls out. A pointer move just offsets the
//  cached glow texture.
//

import AppKit
import SwiftUI

// MARK: - DevCursorViewModel

@MainActor
@Observable
final class DevCursorViewModel {
    /// The real pointer in GLOBAL AppKit coords (points, bottom-left origin), as
    /// read from `NSEvent.mouseLocation`. Each window's `DevCursorView` converts
    /// this into its own screen's top-left space and renders the glow only when
    /// the pointer is on that screen.
    var globalLocation: CGPoint = .zero
}

// MARK: - DevCursorWindowController

@MainActor
final class DevCursorWindowController {

    private let appState: AppState
    private let preferences: PreferencesStore
    private let viewModel = DevCursorViewModel()

    private var windows: [NSWindow] = []
    private var isActive = false
    private var observationTask: Task<Void, Never>?
    private var screenChangeObserver: NSObjectProtocol?
    private var mouseMonitors: [Any] = []

    /// Enter/exit fade duration for the overlay (window alpha), matching DevRing /
    /// RecordingFocus.
    private static let fadeDuration: TimeInterval = 0.18

    /// Whether the green glow should currently be on screen: a Dev Mode recording
    /// is active AND the user's opt-in is on. Pure composition so it's trivially
    /// testable (see `shouldShow(devCursorActive:devCursorEnabled:)`).
    var shouldShowCursor: Bool {
        Self.shouldShow(
            devCursorActive: appState.devCursorActive,
            devCursorEnabled: preferences.devCursorEnabled
        )
    }

    /// The gating rule, factored out so the truth table is unit-testable without
    /// standing up the controller (which builds overlay windows).
    static func shouldShow(devCursorActive: Bool, devCursorEnabled: Bool) -> Bool {
        devCursorActive && devCursorEnabled
    }

    init(appState: AppState, preferences: PreferencesStore) {
        self.appState = appState
        self.preferences = preferences
        startObservingAppState()
    }

    deinit {
        observationTask?.cancel()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }

    /// Drives `setActive(_:)` from `shouldShowCursor` for the controller's full
    /// lifetime — same self-observation pattern as DevRingWindowController. The
    /// tracked closure reads BOTH `devCursorActive` and `devCursorEnabled` (both
    /// `@Observable`), so the loop re-evaluates when EITHER changes: toggling the
    /// pref off mid-recording fades the glow out immediately, and back on re-shows
    /// it while the recording is still running.
    private func startObservingAppState() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.setActive(self.shouldShowCursor)

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.appState.devCursorActive
                        _ = self.preferences.devCursorEnabled
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Single entry point: show the glow (true) or fade it out (false). Idempotent
    /// — re-asserting the current state is a no-op so the loop's initial `false`
    /// doesn't churn windows.
    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        // Seed the position so a stationary pointer is glowed correctly the instant
        // the overlay appears (the monitors only fire on the next move).
        viewModel.globalLocation = NSEvent.mouseLocation
        rebuildWindows()
        installScreenChangeObserver()
        installMouseMonitors()
        for window in windows {
            // Appear as a pure opacity fade: order in while invisible inside an
            // actions-disabled transaction so the hosting view mounts + renders at
            // full size NOW (no Core Animation `onOrderIn` zoom), then ramp alpha.
            // Same approach as DevRing / RecordingFocus / AreaSelector.
            window.alphaValue = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.display()
            CATransaction.commit()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for window in self.windows { window.animator().alphaValue = 1 }
            }
        }
    }

    private func hide() {
        removeScreenChangeObserver()
        removeMouseMonitors()
        // Snapshot the windows so the completion tears down exactly these, not
        // whatever a later show() may have rebuilt.
        let closing = windows
        windows = []
        guard !closing.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in closing { window.animator().alphaValue = 0 }
        } completionHandler: {
            for window in closing { window.orderOut(nil) }
        }
    }

    // MARK: - Window construction

    /// Build one glow window per current `NSScreen`, replacing any existing set.
    /// Called on show and on display-configuration changes while active.
    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { makeCursorWindow(on: $0) }
    }

    private func makeCursorWindow(on screen: NSScreen) -> NSWindow {
        let hosting = NSHostingView(
            rootView: DevCursorView(viewModel: viewModel, screenFrame: screen.frame)
        )
        hosting.makeBackingTransparent()

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.animationBehavior = .none
        // Above app windows, the menu bar, and fullscreen apps — same level the
        // DevRing + capture overlays use; the glow must float over everything.
        win.level = .screenSaver
        // Purely decorative: never intercept clicks/keys/hit-testing.
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isExcludedFromWindowsMenu = true
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.contentView?.makeBackingTransparent()
        // contentRect: is in global screen coords; re-set the frame so non-primary
        // displays land at the right origin.
        win.setFrame(screen.frame, display: false)
        return win
    }

    // MARK: - Screen changes

    /// Rebuild the window set when displays are added/removed/rearranged DURING a
    /// recording so the glow keeps working across the new layout. Only installed
    /// while active.
    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.rebuildWindows()
                // Newly built windows start at alpha 0 — reveal immediately (no
                // fade; the effect is already established for this recording).
                for window in self.windows {
                    window.alphaValue = 1
                    window.orderFrontRegardless()
                }
            }
        }
    }

    private func removeScreenChangeObserver() {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        screenChangeObserver = nil
    }

    // MARK: - Pointer tracking

    /// Event-driven position updates: a GLOBAL monitor (events headed to other
    /// apps — the common case, since this is an accessory app and our windows are
    /// click-through) plus a LOCAL monitor (events headed to us) for mouse-move
    /// and drag. Each reads `NSEvent.mouseLocation` so the glow stays glued to the
    /// real pointer. Removed on hide so nothing samples while inactive.
    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Event monitors are delivered on the main thread/run loop.
            MainActor.assumeIsolated { self?.updatePointerLocation() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerLocation() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMouseMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    private func updatePointerLocation() {
        viewModel.globalLocation = NSEvent.mouseLocation
    }
}

// MARK: - DevCursorView

/// Renders the glow for one screen. Reads the shared `globalLocation` and draws
/// the glow ONLY when the pointer is on this view's screen — converting the global
/// (bottom-left) point into this window's local (top-left) space, the same Y-flip
/// as `RecordingFocusWindowController`. Screens not containing the pointer draw
/// nothing, so there's never a duplicate glow.
private struct DevCursorView: View {
    let viewModel: DevCursorViewModel
    let screenFrame: CGRect

    var body: some View {
        let global = viewModel.globalLocation
        ZStack {
            Color.clear
            if screenFrame.contains(global) {
                CursorGlow()
                    // Center the glow on the pointer, nudged down-right by
                    // `CursorGlow.offset` so the halo sits under the arrow's BODY
                    // (the hotspot is the arrow's top-left tip) rather than its tip.
                    // localX = gx - minX; localY flips bottom-left global into
                    // top-left window space.
                    .position(
                        x: global.x - screenFrame.minX + CursorGlow.offset.x,
                        y: screenFrame.maxY - global.y + CursorGlow.offset.y
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

// MARK: - CursorGlow

/// The soft green halo drawn beneath the (untouched) system cursor: a wide faint
/// outer glow plus a tighter brighter core, both `vfDevAccent`, flattened into a
/// single GPU texture with `.drawingGroup()` so the blur is rasterized once and a
/// pointer move just repositions the cached texture (no per-frame blur).
private struct CursorGlow: View {
    /// Down-right nudge (top-left coords) so the halo lands under the arrow body,
    /// not its top-left tip/hotspot.
    static let offset = CGPoint(x: 5, y: 9)

    /// Padded canvas the circles are centered in. A `blur(radius:)` spreads its
    /// soft tail ~`radius` points BEYOND the source frame, and `.drawingGroup()`
    /// rasterizes to the view's layout bounds — so without a canvas larger than
    /// `circle + 2·radius` the blur's falloff gets clipped to a hard square (the
    /// bug this fixes). 76pt comfortably contains the 30pt circle + 14pt blur on
    /// each side, so the glow fades all the way out to transparent and reads round.
    private static let canvas: CGFloat = 76

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.vfDevAccent)
                .frame(width: 30, height: 30)
                .blur(radius: 14)
                .opacity(0.45)
            Circle()
                .fill(Color.vfDevAccent)
                .frame(width: 16, height: 16)
                .blur(radius: 7)
                .opacity(0.7)
        }
        .frame(width: Self.canvas, height: Self.canvas)
        .drawingGroup()
    }
}

#Preview {
    // Static preview of the glow itself (the live overlay tracks the real pointer,
    // which a canvas preview can't drive).
    CursorGlow()
        .padding(40)
        .background(Color.black)
}
