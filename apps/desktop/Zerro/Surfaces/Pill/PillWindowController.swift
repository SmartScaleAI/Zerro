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
    /// is busy" feedback for recording-hotkey presses during .processing, which the
    /// hotkey handler would otherwise silently drop.
    var flashTrigger: Int = 0

    /// Phase 5 — called by the host view whenever the SwiftUI content's
    /// size changes OUTSIDE a state morph: the expanded result's content
    /// re-measures itself (HeightCappedScroll), which doesn't pass through
    /// `update(pillState:)`. The controller re-fits the window in response;
    /// it no-ops when the fitting size already matches the last target, so
    /// the per-frame geometry churn DURING a morph animation never fights
    /// the animator.
    @ObservationIgnored var onContentSizeChanged: (() -> Void)?
}

@MainActor
final class PillWindowController {

    private let appState: AppState
    private let viewModel = PillViewModel()
    private var window: NSWindow?
    private var observationTask: Task<Void, Never>?

    /// The size `positionAtTopCenter` last fit the window to. Lets
    /// `contentSizeDidChange` distinguish a REAL content-size change (a
    /// HeightCappedScroll measurement landing)
    /// from the animated in-between sizes a morph reports every frame —
    /// `fittingSize` reflects the final layout, so during a morph it equals
    /// this target and the handler no-ops.
    private var lastTargetSize: CGSize = .zero

