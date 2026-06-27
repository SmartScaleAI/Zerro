//
//  StagingRecordingMarkerWindowController.swift
//  Zerro
//
//  Staging-only. A borderless, click-through, always-on-top window that frames
//  the display currently being recorded with a ~3pt amber border + a
//  "STAGING · RECORDING" pill in a corner — so an active Staging capture is
//  unmistakable at the moment of recording, including the FULL-DISPLAY case the
//  recording-focus dim doesn't cover. (The dim only appears for region captures;
//  a full-display record has no "outside" to darken, so before this there was no
//  on-screen recording signal beyond the menu-bar icon.) Shown for BOTH
//  full-display and region recordings.
//
//  Not baked into the recording — the load-bearing detail: on macOS 15+
//  ScreenCaptureKit composites every window into a single framebuffer and
//  IGNORES `NSWindow.sharingType` and window level, so the ONLY reliable way to
//  keep a window out of a display capture is the content filter's
//  `excludingWindows`. AppState therefore shows this window BEFORE
//  `RecordingSession.start()` enumerates `SCShareableContent`, then feeds this
//  window's number into the filter's `excludingWindows` (see
//  `AppState.startRecording` + `RecordingSession.start`). For a region capture
//  the frame also lies outside the cropped `sourceRect`, so it's doubly
//  excluded; for a full-display capture the filter exclusion is what keeps it
//  out of the output.
//
//  Driven EXPLICITLY by AppState rather than self-observing AppState (the way
//  PillWindowController / RecordingFocusWindowController do) precisely because
//  the exclusion needs the window on screen BEFORE capture start — a moment that
//  precedes the `.recording` state those controllers key off. AppState owns the
//  instance for the same reason: it has to raise the window inside
//  `startRecording`, before it builds the session.
//
//  Compiled ONLY in the Staging configuration. The whole file is behind
//  `#if STAGING`, so it does not exist in the Production binary.
//

#if STAGING

import AppKit
import SwiftUI

@MainActor
final class StagingRecordingMarkerWindowController {

    private var window: NSWindow?

    /// This marker window's `CGWindowID` (as `Int`, matching `NSWindow.windowNumber`)
    /// while it is on screen — handed to the capture content filter's
    /// `excludingWindows` so the frame never bakes into the recording. `nil` when
    /// hidden (no window, or ordered out), so the filter excludes nothing.
    var excludedWindowNumber: Int? {
        guard let window, window.isVisible else { return nil }
        return window.windowNumber
    }

    /// Raise the amber frame around the display the recording targets, sized to
    /// that screen's full frame. Idempotent: reuses the single window across
    /// calls so its window number stays stable for the capture filter. Resolves
    /// the screen from the selection (stable display ID first, then name, then
    /// rect intersection), falling back to the main display for a full-display
    /// record started with no selection.
    func show(for selection: SelectionRect?) {
        guard let screen = Self.resolveScreen(for: selection) else { return }
        ensureWindow()
        guard let window else { return }
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    /// Drop the frame off screen. Safe to call when already hidden / never shown.
    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let hosting = NSHostingView(rootView: StagingRecordingMarkerView())
        hosting.makeBackingTransparent()

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.animationBehavior = .none
        // Above the recorded app windows AND above the recording-focus dim
        // (.floating) and the pill (.floating + 1) so the frame is always
        // visible. The pill stays usable because this window is click-through.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        // Click-through: purely a visual signal — it must never intercept a
        // click meant for the app being recorded.
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isExcludedFromWindowsMenu = true
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.contentView?.makeBackingTransparent()

        window = win
    }

    /// The `NSScreen` the recording targets. The stable `CGDirectDisplayID` is
    /// the authoritative key (it's what `RecordingSession` matches the capture
    /// display on); `localizedName` and rect-intersection are fallbacks, and the
    /// main display is the last resort (full-display record with no selection).
    private static func resolveScreen(for selection: SelectionRect?) -> NSScreen? {
        if let id = selection?.screenDisplayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        if let name = selection?.screenLocalizedName,
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return screen
        }
        if let rect = selection?.rect,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen
        }
        return NSScreen.main
    }
}

// MARK: - StagingRecordingMarkerView

/// A ~3pt amber border tracing the recorded display's edge plus a
/// "STAGING · RECORDING" pill in the TOP-LEADING corner. (The focus dim's
/// existing "STAGING" badge sits top-TRAILING, so the two don't collide when
/// both are up for a region record.) Entirely click-through.
private struct StagingRecordingMarkerView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            // `strokeBorder` draws inside the bounds, so the full 3pt stroke
            // stays on screen rather than half-clipping at the display edge.
            Rectangle()
                .strokeBorder(Color.vfStagingAccent, lineWidth: 3)

            StagingRecordingPill()
                .padding(.top, 14)
                .padding(.leading, 18)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The amber "STAGING · RECORDING" pill, styled like the shared `StagingBadge`
/// (heavy tracked caps, dark text on amber) with a leading dot as a recording
/// cue. Local to this file — the badge is "STAGING"-only and shared across the
/// menu header + overlays, so it isn't reused verbatim here.
private struct StagingRecordingPill: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.vfOnBrand)
                .frame(width: 8, height: 8)
            Text("STAGING · RECORDING")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
        }
        .foregroundStyle(Color.vfOnBrand)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.vfStagingAccent))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 4, y: 1)
    }
}

#endif
