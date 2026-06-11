//
//  PillWindowController.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Owns the borderless, always-on-top NSWindow that hosts the recording pill.
//  The window is created lazily on first show and reused (hide() just orders
//  it out so we don't churn AppKit objects on every state transition).
//
//  State flow: the controller is initialized with an AppState, holds a small
//  @Observable view-model that the hosted PillView reads, and exposes a
//  single `update(pillState:)` entry point. `nil` hides the window; non-nil
//  shows it and animates the morph into the new PillState via withAnimation.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class PillViewModel {
    /// Last-shown pill state. Kept around even while the window is hidden
    /// so that hide → show transitions don't replay a stale morph (the
    /// controller decides whether to animate based on prior visibility).
    var pillState: PillState = .recording(elapsed: "0:00", totalDisplay: "3:00")

    /// Monotonically bumped by `PillWindowController.flashBusy()`. The
    /// host view observes changes and runs a brief scale-down-and-back
    /// animation in response — visible "your key registered but the app
    /// is busy" feedback for ⌘⇧R presses during .processing, which the
    /// hotkey handler would otherwise silently drop.
    var flashTrigger: Int = 0
}

@MainActor
final class PillWindowController {

    private let appState: AppState
    private let viewModel = PillViewModel()
    private var window: NSWindow?
    private var observationTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        startObservingAppState()
    }

    deinit {
        observationTask?.cancel()
    }

    /// Drives `update(pillState:)` from `AppState` changes for the full
    /// lifetime of the controller. Lives here — not in a SwiftUI view's
    /// `.task` — because the pill must keep tracking state regardless
    /// of which views are mounted. In particular, the MenuBarExtra's
    /// content view only mounts while its dropdown is open, so a
    /// `.task` attached there freezes pill updates the moment the menu
    /// closes (observed: hotkey would transition `AppState` to
    /// `.recording` while backgrounded, but the pill window stayed
    /// hidden until the dropdown was reopened).
    private func startObservingAppState() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.update(pillState: self.appState.pillState)

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.appState.pillState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Single entry point driven by `ZerroApp.syncPill`. `nil`
    /// hides the pill; non-nil sets the pill state and shows the window,
    /// morphing the chrome via `withAnimation`.
    func update(pillState: PillState?) {
        guard let pillState else {
            window?.orderOut(nil)
            return
        }

        ensureWindow()
        let wasVisible = window?.isVisible ?? false

        if wasVisible {
            let animation = PillState.morphAnimation(
                from: viewModel.pillState,
                to: pillState
            )
            withAnimation(animation) {
                viewModel.pillState = pillState
            }
            positionAtTopCenter(animated: true)
        } else {
            // No morph when transitioning from hidden — otherwise the
            // pill animates from whatever it was last showing (often a
            // stale `.resultCompact`), which reads as a glitch.
            viewModel.pillState = pillState
            positionAtTopCenter(animated: false)
        }

        window?.orderFrontRegardless()
        // Belt-and-suspenders: if the window's shadow region was sized
        // to include corner padding, invalidating forces AppKit to
        // recompute it against the current (transparent) backing so the
        // shadow's bounding box can't fill with a non-clear color.
        window?.invalidateShadow()
    }

    /// Visible nudge for ⌘⇧R presses that the hotkey handler intentionally
    /// drops (e.g. during .processing — the pill's Cancel is the right
    /// affordance there, not a second recording). Bumps a trigger on the
    /// view-model that the SwiftUI host watches with `.onChange`,
    /// animating a brief scale-down-and-back. No new chrome, no copy —
    /// just enough motion that the user reads the press as registered.
    func flashBusy() {
        guard window?.isVisible == true else { return }
        viewModel.flashTrigger &+= 1
    }

    // MARK: - Window setup

    private func ensureWindow() {
        guard window == nil else { return }

        let hostingView = NSHostingView(
            rootView: PillHostView(viewModel: viewModel, appState: appState)
        )
        hostingView.makeBackingTransparent()

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: hostingView.fittingSize.width, height: hostingView.fittingSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false // SwiftUI's `.shadow` already draws the pill shadow; kill the AppKit one to avoid double-shadow + corner artifacts.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // One level above .floating so the pill always stays in front of
        // the recording-focus dim (RecordingFocusWindowController, at
        // .floating) which covers the full screen during recording.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.contentView = hostingView
        // contentView is the hostingView here, but assert again through the
        // contentView accessor too (see makeBackingTransparent for why).
        win.contentView?.makeBackingTransparent()

        window = win
    }

    private func positionAtTopCenter(animated: Bool) {
        guard let window, let screen = NSScreen.main else { return }
        guard let hosting = window.contentView as? NSHostingView<PillHostView> else { return }

               // Force a layout pass so `fittingSize` reflects the SwiftUI tree's
               // NEW state (just set via `viewModel.pillState =` inside the
               // caller's withAnimation block). Without this, fittingSize can
               // lag by a cycle — the window then snaps to the OLD size while
               // the SwiftUI content morphs to the NEW one, which read as the
               // off-center "expands rightward" effect on the compact↔expanded
               // morph and left the pill x-shifted after the collapse.
               hosting.layoutSubtreeIfNeeded()
               let targetSize = hosting.fittingSize
               let visible = screen.visibleFrame
               let originX = visible.midX - targetSize.width / 2
               let originY = visible.maxY - 24 - targetSize.height
               let targetFrame = NSRect(x: originX, y: originY, width: targetSize.width, height: targetSize.height)

               if animated {
                    // Animate the full frame (origin + size) in lockstep with the
                    // SwiftUI spring so the window grows top-center anchored — top
                    // edge fixed, width grows symmetrically about center, height
                    // grows downward — instead of snapping to the new frame and
                    // letting SwiftUI play its morph on top.
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.20
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        ctx.allowsImplicitAnimation = true
                        window.animator().setFrame(targetFrame, display: true)
                    }
                } else {
                    window.setFrame(targetFrame, display: true)
                }
    }
}