    init(appState: AppState) {
        self.appState = appState
        viewModel.onContentSizeChanged = { [weak self] in
            // The geometry callback fires DURING the hosting view's SwiftUI
            // layout pass. Re-entering AppKit layout from inside it
            // (fittingSize / layoutSubtreeIfNeeded in the handler) is
            // illegal — AppKit logs "NSHostingView is being laid out
            // reentrantly" and SKIPS the pass, which is how the morph could
            // observe a degenerate 0×0 fitting size in the first place.
            // Defer one runloop turn so the re-fit always runs against a
            // finished layout; `lastTargetSize` dedupes the extra calls a
            // single animation frame can enqueue.
            DispatchQueue.main.async { self?.contentSizeDidChange() }
        }
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

    /// Visible nudge for recording-hotkey presses that the hotkey handler intentionally
    /// drops (e.g. during .processing — the pill's Cancel is the right
    /// affordance there, not a second recording). Bumps a trigger on the
    /// view-model that the SwiftUI host watches with `.onChange`,
    /// animating a brief scale-down-and-back. No new chrome, no copy —
    /// just enough motion that the user reads the press as registered.
    func flashBusy() {
        guard window?.isVisible == true else { return }
        viewModel.flashTrigger &+= 1
    }

    /// Re-fits the window when the SwiftUI content changed size on its own
    /// (a late scroll-height measurement) — changes that never
    /// pass through `update(pillState:)` and would otherwise clip against
    /// the stale window frame.
    private func contentSizeDidChange() {
        guard let window, window.isVisible else { return }
        // Don't re-fit a pill that's logically on its way out. This handler runs
        // deferred (DispatchQueue.main.async), so by the time it executes the
        // `.idle → nil` transition is already reflected in `appState.pillState`.
        // Without this guard, the teardown frame (where `parsedResponse` is nil
        // and the result view briefly renders an empty/placeholder card) would
        // re-measure and animate the window to that card's height before the
        // observation Task orders the window out — the dismiss "height flash".
        // A still-visible result keeps a non-nil pillState, so legitimate
        // re-fits (late HeightCappedScroll measurements) are unaffected.
        guard appState.pillState != nil else { return }
        guard let hosting = window.contentView as? NSHostingView<PillHostView> else { return }
        let fitting = hosting.fittingSize
        // During a morph the geometry callback fires every animation frame
        // with in-between sizes, but fittingSize stays at the morph's final
        // layout — which positionAtTopCenter already targeted. Only a
        // genuinely new fitting size warrants a re-fit.
        guard abs(fitting.width - lastTargetSize.width) > 0.5
                || abs(fitting.height - lastTargetSize.height) > 0.5 else { return }
        positionAtTopCenter(animated: true)
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

    /// Whether `fittingSize` describes a window frame the pill may actually
    /// be driven to. SwiftUI can transiently report 0×0 mid-transition (the
    /// hosting view's tree hasn't committed the morphed state yet); a frame
    /// set from that value renders the pill invisible. Pure so the invariant
    /// is unit-testable.
    nonisolated static func isRenderableFitting(_ size: CGSize) -> Bool {
        size.width >= 1 && size.height >= 1
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
               // A mid-transition layout can report a DEGENERATE fitting size —
               // observed as 0×0 during the .processing → .resultExpanded morph.
               // Driving the frame there shrinks the pill into nothing, and if no
               // later geometry event follows, it stays invisible (the launch-QA
               // "pill disappears after stop" bug). Skip instead: the window keeps
               // its last good frame, and the content-size observation re-fires
               // with the settled size and re-fits.
               guard Self.isRenderableFitting(targetSize) else { return }
               lastTargetSize = targetSize
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
    /// scale animates 1.0 → 0.96 → 1.0 over ~180ms so a recording-hotkey press during
    /// processing reads as registered-but-busy instead of silently dropped.
    @State private var flashScale: CGFloat = 1.0

    /// Phase 6 — AppState's conversion lifecycle, mapped to the pill's
    /// render-only affordance enum. `.hidden` whenever the feature doesn't
    /// apply (a card is present, no result, not in .done).
    private var conversionAffordance: ConversionAffordance {
        guard appState.canConvertToAgentPrompt else { return .hidden }
        switch appState.conversionStatus {
        case .idle: return .available
        case .running: return .running
        case .failed: return .failed
        }
    }

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
                // Typed-artifact refactor: copy per the §2 per-type payload
                // table — agent_prompt copies body + Attached Context, other
                // types the body alone, chat-only the chat text; raw output
                // as the fallback when parsing produced no structure. (See
                // Pasteboard.copy for the replace-not-append contract.)
                guard let payload = appState.resultCopyPayload, !payload.isEmpty else { return }
                Pasteboard.copy(payload)
            },
            onToggleExpand: { appState.toggleResultExpanded() },
            onDismissError: { appState.dismissFailure() },
            onRetryError: { appState.retryFailedPrompt() },
            // Error pill's "Retry" fallback (non-retryable failure): dismiss
            // the pill and reopen the screen-region selector to record again.
            onErrorRetryRegion: { appState.retryRecordingFromRegion() },
            // M5 — resume a paid-blocked recording after the user pays.
            onResumePaidGeneration: { appState.resumePaidGeneration() },
            onDismissResult: { appState.resetToIdle() },
            // M2 — recovery offer resolutions, exactly two outcomes. Generate
            // runs the recovered recording (spends the credit, with consent);
            // Discard deletes it. There is no separate dismiss affordance — any
            // other dismissal routes to Discard (delete), never leave-on-disk.
            onRecoveryGenerate: { appState.resolveRecovery(generate: true) },
            onRecoveryDiscard: { appState.resolveRecovery(generate: false) },
            // Dev Mode (M7) terminal-card actions: restore the tree to the
            // checkpoint, or re-dispatch the same prompt.
            onDevRevert: { appState.revertDevDispatch() },
            onDevRetry: { appState.retryDevDispatch() },
            // Dev Mode (M6) confirmAnchors gate: Confirm proceeds with the
            // dispatch; Cancel aborts before the agent runs (safe teardown).
            onConfirmAnchors: { appState.confirmAnchorsAndProceed() },
            onDeclineAnchors: { appState.declineAnchors() },
            // Phase 5: the parsed result — chat text + optional artifact
            // card.
            result: appState.resultPresentation,
            // Phase 6: the "Write agent prompt" ghost button on artifact-less
            // results, mapped from AppState's conversion lifecycle.
            conversion: conversionAffordance,
            onConvert: { appState.convertToAgentPrompt() },
            resultHadNoNarration: appState.resultHadNoNarration,
            stoppedBySleep: appState.stoppedBySleep,
            // Multi-model 6B: the "−N credits · M left" toast, formatted once
            // here so PillView stays a pure renderer of a ready-made string.
            chargeLine: appState.lastGenerationCharge.map {
                CreditDisplay.chargeLine(charged: $0.charged, remaining: $0.remaining)
            },
            audioLevels: appState.audioLevels
        )
        // Phase 5: surface content-size changes that bypass the state
        // machine (HeightCappedScroll measurements) so the
        // controller can re-fit the window. The controller filters out the
        // per-frame churn a morph animation produces.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { _ in
            viewModel.onContentSizeChanged?()
        }
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
