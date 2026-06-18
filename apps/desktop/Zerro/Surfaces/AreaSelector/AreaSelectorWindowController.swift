//
//  AreaSelectorWindowController.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Owns the borderless, full-screen, transparent non-activating
//  NSPanel that hosts the area-selector overlay. Being a
//  .nonactivatingPanel lets it take key status (for its event
//  monitors) without activating the app — so triggering the hotkey
//  never raises other Zerro windows (Settings, onboarding).
//  Mirrors PillWindowController's
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
import os
import SwiftUI

@MainActor
final class AreaSelectorWindowController {

    private var window: NSWindow?
    private var state: AreaSelectorState?
    private var preferences: PreferencesStore?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Builds and shows the overlay on the screen containing the
    /// cursor. `onConfirm` fires when the user accepts a selection
    /// (Checkpoint 3) — its second argument is the generation model
    /// chosen on the toolbar for this recording (seeded from the
    /// last-used model and persisted back as last-used at confirm).
    /// `onCancel` fires on ESC. Either callback is invoked
    /// exactly once per presentation; both implicitly dismiss the
    /// overlay before invocation.
    ///
    /// `entitlements` feeds the model dropdown's per-row credit detail
    /// (Managed/Trial) and BYOK key-gating; nil (tests) renders plain
    /// model names.
    ///
    /// DEFERRED for Phase 7 handoff: multi-monitor coverage. Today
    /// we present a single overlay on the screen under the cursor;
    /// selections cannot span displays, and other displays remain
    /// undimmed. Full multi-display support would require one
    /// overlay window per NSScreen plus cross-window drag state —
    /// meaningful weight without a Phase 6 user need.
    func present(
        preferences: PreferencesStore,
        entitlements: EntitlementStore? = nil,
        onConfirm: @escaping (SelectionRect, String, DevModeSelection?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        Log.ui.debug("AreaSelector present() called")

        // Guard against double-present (e.g. hotkey pressed twice).
        // Re-presenting on top of an existing overlay would leak
        // the prior window; cleanest behavior is to ignore.
        if window != nil { return }

        guard let screen = screenUnderCursor() ?? NSScreen.main else {
            onCancel()
            return
        }

        // The full-screen toolbar floats above the Dock: stash the presenting
        // screen's bottom Dock inset (0 when hidden / on a side) so the static
        // frame helpers raise it for BOTH the view render and this controller's
        // hit-testing. visibleFrame excludes the Dock, so the bottom difference
        // is the Dock height; it auto-adapts to Dock size/position/auto-hide.
        AreaSelectorView.fullScreenBottomInset = max(0, screen.visibleFrame.minY - screen.frame.minY)

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

        // Multi-model: seed the model chip from the last model the user
        // recorded with (PreferencesStore.selectedModelID). The toolbar is
        // the ONLY model picker now; the pick lives in `state` until confirm,
        // where it is written back as the new last-used (see state.onConfirm).
        // Holding it in state until then means abandoning the overlay (ESC)
        // leaves the persisted last-used model untouched.
        state.setModels(
            Self.modelMenuItems(entitlements: entitlements),
            selectedID: preferences.selectedModelID
        )
        // The model button shows the model name, so its width is dynamic — keep
        // the shared geometry width in sync with the current selection (mirrors
        // `fullScreenBottomInset`). Read by the frame helpers on render + hit-test.
        AreaSelectorView.modelButtonWidth = AreaSelectorView.measuredModelButtonWidth(forName: state.selectedModelName)

        // Dev Mode (Phase 1): seed the mode switch + remembered folder WITHOUT
        // probing for the agent — detection runs a slow login-shell PATH lookup
        // and must stay off the hotkey→overlay path. The agent is resolved
        // asynchronously, and only when Dev Mode is (or becomes) active, so a
        // normal-mode user never triggers the shell probe.
        state.setDevState(
            isDevMode: preferences.devModeEnabled,
            agentID: nil,
            agentName: "Claude Code",
            projectURL: preferences.devProjectURL
        )
        if preferences.devModeEnabled {
            beginAgentDetection(for: state)
            // Verify the remembered folder is still a git repo (Milestone 7).
            if let folder = preferences.devProjectURL {
                beginGitRepoCheck(for: folder, state: state)
            }
        }

        state.onConfirm = { [weak self] rect in
            // Read the toolbar's model pick BEFORE dismiss() nils the
            // state. Fallback can only fire if confirm raced dismiss.
            let modelID = self?.state?.selectedModelID ?? preferences.selectedModelID
            // Persist as the last-used model so the next recording (and the
            // chip seed) starts here. Persisted at confirm (record-start), not
            // on every dropdown tap — only models actually used to record
            // become last-used. Tier 4 analytics parity with the removed
            // Settings / menu-bar pickers: fire `model_changed` only on a real
            // change, before the write.
            if modelID != preferences.selectedModelID {
                Analytics.capture("model_changed", [
                    "from_model": preferences.selectedModelID,
                    "to_model": modelID,
                    "surface": "capture_toolbar",
                ])
                preferences.selectedModelID = modelID
            }
            // Dev Mode: carry the agent + folder when the mode switch is on and
            // both are set (record-time validation guarantees this — Record is
            // blocked otherwise). nil → a normal clipboard recording.
            let devSelection: DevModeSelection? = {
                guard let s = self?.state, s.isDevMode,
                      let agentID = s.selectedAgentID, let projectURL = s.projectURL else { return nil }
                // Capture the Model section's current pick (Phase 2). nil ⇒ the
                // agent's own default (no `--model` flag).
                return DevModeSelection(agentID: agentID, projectURL: projectURL, modelID: s.selectedDevModelID)
            }()
            self?.dismiss()
            onConfirm(rect, modelID, devSelection)
        }
        state.onCancel = { [weak self] in
            self?.dismiss()
            onCancel()
        }

        let win = makeOverlayWindow(on: screen, state: state)
        self.window = win

        // Seed the overlay bounds so a Space-press into full-screen mode
        // (which selects the whole display) has the display size on hand.
        // The borderless window's contentView fills screen.frame.
        state.setOverlaySize(win.contentView?.bounds.size ?? screen.frame.size)

        // No NSApp.activate here: under .accessory policy, activating the
        // whole app re-orders EVERY Zerro window to the front (Settings,
        // onboarding, …). The overlay is a non-activating panel (see
        // makeOverlayWindow / AreaSelectorWindow), so orderFrontRegardless()
        // + makeKey() below bring just this panel forward and give it key
        // status — enough for the local event monitors to fire — without
        // touching any other window.

        // Appear as a pure opacity fade with NO scale. The "zoom in" on show
        // is Core Animation's implicit `onOrderIn` action, which runs on the
        // SwiftUI content's layers the moment they join the visible window
        // tree. Suppressing it at the window level (`animationBehavior`,
        // `alphaValue`) isn't enough because it fires on those freshly-
        // mounted sublayers. So: order the window in while it's still
        // invisible AND inside a transaction with implicit actions disabled,
        // forcing the hosting view to mount + lay out its layers right now —
        // they join the tree at full size with no `onOrderIn`. Then fade the
        // whole overlay's opacity in.
        win.alphaValue = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        win.orderFrontRegardless()
        win.contentView?.layoutSubtreeIfNeeded()
        win.contentView?.display() // force SwiftUI to render+mount layers now
        CATransaction.commit()
        win.makeKey()

        // Defer one runloop tick so any SwiftUI render that landed after the
        // synchronous layout has also settled at full size before we reveal —
        // guaranteeing the fade carries no residual scale.
        DispatchQueue.main.async { [weak win] in
            guard let win else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }

        installEventMonitors(for: win, state: state)
        installScreenChangeObserver()
        installActivationObserver()
    }

    /// Phase 10: catch the case where the overlay is presented on an
    /// external display and that display is unplugged while the overlay
    /// is open. Without this, the window is stranded — pinned to a
    /// screen that's no longer in `NSScreen.screens` — and the user has
    /// no visible affordance to recover from. On the notification, if
    /// our window's screen is gone, dismiss via the cancel path so
    /// AppState returns to .idle and the next hotkey press re-presents
    /// on the (now-only) remaining display.
    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }
    }

    /// Re-arm the keyboard when Zerro becomes active again. ⌘-Tab away
    /// makes another app's window key, so this transient, non-restorable
    /// panel resigns key and the keyDown monitor goes silent. ⌘-Tab back
    /// reactivates the app but does not restore the panel as key on its
    /// own. On reactivation, re-assert key status (makeKey, never
    /// NSApp.activate — that would re-order every Zerro window) so ESC
    /// works again without requiring a click first. Guarded on a live
    /// window so a stale notification after dismiss() is a no-op.
    private func installActivationObserver() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let window = self?.window, !window.isKeyWindow else { return }
                window.makeKey()
            }
        }
    }

    private func handleScreenParametersChanged() {
        guard let window, let screen = window.screen else {
            // No screen at all means the display the window was on has
            // detached. Route through state.cancel so the onCancel
            // callback fires (AppState's no-op onCancel keeps us at
            // .idle, which is the correct landing here).
            state?.cancel()
            return
        }
        // The window's screen object can survive the underlying display
        // disappearing for a tick; if it isn't in the live list, treat
        // it as gone.
        if !NSScreen.screens.contains(where: { $0 === screen }) {
            state?.cancel()
        }
    }

    /// Tears down the overlay window, releases the state model, and
    /// removes the event monitors. Safe to call multiple times.
    func dismiss() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        mouseMonitor = nil
        keyMonitor = nil
        screenChangeObserver = nil
        didBecomeActiveObserver = nil

        window?.orderOut(nil)
        window = nil
        state = nil
        preferences = nil
    }

    // MARK: - Event monitors

    private func installEventMonitors(for window: NSWindow, state: AreaSelectorState) {
        // .mouseMoved drives the toolbar hover feedback (Record button,
        // mic/model chips, open dropdown rows); the window has to accept
        // moved events for the monitor to see them while not tracking a drag.
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

            // Compact toolbar hit regions. The SwiftUI tree is hit-test-disabled,
            // so the controller owns clicks + hover by re-deriving each control's
            // frame from the same static helpers the view renders with. Handled
            // before the per-mode drag/settle logic so a toolbar click acts on the
            // toolbar rather than re-dragging underneath it. The mode switch is two
            // separate hit regions (Artifact | Dev), present in both modes; the
            // dev-settings icon exists only in Dev Mode.
            let size = contentView.bounds.size
            let fullScreen = state.mode == .fullScreen
            let devMode = state.isDevMode
            let selectionRect = state.confirmableSelectionRect
            let recordFrame = selectionRect.map {
                AreaSelectorView.recordButtonFrame(forSelection: $0, in: size, fullScreen: fullScreen, devMode: devMode)
            }
            let micFrame = selectionRect.map {
                AreaSelectorView.micChipFrame(forSelection: $0, in: size, fullScreen: fullScreen, devMode: devMode)
            }
            let modelFrame = selectionRect.map {
                AreaSelectorView.modelChipFrame(forSelection: $0, in: size, fullScreen: fullScreen, devMode: devMode)
            }
            let artifactFrame = selectionRect.map {
                AreaSelectorView.modeArtifactSegmentFrame(forSelection: $0, in: size, fullScreen: fullScreen, devMode: devMode)
            }
            let devSegmentFrame = selectionRect.map {
                AreaSelectorView.modeDevSegmentFrame(forSelection: $0, in: size, fullScreen: fullScreen, devMode: devMode)
            }
            let devSettingsFrame = (devMode ? selectionRect : nil).map {
                AreaSelectorView.devSettingsIconFrame(forSelection: $0, in: size, fullScreen: fullScreen)
            }
            // The whole container, so a click on toolbar chrome that misses a
            // specific control (inter-icon gaps, the divider, the padding, the
            // mode-switch well) is inert rather than starting a selection drag.
            let toolbarContainerFrame = selectionRect.map {
                AreaSelectorView.toolbarFrame(forSelection: $0, in: size, fullScreen: fullScreen, devMode: devMode)
            }

            if event.type == .mouseMoved {
                state.setRecordButtonHovered(recordFrame?.contains(point) ?? false)
                state.setMicChipHovered(micFrame?.contains(point) ?? false)
                state.setModelChipHovered(modelFrame?.contains(point) ?? false)
                state.setModeArtifactHovered(artifactFrame?.contains(point) ?? false)
                state.setModeDevHovered(devSegmentFrame?.contains(point) ?? false)
                state.setDevSettingsHovered(devSettingsFrame?.contains(point) ?? false)
                if state.isMicMenuOpen, let rect = selectionRect {
                    state.setHighlightedMicIndex(AreaSelectorView.micMenuRowIndex(
                        at: point, forSelection: rect, in: size,
                        itemCount: state.micMenuItems.count, fullScreen: fullScreen, devMode: devMode
                    ))
                }
                if state.isModelMenuOpen, let rect = selectionRect {
                    state.setHighlightedModelIndex(AreaSelectorView.modelMenuRowIndex(
                        at: point, forSelection: rect, in: size,
                        itemCount: state.models.count, fullScreen: fullScreen, devMode: devMode
                    ))
                }
                if state.isDevSettingsMenuOpen, let rect = selectionRect {
                    let agentCount = state.devAgentMenuItems.count
                    let modelCount = state.devModelMenuItems.count
                    state.setHighlightedDevAgentIndex(AreaSelectorView.devSettingsAgentRowIndex(
                        at: point, forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen
                    ))
                    state.setHighlightedDevModelIndex(AreaSelectorView.devSettingsModelRowIndex(
                        at: point, forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen
                    ))
                }
            }

            if event.type == .leftMouseDown {
                // Re-arm the keyboard. This monitor consumes the
                // leftMouseDown (returns nil) before AppKit's sendEvent:
                // runs, so the panel never goes through its normal
                // click-to-become-key path. If focus left the overlay
                // (⌘-Tab away, or another app became key) the panel is no
                // longer key and the keyDown monitor goes silent. Re-assert
                // key status here — explicitly doing what sendEvent: would —
                // so ESC/Space/Return work again after any click into the
                // overlay. makeKey() (not NSApp.activate) keeps this scoped
                // to the panel and never re-orders other Zerro windows.
                if !window.isKeyWindow { window.makeKey() }

                // Mode switch — two segments, each maps to a mode (Artifact = off,
                // Dev = on). Clicking the already-active segment is a no-op (the
                // state guards it). Handled first since the switch leads the
                // cluster. Present in BOTH modes (it's how you enter/leave Dev).
                if let artifactFrame, artifactFrame.contains(point) {
                    self?.setDevMode(false, state: state)
                    return nil
                }
                if let devSegmentFrame, devSegmentFrame.contains(point) {
                    self?.setDevMode(true, state: state)
                    return nil
                }
                // Dev-settings icon (Dev Mode) — open/close the agent+project menu.
                if let devSettingsFrame, devSettingsFrame.contains(point) {
                    state.toggleDevSettingsMenu()
                    return nil
                }
                // Record button — start recording.
                if let recordFrame, recordFrame.contains(point) {
                    self?.confirmCurrentSelection(window: window, state: state)
                    return nil
                }
                // Model icon — open/close the model dropdown (one dropdown at a
                // time; the state closes the others).
                if let modelFrame, modelFrame.contains(point) {
                    state.toggleModelMenu()
                    return nil
                }
                // Mic icon — open/close the device dropdown.
                if let micFrame, micFrame.contains(point) {
                    state.toggleMicMenu()
                    return nil
                }
                // Model dropdown open — a click selects the (non-gated) row
                // under the cursor or, if outside, dismisses. The pick lands
                // in `state` only; it's persisted as last-used at confirm
                // (state.onConfirm), not here — so a pick the user backs out
                // of never changes the stored last-used model.
                if state.isModelMenuOpen {
                    if let rect = selectionRect,
                       let idx = AreaSelectorView.modelMenuRowIndex(
                        at: point, forSelection: rect, in: size,
                        itemCount: state.models.count, fullScreen: fullScreen, devMode: devMode
                       ) {
                        let item = state.models[idx]
                        if !item.gated {
                            state.selectModel(id: item.id)
                            // New model name → re-measure the model button so the
                            // toolbar reflows around the new label.
                            AreaSelectorView.modelButtonWidth = AreaSelectorView.measuredModelButtonWidth(forName: state.selectedModelName)
                        } else {
                            // Gated row (BYOK, keyless provider): ignore the
                            // click but keep the menu open — mirrors the
                            // menu-bar picker's disabled rows.
                            return nil
                        }
                    }
                    state.closeModelMenu()
                    return nil
                }
                // Mic dropdown open — a click selects the row under the cursor
                // (persisting to prefs) or, if outside, dismisses. Either way
                // the click is consumed so it never starts a new drag.
                if state.isMicMenuOpen {
                    if let rect = selectionRect,
                       let idx = AreaSelectorView.micMenuRowIndex(
                        at: point, forSelection: rect, in: size,
                        itemCount: state.micMenuItems.count, fullScreen: fullScreen, devMode: devMode
                       ) {
                        let id = state.micMenuItems[idx].id
                        self?.preferences?.microphoneDeviceID = id
                        state.selectMicrophone(id: id)
                    }
                    state.closeMicMenu()
                    return nil
                }
                // Dev-settings menu open — an agent row picks that agent (or, for
                // a not-installed agent, opens its install docs); the project row
                // opens the folder picker; a click elsewhere dismisses. The menu
                // stays open after a row action so the user can finish setup.
                if state.isDevSettingsMenuOpen {
                    if let rect = selectionRect {
                        let agentCount = state.devAgentMenuItems.count
                        let modelCount = state.devModelMenuItems.count
                        if let idx = AreaSelectorView.devSettingsAgentRowIndex(
                            at: point, forSelection: rect, in: size,
                            agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen
                        ) {
                            self?.selectDevAgent(at: idx, state: state)
                            return nil
                        }
                        if let idx = AreaSelectorView.devSettingsModelRowIndex(
                            at: point, forSelection: rect, in: size,
                            agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen
                        ) {
                            self?.selectDevModel(at: idx, state: state)
                            return nil
                        }
                        let projectRow = AreaSelectorView.devSettingsProjectRowFrame(
                            forSelection: rect, in: size, agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen
                        )
                        if projectRow.contains(point) {
                            self?.presentFolderPicker(window: window, state: state)
                            return nil
                        }
                    }
                    state.closeDevSettingsMenu()
                    return nil
                }
                // No control was hit and no menu was open. If the press landed
                // anywhere on the toolbar container (a gap, the divider, the
                // padding, the mode-switch well), consume it so toolbar chrome
                // never starts a selection drag. Clicks on the dimmed capture
                // area below fall through to begin a new drag.
                if let toolbarContainerFrame, toolbarContainerFrame.contains(point) {
                    return nil
                }
            }

            // Drag-to-select. A mouseDown starting a drag flips back to
            // .area (see beginDrag), so drawing a rectangle after Space
            // supersedes the full-screen selection.
            switch event.type {
            case .leftMouseDown:
                state.beginDrag(at: point)
            case .leftMouseDragged:
                // Only extend an in-flight drag. A press that began on a
                // toolbar control (model/mic chip, dropdown row) was
                // consumed at mouseDown without calling beginDrag, so
                // isDragging is false here — and its trailing dragged/up
                // events must NOT resize the already-settled selection.
                if state.isDragging { state.updateDrag(to: point) }
            case .leftMouseUp:
                if state.isDragging { state.endDrag(at: point) }
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
                // ESC closes an open toolbar dropdown first (mic, model, or
                // dev-settings), so the first press dismisses the menu and only a
                // second press cancels the whole overlay.
                if state.isMicMenuOpen {
                    state.closeMicMenu()
                    return nil
                }
                if state.isModelMenuOpen {
                    state.closeModelMenu()
                    return nil
                }
                if state.isDevSettingsMenuOpen {
                    state.closeDevSettingsMenu()
                    return nil
                }
                state.cancel()
                return nil
            case 49: // Space — select the whole display (one-way)
                self?.enterFullScreen(window: window, state: state)
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

    /// Enter full-screen mode in response to Space: select the entire
    /// display the overlay is on. One-way — there is no Space toggle back
    /// to drag mode; drawing a new rectangle returns to an area selection.
    /// Seeds the overlay bounds so the full-display `confirmableSelectionRect`
    /// (and the bottom-center toolbar) resolve immediately.
    private func enterFullScreen(window: NSWindow, state: AreaSelectorState) {
        let size = window.contentView?.bounds.size ?? window.frame.size
        state.enterFullScreenMode(overlaySize: size)
    }

    /// Builds a `SelectionRect` in global AppKit screen coordinates from
    /// the current selection and forwards it to the state's confirm
    /// callback. In `.area`, selections below
    /// `AreaSelectorState.minimumSelectionSize` on either axis (including
    /// zero-size) are a no-op — the overlay stays open — so an accidental
    /// Return without a real drag doesn't kick off a recording of nothing.
    /// In `.fullScreen`, the whole display is always confirmable.
    private func confirmCurrentSelection(window: NSWindow, state: AreaSelectorState) {
        // Dev Mode record-time validation: both an agent and a folder must be
        // chosen before a recording can dispatch to the agent. Replaces the
        // first-run popover as the dead-end guard (design §1). Inert in normal
        // mode (`devRequirementsMet` is always true there).
        guard state.devRequirementsMet else {
            // Agent state takes precedence — picking a folder won't unblock until
            // the CLI resolves. Order: still detecting → not installed → folder.
            let message: String
            if state.isDetectingAgent {
                message = "Checking for Claude Code…"
            } else if state.isAgentMissing {
                message = "Install Claude Code to use Dev Mode."
            } else {
                message = "Pick a folder to work in before recording."
            }
            state.setDevValidationMessage(message)
            return
        }
        switch state.mode {
        case .area:
            confirmAreaSelection(window: window, state: state)
        case .fullScreen:
            confirmFullScreenSelection(window: window, state: state)
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
            screenDisplayID: window.screen?.displayID,
            target: .area
        )
        state.confirm(with: selection)
    }

    /// Confirms a full-screen selection: the whole display the overlay is
    /// on. The rect is the display's full frame in global AppKit space
    /// (`window.frame` already lives there); capture ignores the rect and
    /// filters on `screenDisplayID` via `SCContentFilter(display:)`, so the
    /// menu bar and everything else is captured with no crop.
    private func confirmFullScreenSelection(window: NSWindow, state: AreaSelectorState) {
        let selection = SelectionRect(
            rect: window.frame,
            screenLocalizedName: window.screen?.localizedName,
            screenDisplayID: window.screen?.displayID,
            target: .fullScreen
        )
        state.confirm(with: selection)
    }

    /// View-local (top-left, point) → global AppKit (bottom-left, point).
    /// contentView fills the borderless window, so its bounds height
    /// equals the window's content height; the window's frame origin is
    /// already in the global AppKit space, so a Y-flip plus an offset
    /// lands us there. Used by the area confirm path (full-screen confirm
    /// uses `window.frame` directly, already global).
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

    // MARK: - Dev Mode (Phase 1)
    //
    // The mode switch + folder picker mirror how the controller owns the
    // mic/model pickers: state holds the selection, the controller persists it
    // to PreferencesStore and runs the native panel. Milestone 2 replaces the
    // hard-coded agent default with live `DevAgentRegistry` detection.

    /// Where the dev-settings menu's "Install" hint points when a CLI isn't found
    /// on PATH, per agent (Claude Code's setup docs are the fallback).
    private static let claudeCodeInstallURL = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
    private static let codexInstallURL = URL(string: "https://developers.openai.com/codex/cli/")!

    private static func installURL(forAgent agentID: String) -> URL {
        switch agentID {
        case DevAgentRegistry.codexID: return codexInstallURL
        default:                       return claudeCodeInstallURL
        }
    }

    /// Set the mode from a mode-switch segment click. Clicking the already-active
    /// segment is a no-op (the state guards it) — so persistence, analytics, and
    /// detection only fire on a real change. Turning Dev ON resolves the agent
    /// off-main and verifies a remembered folder's git status. The user's explicit
    /// Dev click also offers the setup menu via `handleDevModeEntered` (its
    /// auto-open guard decides whether it actually opens) — this is the ONLY
    /// auto-open trigger; seeding/present never calls it.
    private func setDevMode(_ on: Bool, state: AreaSelectorState) {
        let changed = state.isDevMode != on
        state.setDevMode(on)
        // Clicking the already-active segment is a no-op — no persistence,
        // analytics, detection, or auto-open re-fires.
        guard changed else { return }
        // The mode change resizes + re-centers the container, so the controls
        // move out from under the cursor; clear the now-stale hover highlights
        // (the next mouse-move re-establishes them).
        state.resetToolbarHovers()
        preferences?.devModeEnabled = on
        Analytics.capture("dev_mode_toggled", ["enabled": on])
        if on {
            beginAgentDetection(for: state)
            if let folder = state.projectURL {
                beginGitRepoCheck(for: folder, state: state)
            }
            // The user's Dev ENTRY offers the setup menu (the auto-open guard
            // decides whether it actually opens — first entry this session, or
            // folder unset). Re-opening later is done via the dev-settings icon.
            state.handleDevModeEntered()
        }
    }

    /// Act on a dev-settings menu Agent row: an installed agent becomes the
    /// selection (persisted); a not-installed one opens its install docs.
    private func selectDevAgent(at index: Int, state: AreaSelectorState) {
        guard index >= 0, index < state.devAgentMenuItems.count else { return }
        let item = state.devAgentMenuItems[index]
        if item.installed {
            state.setSelectedAgent(id: item.id, name: item.name)
            preferences?.selectedAgentID = item.id
            // The model list is per-agent — repopulate the Model section for the
            // newly-selected agent (its remembered pick, else newest).
            refreshDevModelItems(forAgent: item.id, state: state)
        } else {
            // A not-installed agent row opens that agent's install docs.
            NSWorkspace.shared.open(Self.installURL(forAgent: item.id))
        }
    }

    /// Act on a dev-settings menu Model row: remember the pick for the current
    /// agent (persisted) and checkmark it. No-op without a selected agent.
    private func selectDevModel(at index: Int, state: AreaSelectorState) {
        guard index >= 0, index < state.devModelMenuItems.count,
              let agentID = state.selectedAgentID else { return }
        let item = state.devModelMenuItems[index]
        preferences?.selectedModelByAgent[agentID] = item.id
        state.setSelectedDevModelID(item.id)
    }

    /// Populate the Model section for `agentID`: the agent's available models
    /// (manifest provider, or the Cursor CLI) and the resolved pick (remembered,
    /// else newest/rank-0). Reads through `PreferencesStore.selectedModel(...)`
    /// so a retired remembered pick falls back to newest. The list is ALWAYS
    /// non-empty for a manifest agent (cache→bundled fallback), so offline never
    /// empties the section.
    private func refreshDevModelItems(forAgent agentID: String?, state: AreaSelectorState) {
        guard let agentID else {
            state.setDevModelMenuItems([], selectedID: nil)
            return
        }
        let available = AgentModelManifestStore.shared.models(forAgent: agentID)
        let items = available.map { AreaSelectorState.DevModelMenuItem(id: $0.modelID, name: $0.displayName) }
        let selected = preferences?.selectedModel(forAgent: agentID, available: available)
        // Persist the resolved default so the captured `DevModeSelection` and the
        // checkmark agree even before the user touches the Model section.
        if let selected, preferences?.selectedModelByAgent[agentID] == nil {
            preferences?.selectedModelByAgent[agentID] = selected
        }
        state.setDevModelMenuItems(items, selectedID: selected)
    }

    /// Warm agent detection (background, cached) and apply the result to the
    /// live overlay state when it lands — even if it finishes after `present()`
    /// (the chip + validation update reactively via `@Observable`). Synchronous
    /// when detection already completed this launch (no flicker).
    private func beginAgentDetection(for state: AreaSelectorState) {
        state.setDetectingAgent(true)
        DevAgentDetection.shared.warm { [weak self, weak state] entries in
            guard let state else { return }
            self?.applyAgentDetection(entries, to: state)
        }
        // Phase 2: refresh the server model manifest in the background (covers a
        // session that launched in normal mode, where ZerroApp didn't warm it).
        // When it lands, re-seed the Model section for the current agent so
        // freshly-fetched models appear. Fail-open — offline keeps cache/bundled.
        Task { [weak self, weak state] in
            await AgentModelManifestStore.shared.warm()
            guard let self, let state else { return }
            self.refreshDevModelItems(forAgent: state.selectedAgentID, state: state)
        }
    }

    /// Reconcile detection results into `state`: select the installed agent (or
    /// nil → install attention state) and remember it for next time.
    private func applyAgentDetection(_ entries: [DevAgentEntry], to state: AreaSelectorState) {
        state.setDetectingAgent(false)
        // Seed the dev-settings menu's Agent rows from every known agent; the
        // green check + "Detected" badge vs. dim "Install" hint follow `installed`.
        state.setDevAgentMenuItems(entries.map {
            .init(id: $0.id, name: $0.displayName, installed: $0.installed)
        })
        let claude = entries.first { $0.id == DevAgentRegistry.recommendedID }
        guard claude?.installed == true, let claude else {
            // Not installed: agent stays unset so validation blocks; keep the
            // display name for the menu's install affordance. No agent → no models.
            state.setSelectedAgent(id: nil, name: claude?.displayName ?? "Claude Code")
            state.setDevModelMenuItems([], selectedID: nil)
            return
        }
        let id = preferences?.selectedAgentID ?? claude.id
        state.setSelectedAgent(id: id, name: claude.displayName)
        // Persist the detected agent so a returning user lands pre-filled.
        if preferences?.selectedAgentID == nil {
            preferences?.selectedAgentID = id
        }
        // Seed the Model section for the resolved agent (Phase 2).
        refreshDevModelItems(forAgent: id, state: state)
    }

    /// Open a directories-only `NSOpenPanel` to choose the project folder.
    /// Because the overlay sits at `.screenSaver` level (and the app isn't
    /// activated when the overlay shows), the overlay is temporarily dropped
    /// below the panel and the app is activated for the modal, then the overlay
    /// is restored + re-keyed so ESC/Return keep working.
    private func presentFolderPicker(window: NSWindow, state: AreaSelectorState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the project folder Dev Mode will work in"
        if let current = state.projectURL { panel.directoryURL = current }

        // The overlay sits at `.screenSaver` level, and Zerro is a menu-bar app
        // that shows the overlay WITHOUT activating (so other apps' windows keep
        // their order). An NSOpenPanel from a non-active app at the default
        // window level therefore opens BEHIND the screenSaver-level overlay —
        // and setting `panel.level` before `runModal()` is unreliable (the panel
        // re-levels itself when shown). So for the duration of the modal: drop
        // the overlay below the panel, raise the panel, and bring the app
        // forward; restore the overlay afterward.
        let overlayLevel = window.level
        window.level = .normal
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)

        let response = panel.runModal()

        // Restore the overlay to its on-top level + re-key it so ESC/Return work.
        window.level = overlayLevel
        window.makeKeyAndOrderFront(nil)

        if response == .OK, let url = panel.url {
            state.setProjectURL(url)
            preferences?.devProjectURL = url
            // Dev Mode needs a git repo for its checkpoint/revert (Milestone 7).
            // Verify async so the user learns BEFORE recording if the folder
            // isn't one — non-blocking, mirrors agent detection.
            beginGitRepoCheck(for: url, state: state)
        }
    }

    /// Verify `url` is inside a git work tree off the main thread and reflect the
    /// verdict on the folder chip (Milestone 7). Guarded against a stale result
    /// (the user picking a second folder before the first probe lands) by
    /// re-checking the live `projectURL` on apply.
    private func beginGitRepoCheck(for url: URL, state: AreaSelectorState) {
        state.setCheckingGitRepo(true)
        Task.detached(priority: .utility) { [weak state] in
            let isRepo = (try? GitCheckpointService(projectURL: url))?.isRepository() ?? false
            await MainActor.run {
                guard let state, state.projectURL == url else { return }
                state.setProjectGitRepo(isRepo)
            }
        }
    }

    // MARK: - Model picker rows
    //
    // Display data for the toolbar's model dropdown, computed once at
    // present time (same lifecycle as the mic list). Rows are model names
    // only — NO per-model cost anywhere (metered-credits Phase 4). BYOK
    // key-gates by provider, carrying an "add key" hint as the only detail
    // text; every other mode renders plain names.
    private static func modelMenuItems(
        entitlements: EntitlementStore?
    ) -> [AreaSelectorState.ModelMenuItem] {
        // Only BYOK needs per-provider key-gating; every other mode renders
        // plain names with no detail.
        var gatedProviders: Set<ModelProvider> = []
        if case .byok = entitlements?.state {
            let available = ProviderKeys.availableProviders()
            gatedProviders = Set(ModelProvider.allCases).subtracting(available)
        }

        return ModelRegistry.enabled.map { model in
            let gated = gatedProviders.contains(model.provider)
            return .init(
                id: model.id,
                name: model.displayName,
                detail: gated ? "Add \(model.provider.displayName) key" : nil,
                recommended: model.recommended,
                gated: gated
            )
        }
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

        // .nonactivatingPanel: the overlay takes key status (for its
        // mouse/ESC local monitors) without activating the app, so no other
        // Zerro window is raised when the hotkey fires. See AreaSelectorWindow.
        let win = AreaSelectorWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // NSPanel hides itself on app deactivation by default; since we
        // deliberately never activate the app, that would whisk the overlay
        // away on a stray deactivation event — keep it pinned.
        win.hidesOnDeactivate = false
        // We DO need key status (ESC), so the panel must become key on
        // makeKey() rather than only when a subview demands first responder.
        win.becomesKeyOnlyIfNeeded = false
        // Suppress AppKit's implicit window appearance animation; `present`
        // reveals the overlay with an explicit opacity-only fade so the dim
        // never scales/zooms up on show.
        win.animationBehavior = .none
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
        // After contentViewController is set, the controller's view becomes
        // the window's contentView — make that view's backing transparent
        // (see makeBackingTransparent for why).
        win.contentView?.makeBackingTransparent()
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

/// Borderless, non-activating NSPanel subclass that allows itself to
/// become key. As an NSPanel with `.nonactivatingPanel`, it can take
/// key status — so its mouse/ESC local monitors fire — WITHOUT
/// activating the app, which under `.accessory` policy would re-order
/// every Zerro window (Settings, onboarding, …) to the front. The
/// `canBecomeKey` override is still required: a panel whose styleMask
/// is just `.borderless`/`.nonactivatingPanel` otherwise refuses key
/// status, which would block keyDown(ESC) from reaching the responder
/// chain.
private final class AreaSelectorWindow: NSPanel {
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