// MARK: - PillHostView
//
// SwiftUI root for the pill window. Reads its `PillState` from the
// shared view-model so the controller can drive morphs by mutating
// the model inside `withAnimation`. Action closures route back into
// AppState — the pill itself stays pure.

private struct PillHostView: View {
    let viewModel: PillViewModel
    let appState: AppState

    /// Driven by viewModel.flashTrigger — when the trigger bumps, the
    /// scale animates 1.0 → 0.96 → 1.0 over ~180ms so a ⌘⇧R press during
    /// processing reads as registered-but-busy instead of silently dropped.
    @State private var flashScale: CGFloat = 1.0

    var body: some View {
        PillView(
            state: viewModel.pillState,
            onStop: { appState.stopRecording() },
            onCancel: {
                // Cancel during recording/wrapping returns to idle;
                // cancel during processing also resets to idle since
                // the state machine collapses both into the same exit.
                appState.cancelRecording()
            },
            onCopy: {
                // Phase 9 Step 6: write the generated prompt to the system
                // clipboard (see Pasteboard.copy for the replace-not-append
                // contract).
                guard let prompt = appState.generatedPrompt, !prompt.isEmpty else { return }
                Pasteboard.copy(prompt)
            },
            onToggleExpand: { appState.toggleResultExpanded() },
            onDismissError: { appState.dismissFailure() },
            onRetryError: { appState.retryFailedPrompt() },
            onDismissResult: { appState.resetToIdle() },
            // Phase 17 — confirmation-pill resolutions. Keep uses the
            // recording's selected mode (the safe default); Switch applies
            // the suggested opposite mode to this one generation only.
            onKeepMode: { appState.resolveModeSwitch(switchTo: false) },
            onSwitchMode: { appState.resolveModeSwitch(switchTo: true) },
            // M2 — recovery offer resolutions, exactly two outcomes. Generate
            // runs the recovered recording (spends the credit, with consent);
            // Discard deletes it. There is no separate dismiss affordance — any
            // other dismissal routes to Discard (delete), never leave-on-disk.
            onRecoveryGenerate: { appState.resolveRecovery(generate: true) },
            onRecoveryDiscard: { appState.resolveRecovery(generate: false) },
            generatedPrompt: appState.generatedPrompt,
            resultHadNoNarration: appState.resultHadNoNarration,
            stoppedBySleep: appState.stoppedBySleep,
            // Multi-model 6B: the "−N credits · M left" toast, formatted once
            // here so PillView stays a pure renderer of a ready-made string.
            chargeLine: appState.lastGenerationCharge.map {
                CreditDisplay.chargeLine(charged: $0.charged, remaining: $0.remaining)
            },
            audioLevels: appState.audioLevels
        )
        .scaleEffect(flashScale)
        .onChange(of: viewModel.flashTrigger) { _, _ in
            // Two-step so the property ends back at 1.0 — `repeatCount(1,
            // autoreverses: true)` returns the visual to start but
            // leaves the property at the inner value, which would block
            // the next flash from animating.
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.08)) {
                    flashScale = 0.96
                }
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeIn(duration: 0.10)) {
                    flashScale = 1.0
                }
            }
        }
    }
}
