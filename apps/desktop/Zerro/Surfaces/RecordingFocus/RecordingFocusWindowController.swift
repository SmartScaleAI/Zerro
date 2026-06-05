//
//  RecordingFocusWindowController.swift
//  Zerro
//
//  Created by Colin Breeding on 5/29/26.
//
//  Owns a borderless, click-through, full-screen NSWindow that dims
//  everything OUTSIDE the region currently being recorded — the
//  CleanShot-style focus effect — so the user can see exactly what's
//  being captured. Mirrors PillWindowController's self-observation
//  pattern: the controller owns an observation loop over AppState and
//  shows/hides its window itself, rather than being driven from a
//  SwiftUI view that may not be mounted.
//
//  The dim is shown only while a recording is active AND a region
//  selection exists (area or window target). Full-display recordings
//  (no selection) get no dim — there is no "outside" to darken.
//
//  Not-captured guarantee: the area-capture path crops the display to
//  `selection.rect`, and the dim's clear cutout is that same rect, so
//  the dimmed area lies entirely outside the captured region and is
//  cropped away. Window-target captures use a desktop-independent
//  filter that only sees the target window, so this separate full-
//  screen window is never captured either way.
//
//  Coordinate spaces: `SelectionRect.rect` is in points, global AppKit
//  screen space (bottom-left origin). The overlay window is sized to
//  the selection's screen (`NSScreen.frame`, same space), and the
//  cutout is converted into the window's view-local TOP-LEFT space for
//  SwiftUI — the single Y-flip here mirrors the area selector's.
//
//  Limitation: for window-target recordings the cutout is pinned to the
//  window's frame at capture-start and does not follow the window if it
//  is moved or resized mid-recording (the capture itself still tracks
//  the window via ScreenCaptureKit; only the dim cutout goes stale).
//  Acceptable for v1.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingFocusWindowController {

    private let appState: AppState
    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingFocusView>?
    private var observationTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        startObservingAppState()
    }

    deinit {
        observationTask?.cancel()
    }

    /// Drives show/hide from AppState for the controller's full lifetime.
    /// Lives here rather than in a view's `.task` for the same reason as
    /// PillWindowController: the dim must track recording state even
    /// while the menu-bar dropdown (the only always-available SwiftUI
    /// content) is closed.
    private func startObservingAppState() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sync()

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.appState.isRecordingActive
                        _ = self.appState.activeSelection
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func sync() {
        guard appState.isRecordingActive, let selection = appState.activeSelection else {
            window?.orderOut(nil)
            return
        }
        show(around: selection)
    }

    private func show(around selection: SelectionRect) {
        guard let screen = resolveScreen(for: selection) else { return }
        ensureWindow()
        guard let window, let hostingView else { return }
        window.setFrame(screen.frame, display: true)
        hostingView.rootView = RecordingFocusView(
            cutout: Self.windowLocalRect(selection.rect, on: screen)
        )
        window.orderFrontRegardless()
    }

    /// The NSScreen the selection was made on. Prefers the screen by its
    /// recorded localized name (stable across the recording), then any
    /// screen the rect intersects, then main.
    private func resolveScreen(for selection: SelectionRect) -> NSScreen? {
        if let name = selection.screenLocalizedName,
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return screen
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection.rect) }) {
            return screen
        }
        return NSScreen.main
    }

    /// Global AppKit rect (bottom-left origin) → window-local rect
    /// (top-left origin) for a window whose frame equals `screen.frame`.
    private static func windowLocalRect(_ global: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: global.minX - f.minX,
            y: f.height - (global.minY - f.minY) - global.height,
            width: global.width,
            height: global.height
        )
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let hosting = NSHostingView(rootView: RecordingFocusView(cutout: .zero))
        hosting.makeBackingTransparent()
        self.hostingView = hosting

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // Above normal app windows (the recorded content) but below the
        // pill, which is raised one level above .floating so it always
        // stays in front of this dim.
        win.level = .floating
        // Click-through: the dim is purely visual and must never
        // intercept clicks meant for the app being recorded.
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isExcludedFromWindowsMenu = true
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.contentView?.makeBackingTransparent()

        window = win
    }
}

// MARK: - RecordingFocusView

/// Dims the whole window except `cutout`, using a single eo-filled path
/// (outer bounds + inner cutout) so the selected region stays perfectly
/// clear — the captured content shows through untinted. Mirrors the
/// area selector's `dimCutout`.
private struct RecordingFocusView: View {
    /// Recording region in the window's view-local, top-left space.
    let cutout: CGRect

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geo.size))
                path.addRect(cutout)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        }
        .ignoresSafeArea()
    }
}
