//
//  DevRingWindowController.swift
//  Zerro
//
//  Created by Colin Breeding on 6/19/26.
//
//  Owns the borderless, click-through, full-screen overlay(s) that draw a
//  thin pulsing green ring hugging the outer edge of the screen while a Dev
//  Mode coding-agent run is actively in progress — the desktop analogue of
//  the orange ring Claude draws around a controlled browser tab. An ambient
//  "the agent is touching your machine right now" signal.
//
//  Self-observation: mirrors PillWindowController / RecordingFocusWindowController.
//  The controller owns an observation loop over `AppState.devRingActive` and
//  shows/hides itself, rather than being driven from a SwiftUI view that may
//  not be mounted (the MenuBarExtra content unmounts when its dropdown closes).
//  `devRingActive` is the single source of truth (AppState) — true EXACTLY in
//  the `.devAgentDispatching`/`.devAgentRunning` window, so every existing
//  dispatch/complete/cancel/revert path drives the ring for free.
//
//  Window config mirrors AreaSelectorWindowController's non-interactive cousin:
//  borderless, transparent, `.screenSaver`-level so it floats above app windows
//  and fullscreen apps, `ignoresMouseEvents = true` so it is purely decorative
//  and never intercepts clicks/keys, and `.canJoinAllSpaces`/`.fullScreenAuxiliary`/
//  `.stationary` so it shows across Spaces and over fullscreen apps. The frame is
//  `screen.frame` (the FULL screen incl. menu bar / Dock) — this is an EDGE ring,
//  not a content overlay, so it must reach the physical screen edges.
//
//  Performance: the web version of this exact effect pinned Chrome Helper at
//  ~50% CPU by animating layered box-shadows every frame (a non-GPU-composited
//  property). We avoid that: the glow is rendered ONCE (a static blurred gradient
//  flattened into a single GPU texture via `.drawingGroup()`), and ONLY its layer
//  opacity is animated — a `repeatForever` opacity ramp that Core Animation
//  cross-fades on the cached bitmap. No `.blur`/shadow radius is animated, and no
//  Timer/TimelineView re-renders the gradient per tick. The overlay can be up for
//  minutes during a long run, so idle cost stays near-zero.
//
//  Multi-display: one ring window per `NSScreen`, all driven by the same shared
//  view-model so they pulse in lockstep. Rebuilt on
//  `didChangeScreenParametersNotification` so plugging/unplugging a display while
//  a run is active keeps every screen ringed.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class DevRingViewModel {
    /// Drives the pulse on the hosted `DevRingView`(s). The controller flips this
    /// in `setActive(_:)`; the view starts the `repeatForever` opacity animation
    /// when true and stops it (steady, non-repeating) when false, so nothing keeps
    /// animating once the run ends.
    var isActive = false
}

@MainActor
final class DevRingWindowController {

    private let appState: AppState
    private let viewModel = DevRingViewModel()
    private var windows: [NSWindow] = []
    private var observationTask: Task<Void, Never>?
    private var screenChangeObserver: NSObjectProtocol?

    /// Enter/exit fade duration for the whole ring (window alpha), per spec.
    private static let fadeDuration: TimeInterval = 0.25

    init(appState: AppState) {
        self.appState = appState
        startObservingAppState()
    }

    deinit {
        observationTask?.cancel()
    }

    /// Drives `setActive(_:)` from `AppState.devRingActive` for the controller's
    /// full lifetime. Lives here rather than in a view's `.task` for the same
    /// reason as the pill/focus controllers: the ring must track the run even
    /// while the menu-bar dropdown (the only always-available SwiftUI content)
    /// is closed.
    private func startObservingAppState() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.setActive(self.appState.devRingActive)

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.appState.devRingActive
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Single entry point: show + start pulsing (true) or fade out + hide (false).
    /// Idempotent — re-asserting the current state is a no-op so the observation
    /// loop's initial `false` (and any duplicate emit) doesn't churn windows.
    private func setActive(_ active: Bool) {
        guard active != viewModel.isActive else { return }
        viewModel.isActive = active
        if active {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        rebuildWindows()
        installScreenChangeObserver()
        for window in windows {
            // Appear as a pure opacity fade. Order the window in while invisible
            // and inside an actions-disabled transaction so the hosting view
            // mounts + renders its layers at full size NOW (no Core Animation
            // `onOrderIn` zoom), then ramp the window's alpha in. Same approach
            // as AreaSelector/RecordingFocus.
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
        // Snapshot the windows so the completion tears down exactly these,
        // not whatever a later show() may have rebuilt.
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

    /// Build one ring window per current `NSScreen`, replacing any existing set.
    /// Called on show and on display-configuration changes while active.
    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { makeRingWindow(on: $0) }
    }

    private func makeRingWindow(on screen: NSScreen) -> NSWindow {
        let hosting = NSHostingView(rootView: DevRingView(viewModel: viewModel))
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
        // Suppress AppKit's implicit window appearance animation; the ring fades
        // via the explicit `alphaValue` ramp in `show()`.
        win.animationBehavior = .none
        // Above app windows, the menu bar, and fullscreen apps — this is an
        // ambient machine-level signal, same level the capture overlay uses.
        win.level = .screenSaver
        // Purely decorative: never intercept clicks, keys, or hit-testing. The
        // user keeps working underneath it normally.
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isExcludedFromWindowsMenu = true
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.contentView?.makeBackingTransparent()
        // contentRect: is in global screen coordinates; re-set the frame after
        // construction to land the window on the right screen (non-primary
        // displays need the explicit origin).
        win.setFrame(screen.frame, display: false)
        return win
    }

    // MARK: - Screen changes

    /// Rebuild the ring set when displays are added/removed/rearranged DURING an
    /// active run, so every screen stays ringed. Only installed while active.
    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isActive else { return }
                self.rebuildWindows()
                // Newly built windows start at alpha 0 — reveal them immediately
                // (no fade; the ring is already established for this run).
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
}

// MARK: - DevRingView

/// The pulsing ring. A soft green glow that fades inward from all four screen
/// edges, breathing via an opacity-only `repeatForever` animation.
///
/// Construction: two concentric rounded-rect strokes sized to the full window
/// bounds — a wide blurred glow + a crisp inner line. Strokes are centered on
/// the bounds path, so their outer half is clipped off-screen and the inner
/// half + blur reads as a band fading inward from the edge. A small corner
/// radius keeps the four edges meeting cleanly at the screen corners.
///
/// The whole glow is flattened into a single GPU texture with `.drawingGroup()`
/// so the (expensive) blur is rasterized ONCE; the pulse then animates only the
/// flattened layer's opacity, which Core Animation composites for ~free. No blur
/// or shadow radius is animated, and the gradient is never re-rendered per frame.
private struct DevRingView: View {
    let viewModel: DevRingViewModel

    /// Drives the breathing pulse: opacity ramps between the two bounds on a
    /// gentle ease-in-out `autoreverses` `repeatForever` loop while active.
    @State private var pulsedUp = false

    // Visual tuning — thin and sleek: a crisp edge line plus a soft inward
    // falloff. Tuned to read as present-but-not-heavy.
    private let cornerRadius: CGFloat = 14
    private let crispLineWidth: CGFloat = 9
    private let glowLineWidth: CGFloat = 22
    private let glowBlur: CGFloat = 34

    private let minOpacity: CGFloat = 0.45
    private let maxOpacity: CGFloat = 1.0
    private let pulseDuration: TimeInterval = 1.9

    var body: some View {
        ZStack {
            // Wide soft glow — the inward falloff.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.vfDevAccent, lineWidth: glowLineWidth)
                .blur(radius: glowBlur)
            // Crisp inner line right at the edge.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.vfDevAccent, lineWidth: crispLineWidth)
                .blur(radius: 1.5)
        }
        // Rasterize the blurred glow ONCE into a single GPU texture so the pulse
        // below cross-fades a cached bitmap's opacity instead of recomputing the
        // blur every frame (the box-shadow CPU-pin we must not recreate).
        .drawingGroup()
        .opacity(pulsedUp ? maxOpacity : minOpacity)
        .ignoresSafeArea()
        .onAppear { if viewModel.isActive { startPulse() } }
        .onChange(of: viewModel.isActive) { _, active in
            if active { startPulse() } else { stopPulse() }
        }
    }

    private func startPulse() {
        // Seed at the low bound (no animation) so the breathe always begins from
        // the same place, then drive the repeating ramp.
        pulsedUp = false
        withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) {
            pulsedUp = true
        }
    }

    private func stopPulse() {
        // A non-repeating animation on the same property overrides the standing
        // repeatForever, settling the ring instead of leaving it mid-breath.
        withAnimation(.easeInOut(duration: 0.2)) {
            pulsedUp = false
        }
    }
}
