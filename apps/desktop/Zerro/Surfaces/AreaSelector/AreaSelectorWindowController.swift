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
    /// Accumulates trackpad scroll deltas (points) for the dev-settings Model
    /// viewport; steps the offset one row each time it crosses `devMenuRowHeight`.
    /// Reset at the start of each scroll gesture.
    private var devModelScrollAccum: CGFloat = 0
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
    /// `offerToolbarWalkthrough` — when true AND the walkthrough hasn't been
    /// seen, the overlay opens with a seeded full-screen selection and the
    /// first-run toolbar tour running (see the end of this method). The
    /// hotkey path passes onboarding-complete here; the default false keeps
    /// every other caller (and tests) on the pre-walkthrough behavior.
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
        offerToolbarWalkthrough: Bool = false,
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
        // Trial model-lock: hand the (observable) entitlement store to the state
        // so the chip can show the free model + lock glyph and tapping it opens
        // the upgrade popup. nil (tests) → never locked, full picker as before.
        state.setEntitlements(entitlements)
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
        // Seed the dev-settings "Auto-Detect Project" toggle (default OFF) so the
        // menu's switch reflects the persisted opt-in.
        state.setAutoDetectProjectEnabled(preferences.devAutoDetectProject)
        // Seed the Permissions section's checkmark from the persisted mode.
        state.setDevPermissionTier(preferences.devPermissionTier)
        if preferences.devModeEnabled {
            beginAgentDetection(for: state)
            // Verify the remembered folder is still a git repo (Milestone 7).
            if let folder = preferences.devProjectURL {
                beginGitRepoCheck(for: folder, state: state)
            }
            // Phase 3: try to auto-match the folder to the browser's localhost port.
            beginLocalhostFolderDetection(for: state)
        }

        state.onConfirm = { [weak self] rect in
            // Read the toolbar's model pick BEFORE dismiss() nils the
            // state. Fallback can only fire if confirm raced dismiss.
            //
            // Two distinct ids: the RAW pick (what becomes last-used) and the
            // EFFECTIVE id generation runs (forced to the free model while the
            // trial model-lock is active). Persisting only the RAW pick means a
            // locked trial user's prior preference is never overwritten — it's
            // restored the moment they upgrade.
            let rawModelID = self?.state?.selectedModelID ?? preferences.selectedModelID
            let effectiveModelID = self?.state?.effectiveModelID ?? rawModelID
            // Persist as the last-used model so the next recording (and the
            // chip seed) starts here. Persisted at confirm (record-start), not
            // on every dropdown tap — only models actually used to record
            // become last-used. Tier 4 analytics parity with the removed
            // Settings / menu-bar pickers: fire `model_changed` only on a real
            // change, before the write.
            if rawModelID != preferences.selectedModelID {
                Analytics.capture("model_changed", [
                    "from_model": preferences.selectedModelID,
                    "to_model": rawModelID,
                    "surface": "capture_toolbar",
                ])
                preferences.selectedModelID = rawModelID
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
            onConfirm(rect, effectiveModelID, devSelection)
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

        // First-run toolbar walkthrough (plan §6): offered only when the
        // caller says so (the hotkey path, post-onboarding) and only until
        // it's been seen. Seed a full-screen selection first so the toolbar
        // is on screen for the coach-marks to anchor to — the user can drag
        // a custom region once the tour ends. The seen flag is written on
        // complete or Esc dismiss (finishToolbarWalkthrough), NOT here, so an
        // interrupted first open still teaches next time.
        if offerToolbarWalkthrough, preferences.toolbarWalkthroughSeen == false {
            state.enterFullScreenMode(overlaySize: win.contentView?.bounds.size ?? screen.frame.size)
            state.startToolbarWalkthrough()
            Analytics.capture("area_toolbar_walkthrough_started")
            Analytics.capture("area_toolbar_walkthrough_step_viewed",
                              ["step": ToolbarWalkthroughStep.mode.analyticsName])
        }
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
            .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .scrollWheel
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

            // Scroll wheel — when the dev-settings menu is open and the pointer is
            // over the (capped) Model viewport, scroll the model list. Routed
            // through this monitor because the SwiftUI tree is hit-test-disabled (a
            // ScrollView would never receive the event, and its offset would desync
            // from the geometry-based hit-testing). Consumed only when handled.
            if event.type == .scrollWheel {
                if let rect = (state.isDevSettingsMenuOpen ? selectionRect : nil),
                   self?.handleDevModelScroll(event: event, at: point, forSelection: rect,
                                              in: size, fullScreen: fullScreen, state: state) == true {
                    return nil
                }
                return event
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
                if state.isUpgradePopupOpen, let rect = selectionRect {
                    let buttonFrame = AreaSelectorView.upgradeButtonFrame(
                        forSelection: rect, in: size, fullScreen: fullScreen, devMode: devMode
                    )
                    state.setUpgradeButtonHovered(buttonFrame.contains(point))
                }
                if state.isDevSettingsMenuOpen, let rect = selectionRect {
                    let agentCount = state.devAgentMenuItems.count
                    let modelCount = state.devModelMenuItems.count
                    let expanded = state.expandedDevSection
                    // Option-row highlights (only meaningful while the section is
                    // expanded — the helpers return nil otherwise).
                    state.setHighlightedDevAgentIndex(AreaSelectorView.devSettingsAgentRowIndex(
                        at: point, forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                    ))
                    state.setHighlightedDevModelIndex(AreaSelectorView.devSettingsModelRowIndex(
                        at: point, forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount,
                        scrollOffset: state.devModelScrollOffset, expanded: expanded, fullScreen: fullScreen
                    ))
                    state.setHighlightedDevPermissionIndex(AreaSelectorView.devSettingsPermissionRowIndex(
                        at: point, forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                    ))
                    // Collapsed summary-row hover highlight (cosmetic).
                    var hoveredSummary: AreaSelectorState.DevMenuSection? = nil
                    for section in [AreaSelectorState.DevMenuSection.agent, .model, .permissions] {
                        let frame = AreaSelectorView.devSettingsSummaryRowFrame(
                            section, forSelection: rect, in: size,
                            agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
                        if frame.contains(point) { hoveredSummary = section; break }
                    }
                    state.setHoveredDevSummary(hoveredSummary)
                    // Auto-Detect info-icon hover → drives the custom tooltip (the
                    // glyph's `.help` can't fire through the hit-test-disabled tree).
                    let infoIcon = AreaSelectorView.devSettingsAutoDetectInfoIconRect(
                        forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                    )
                    state.setAutoDetectInfoHovered(infoIcon.contains(point))
                    // Permissions summary-row safety icon (git-shield / ⚠) hover →
                    // its custom tooltip. Hover-only: non-interactive, so it never
                    // affects the row's open/close click.
                    let safetyIcon = AreaSelectorView.devSettingsPermissionSafetyIconRect(
                        forSelection: rect, in: size,
                        agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                    )
                    state.setPermissionSafetyHovered(safetyIcon.contains(point))
                    // Per-tier safety icons on the EXPANDED option rows → each shows
                    // its own tooltip on hover (same copy as the summary icon would
                    // for that tier).
                    var optionSafety: Int? = nil
                    if expanded == .permissions {
                        for row in 0..<AreaSelectorView.devPermissionRowCount {
                            let r = AreaSelectorView.devSettingsPermissionOptionSafetyIconRect(
                                forSelection: rect, in: size,
                                agentCount: agentCount, modelCount: modelCount,
                                rowIndex: row, expanded: expanded, fullScreen: fullScreen)
                            if r.contains(point) { optionSafety = row; break }
                        }
                    }
                    state.setHoveredPermissionOptionSafety(optionSafety)
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

                // First-run walkthrough: while the tour is active it owns
                // EVERY click. Only the callout's Back/Next act (hit-tested
                // against the same static frames the view renders them at —
                // the SwiftUI buttons are visual-only); any other press is
                // inert, so no toolbar control fires and no selection drag
                // begins under the tour. Esc (key monitor) dismisses early.
                if let step = state.toolbarWalkthroughStep {
                    if let rect = selectionRect {
                        switch AreaSelectorView.walkthroughHit(
                            at: point, for: step,
                            forSelection: rect, in: size,
                            fullScreen: fullScreen, devMode: devMode
                        ) {
                        case .next: self?.walkthroughNextTapped(state: state); return nil
                        case .back: self?.walkthroughBackTapped(state: state); return nil
                        case .none: break
                        }
                    }
                    return nil   // all other presses inert while the tour runs
                }

                // While a dropdown/popup is open it owns clicks: the menu sits
                // visually above the toolbar, so a press inside a control's frame
                // must route to the menu (select the row under the cursor, or
                // dismiss) rather than fire the control underneath. Without this,
                // Record (and the other controls) trigger "through" the open agent
                // & project menu. Suppress the toolbar-control handlers here; the
                // menu-open blocks further down do the routing.
                let anyMenuOpen = state.isModelMenuOpen || state.isMicMenuOpen
                    || state.isUpgradePopupOpen || state.isDevSettingsMenuOpen

                // Mode switch — two segments, each maps to a mode (Artifact = off,
                // Dev = on). Clicking the already-active segment is a no-op (the
                // state guards it). Handled first since the switch leads the
                // cluster. Present in BOTH modes (it's how you enter/leave Dev).
                if !anyMenuOpen, let artifactFrame, artifactFrame.contains(point) {
                    self?.setDevMode(false, state: state)
                    return nil
                }
                if !anyMenuOpen, let devSegmentFrame, devSegmentFrame.contains(point) {
                    self?.setDevMode(true, state: state)
                    return nil
                }
                // Dev-settings icon (Dev Mode) — open/close the agent+project menu.
                if !anyMenuOpen, let devSettingsFrame, devSettingsFrame.contains(point) {
                    state.toggleDevSettingsMenu()
                    return nil
                }
                // Record button — start recording.
                if !anyMenuOpen, let recordFrame, recordFrame.contains(point) {
                    self?.confirmCurrentSelection(window: window, state: state)
                    return nil
                }
                // Model icon — when the trial model-lock is active, open the
                // upgrade popup instead of the (premium) model list. Otherwise
                // open/close the model dropdown (one surface at a time; the state
                // closes the others).
                if !anyMenuOpen, let modelFrame, modelFrame.contains(point) {
                    if state.isModelPickerLocked {
                        state.toggleUpgradePopup()
                    } else {
                        state.toggleModelMenu()
                    }
                    return nil
                }
                // Mic icon — open/close the device dropdown.
                if !anyMenuOpen, let micFrame, micFrame.contains(point) {
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
                // Upgrade popup open (trial model-lock) — a click on the Upgrade
                // button opens the voluntary-upgrade paywall; anywhere else
                // dismisses. The click is always consumed so it never starts a
                // new drag.
                if state.isUpgradePopupOpen {
                    if let rect = selectionRect {
                        let buttonFrame = AreaSelectorView.upgradeButtonFrame(
                            forSelection: rect, in: size, fullScreen: fullScreen, devMode: devMode
                        )
                        if buttonFrame.contains(point) {
                            self?.openUpgradePaywall()
                            state.closeUpgradePopup()
                            return nil
                        }
                    }
                    state.closeUpgradePopup()
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
                // Dev-settings menu open. Compact accordion: a section's SUMMARY row
                // toggles that section open/closed; an OPTION row (only present while
                // its section is expanded) selects + collapses back. The Project rows
                // toggle Auto-Detect / open the folder picker. A click elsewhere
                // dismisses. The menu stays open after a row action so setup can
                // continue.
                if state.isDevSettingsMenuOpen {
                    if let rect = selectionRect {
                        let agentCount = state.devAgentMenuItems.count
                        let modelCount = state.devModelMenuItems.count
                        let expanded = state.expandedDevSection

                        func summary(_ section: AreaSelectorState.DevMenuSection) -> CGRect {
                            AreaSelectorView.devSettingsSummaryRowFrame(
                                section, forSelection: rect, in: size,
                                agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
                        }

                        // Agent: summary toggles; option selects + collapses.
                        if summary(.agent).contains(point) {
                            state.toggleDevSection(.agent); return nil
                        }
                        if let idx = AreaSelectorView.devSettingsAgentRowIndex(
                            at: point, forSelection: rect, in: size,
                            agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                        ) {
                            self?.selectDevAgent(at: idx, state: state)
                            state.collapseDevSections()
                            return nil
                        }
                        // Model.
                        if summary(.model).contains(point) {
                            state.toggleDevSection(.model); return nil
                        }
                        if let idx = AreaSelectorView.devSettingsModelRowIndex(
                            at: point, forSelection: rect, in: size,
                            agentCount: agentCount, modelCount: modelCount,
                            scrollOffset: state.devModelScrollOffset, expanded: expanded, fullScreen: fullScreen
                        ) {
                            self?.selectDevModel(at: idx, state: state)
                            state.collapseDevSections()
                            return nil
                        }
                        // Permissions.
                        if summary(.permissions).contains(point) {
                            state.toggleDevSection(.permissions); return nil
                        }
                        if let idx = AreaSelectorView.devSettingsPermissionRowIndex(
                            at: point, forSelection: rect, in: size,
                            agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                        ) {
                            self?.selectDevPermission(at: idx, state: state)
                            state.collapseDevSections()
                            return nil
                        }
                        // Auto-Detect Project toggle row (Project section, above
                        // "Change…") — clicking anywhere on it flips the opt-in.
                        let autoDetectRow = AreaSelectorView.devSettingsAutoDetectRowFrame(
                            forSelection: rect, in: size, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
                        )
                        if autoDetectRow.contains(point) {
                            self?.toggleAutoDetectProject(state: state)
                            return nil
                        }
                        let projectRow = AreaSelectorView.devSettingsProjectRowFrame(
                            forSelection: rect, in: size, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen
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
                // Defensive: the walkthrough block above consumes the
                // initiating press while the tour is active, so this is
                // unreachable then — the guard keeps a drag from ever
                // starting under the tour if that routing shifts.
                if state.toolbarWalkthroughStep == nil { state.beginDrag(at: point) }
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
                // While the walkthrough is active, ESC dismisses the TOUR —
                // not the overlay (which stays open, live for recording) —
                // and marks it seen so it doesn't re-offer next open.
                if state.toolbarWalkthroughStep != nil {
                    self?.dismissWalkthrough(state: state)
                    return nil
                }
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
                if state.isUpgradePopupOpen {
                    state.closeUpgradePopup()
                    return nil
                }
                if state.isDevSettingsMenuOpen {
                    // ESC first collapses an expanded accordion section, then (next
                    // press) closes the menu, then cancels the overlay.
                    if state.expandedDevSection != nil {
                        state.collapseDevSections()
                        return nil
                    }
                    state.closeDevSettingsMenu()
                    return nil
                }
                state.cancel()
                return nil
            case 49: // Space — select the whole display (one-way)
                // Swallowed during the walkthrough — no mode change under the tour.
                if state.toolbarWalkthroughStep != nil { return nil }
                self?.enterFullScreen(window: window, state: state)
                return nil
            case 36, 76: // Return, Enter (keypad)
                // Swallowed during the walkthrough — no record under the tour.
                if state.toolbarWalkthroughStep != nil { return nil }
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

    // MARK: - Toolbar walkthrough (first-run tour)
    //
    // The state machine (Phase 1) owns the step cursor and the Dev Mode
    // display borrow/restore; the controller owns exactly what the model
    // must not (its unit-testability contract): the seen-flag write and
    // analytics. Next/Back arrive from the mouse monitor above — the
    // callout's SwiftUI buttons are visual-only, hit-tested against the same
    // static frames they render at — and Esc from the key monitor.

    private func walkthroughNextTapped(state: AreaSelectorState) {
        state.advanceToolbarWalkthrough()
        if let step = state.toolbarWalkthroughStep {
            Analytics.capture("area_toolbar_walkthrough_step_viewed", ["step": step.analyticsName])
        } else {
            // Advancing past .record ("Got it") ended the tour as completed.
            finishToolbarWalkthrough(completed: true)
        }
    }

    private func walkthroughBackTapped(state: AreaSelectorState) {
        state.toolbarWalkthroughBack()
        if let step = state.toolbarWalkthroughStep {
            Analytics.capture("area_toolbar_walkthrough_step_viewed", ["step": step.analyticsName])
        }
    }

    /// Esc while the tour is active: end it early. The overlay stays open.
    private func dismissWalkthrough(state: AreaSelectorState) {
        state.endToolbarWalkthrough(completed: false)
        finishToolbarWalkthrough(completed: false)
    }

    /// Both endings mark the walkthrough seen — completed AND Esc-dismissed
    /// (per plan §6, a deliberate dismissal shouldn't re-run forever; only an
    /// interrupted open, which never reaches this, re-offers next time).
    private func finishToolbarWalkthrough(completed: Bool) {
        preferences?.toolbarWalkthroughSeen = true
        Analytics.capture(completed
            ? "area_toolbar_walkthrough_completed"
            : "area_toolbar_walkthrough_dismissed")
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
        // Phase 3: a Dev recording on a detected localhost port LEARNS the folder
        // for that port (pre-filled next time). No-op outside Dev Mode or when no
        // port was detected this session.
        if state.isDevMode { rememberLocalhostPortMapping(state: state) }
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
    private static let cursorInstallURL = URL(string: "https://docs.cursor.com/en/cli/overview")!

    private static func installURL(forAgent agentID: String) -> URL {
        switch agentID {
        case DevAgentRegistry.codexID:  return codexInstallURL
        case DevAgentRegistry.cursorID: return cursorInstallURL
        default:                        return claudeCodeInstallURL
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
            // Phase 3: try to auto-match the folder to the browser's localhost port.
            beginLocalhostFolderDetection(for: state)
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

    /// Act on a dev-settings menu Permissions row: persist the chosen tier and
    /// checkmark it. Row order matches `DevPermissionTier.allCases` (0 = Ask
    /// Permission, 1 = Auto-Approve, 2 = Unrestricted), the same order the view
    /// renders + the hit-test indexes. The menu stays open after the pick.
    private func selectDevPermission(at index: Int, state: AreaSelectorState) {
        let tiers = DevPermissionTier.allCases
        guard index >= 0, index < tiers.count else { return }
        let tier = tiers[index]
        preferences?.devPermissionTier = tier
        state.setDevPermissionTier(tier)
        Analytics.capture("dev_permission_tier_selected", ["tier": tier.rawValue])
    }

    /// Flip the dev-settings "Auto-Detect Project" toggle (Project section). The
    /// toggle IS the permission primer: on OFF→ON we fire one browser read so the
    /// Apple Event surfaces the macOS per-browser Automation prompt NOW — in the
    /// obvious context of the user having just asked for this — and pre-fill the
    /// folder if a mapped port comes back. Fire-and-forget: the toggle stays ON
    /// regardless of the grant outcome (a denial degrades to silent fallback, with
    /// the one-time explainer). On ON→OFF the browser is never read again (the gate
    /// in `beginLocalhostFolderDetection`) and any standing denial note is dropped.
    /// The live AppleScript path is covered by the E2E, not unit tests.
    private func toggleAutoDetectProject(state: AreaSelectorState) {
        let enabled = !(preferences?.devAutoDetectProject ?? false)
        preferences?.devAutoDetectProject = enabled
        state.setAutoDetectProjectEnabled(enabled)
        Analytics.capture("dev_auto_detect_project_toggled", ["enabled": enabled])
        if enabled {
            // beginLocalhostFolderDetection self-gates on the pref we just set, so
            // this triggers exactly one detection (prompt + immediate match attempt).
            beginLocalhostFolderDetection(for: state)
        } else {
            state.dismissLocalhostNotice()
        }
    }

    /// Scroll the dev-settings Model viewport from a scroll-wheel event. Returns
    /// true (→ the monitor consumes the event) only when the pointer is within the
    /// Model viewport AND the list is longer than the cap. Row-stepped to stay in
    /// lockstep with the geometry-based hit-testing: trackpad deltas accumulate
    /// against the row height; a mouse-wheel notch is one row. Sign follows
    /// `scrollingDeltaY` directly, which already reflects the user's natural-scroll
    /// setting (positive = content down = reveal earlier rows = offset decreases).
    private func handleDevModelScroll(
        event: NSEvent,
        at point: CGPoint,
        forSelection rect: CGRect,
        in size: CGSize,
        fullScreen: Bool,
        state: AreaSelectorState
    ) -> Bool {
        let modelCount = state.devModelMenuItems.count
        guard modelCount > AreaSelectorView.maxVisibleModelRows else { return false }   // nothing to scroll
        guard state.expandedDevSection == .model else { return false }                  // only scroll the open Model list
        let agentCount = state.devAgentMenuItems.count
        let viewport = AreaSelectorView.devSettingsModelViewportRect(
            forSelection: rect, in: size, agentCount: agentCount, modelCount: modelCount,
            expanded: state.expandedDevSection, fullScreen: fullScreen
        )
        guard viewport.contains(point) else { return false }

        let rowH = AreaSelectorView.devMenuRowHeight
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate points, step per row. Reset at gesture start so
            // a prior swipe's momentum doesn't carry into this one.
            if event.phase == .began { devModelScrollAccum = 0 }
            devModelScrollAccum += event.scrollingDeltaY
            while devModelScrollAccum >= rowH {
                devModelScrollAccum -= rowH
                state.setDevModelScrollOffset(state.devModelScrollOffset - 1)
            }
            while devModelScrollAccum <= -rowH {
                devModelScrollAccum += rowH
                state.setDevModelScrollOffset(state.devModelScrollOffset + 1)
            }
        } else {
            // Mouse wheel (line-based): one notch ≈ one row.
            devModelScrollAccum = 0
            if event.scrollingDeltaY > 0 {
                state.setDevModelScrollOffset(state.devModelScrollOffset - 1)
            } else if event.scrollingDeltaY < 0 {
                state.setDevModelScrollOffset(state.devModelScrollOffset + 1)
            }
        }
        // Re-evaluate the hover highlight at the now-scrolled position so it tracks
        // without needing a mouse move.
        state.setHighlightedDevModelIndex(AreaSelectorView.devSettingsModelRowIndex(
            at: point, forSelection: rect, in: size,
            agentCount: agentCount, modelCount: modelCount,
            scrollOffset: state.devModelScrollOffset, fullScreen: fullScreen
        ))
        return true
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

    /// Phase 3 — auto-match the project folder to the `localhost:<port>` in the
    /// user's browser. Opt-in (the toggle) + Dev-Mode-only + off-main + best-
    /// effort: any failure falls back to the last-used folder, and a failed
    /// detection NEVER clears an already-set folder. Kicked off on Dev entry,
    /// alongside agent detection + the git-repo check.
    private func beginLocalhostFolderDetection(for state: AreaSelectorState) {
        // Opt-in gate (default OFF): never read the browser unless the user enabled
        // the dev-settings "Auto-Detect Project" toggle. With it off, this is
        // byte-identical to pre-Phase-3 behavior.
        guard preferences?.devAutoDetectProject == true else { return }

        // Will a detection here surface the system Automation prompt (some running
        // browser's permission isn't determined yet)? Checked WITHOUT prompting.
        // (No pre-prompt primer: enabling the toggle IS the primer — the user just
        // asked for this, so the system dialog already has obvious context.)
        let willPrompt = BrowserURLReader.automationWouldPrompt()

        // The system TCC prompt is presented BELOW our `.screenSaver`-level overlay
        // → "Allow"/"Don't Allow" are unclickable (the user literally can't grant
        // it). So when a prompt is pending, drop the overlay to `.normal` for its
        // duration (mirroring `presentFolderPicker`) and give detection a longer
        // budget to await the user's response; restore the level the instant
        // detection resolves. Once permission is determined, future entries take
        // the silent short path and the overlay is never lowered.
        let savedLevel: NSWindow.Level?
        if willPrompt, let window {
            savedLevel = window.level
            window.level = .normal
        } else {
            savedLevel = nil
        }
        let timeout: TimeInterval = willPrompt ? 30 : 1.5

        Task { @MainActor [weak self, weak state] in
            let url = await BrowserURLReader.detectLocalhostURL(timeout: timeout)
            // Restore the overlay to its on-top level (it was lowered for the
            // prompt) and re-key it so ESC/Return keep working.
            if let savedLevel, let window = self?.window {
                window.level = savedLevel
                window.makeKeyAndOrderFront(nil)
            }
            guard let self, let state, state.isDevMode else { return }

            // LIVE port→folder resolution (off-main), consulted BEFORE the learned
            // cache so a stale `devProjectByPort` entry can self-correct: find the
            // process actually serving the detected port and derive its project
            // root. Only runs when an explicit localhost port is present (the
            // privacy boundary); fail-open to nil → the cache/last-used fallback.
            let port = url.flatMap { BrowserURLReader.portForLocalhostURL($0) }
            let liveFolder: URL?
            if let port {
                liveFolder = await LocalhostPortResolver.resolveProjectFolder(forPort: port)
            } else {
                liveFolder = nil
            }

            guard let preferences = self.preferences else { return }
            switch Self.applyLocalhostAutoMatch(
                url: url,
                liveFolderForPort: { $0 == port ? liveFolder : nil },
                state: state,
                preferences: preferences
            ) {
            case .autoFilled(let folder):
                // HIT (live or cached) → folder pre-filled + map/last-used
                // refreshed by the helper; verify the repo here (needs the
                // controller's async git probe).
                self.beginGitRepoCheck(for: folder, state: state)
            case .notedPort:
                // Port detected but unresolved → the helper remembered it so a
                // folder pick / record learns the mapping; folder left untouched.
                break
            case .noMatch:
                // Miss / no localhost tab / denied / timeout → keep the last-used
                // folder. If permission was actually DENIED, surface the one-time,
                // dismissible explainer (non-blocking) — never nag.
                if preferences.hasShownLocalhostDenialNote != true,
                   BrowserURLReader.automationDenied() {
                    preferences.hasShownLocalhostDenialNote = true
                    state.showLocalhostNotice(.denied)
                }
            }
        }
    }

    /// What an auto-match attempt resolved to, so the caller can run the
    /// follow-ups it owns (the async git-repo probe; the denial explainer).
    enum LocalhostAutoMatchOutcome: Equatable {
        /// A folder was filled (live hit or cache hit); `folder` is it.
        case autoFilled(folder: URL)
        /// A port was detected but no folder resolved; the port was remembered.
        case notedPort
        /// No localhost port at all (non-local URL, none, denied, timeout).
        case noMatch
    }

    /// The PURE, testable core of localhost auto-match: turn a (possibly nil)
    /// detected URL + a LIVE port→folder resolver into the state + preference
    /// mutations, with the learned `devProjectByPort` map as a fallback/cache.
    ///
    /// Resolution precedence per detected port: LIVE result (authoritative — the
    /// project genuinely serving the port) THEN the cached `devProjectByPort`
    /// entry. On a hit:
    ///   • pre-fill the folder + flag the hint (`setAutoMatchedProject`),
    ///   • remember it as the global last-used (`devProjectURL`) — so an
    ///     auto-matched folder seeds the next launch (previously only the manual
    ///     picker did this), and
    ///   • REFRESH the cache (`setProjectURL(forPort:)`) only when it disagrees —
    ///     so a live result that beat a stale cache entry teaches the map the
    ///     correct folder (and a pure cache hit writes nothing).
    /// A miss notes the port (so a later pick learns it) and NEVER clears a set
    /// folder. Lives here (not in `BrowserURLReader`) because it mutates app
    /// state/preferences; the live I/O is injected so tests never touch `lsof`.
    @MainActor
    @discardableResult
    static func applyLocalhostAutoMatch(
        url: String?,
        liveFolderForPort: (Int) -> URL?,
        state: AreaSelectorState,
        preferences: PreferencesStore
    ) -> LocalhostAutoMatchOutcome {
        // Live-first, then the learned cache.
        let folderForPort: (Int) -> URL? = { liveFolderForPort($0) ?? preferences.projectURL(forPort: $0) }
        switch BrowserURLReader.resolveFolder(forURL: url, folderForPort: folderForPort) {
        case .autoFill(let folder, let port):
            state.setAutoMatchedProject(folder, port: port)
            // Bug fix #1: an auto-matched folder is now remembered as last-used.
            preferences.devProjectURL = folder
            // Bug fix #2: refresh a stale/absent cache entry (guarded so a pure
            // cache hit — live agreed with the map — writes nothing).
            if preferences.projectURL(forPort: port) != folder {
                preferences.setProjectURL(folder, forPort: port)
            }
            return .autoFilled(folder: folder)
        case .notePort(let port):
            state.noteDetectedLocalhostPort(port)
            return .notedPort
        case .none:
            return .noMatch
        }
    }

    /// Learn `port → folder` for the localhost port detected this session (if any)
    /// — called when the user picks a folder via "Change…" or records. Keeps the
    /// global last-used (`devProjectURL`) in sync at its own call sites.
    private func rememberLocalhostPortMapping(state: AreaSelectorState) {
        guard let port = state.detectedLocalhostPort, let folder = state.projectURL else { return }
        preferences?.setProjectURL(folder, forPort: port)
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
        // Resolve the agent to pre-select, agent-agnostically (Codex/Cursor are
        // first-class now, not just Claude Code): the remembered pick if it's
        // installed, else the recommended default if installed, else ANY installed
        // agent (so a machine with only Cursor isn't blocked just because the
        // Claude-Code default is absent), else nil.
        let installed = entries.filter(\.installed)
        let resolved = installed.first { $0.id == preferences?.selectedAgentID }
            ?? installed.first { $0.id == DevAgentRegistry.recommendedID }
            ?? installed.first
        guard let resolved else {
            // Nothing usable installed: agent stays unset so validation blocks.
            // Keep the recommended agent's display name for the menu's install
            // affordance. No agent → no models.
            let fallbackName = entries.first { $0.id == DevAgentRegistry.recommendedID }?.displayName ?? "Claude Code"
            state.setSelectedAgent(id: nil, name: fallbackName)
            state.setDevModelMenuItems([], selectedID: nil)
            return
        }
        // Use the RESOLVED agent's own name (not always Claude Code) so the chip
        // label matches the selection — fixes a remembered Codex/Cursor pick
        // surfacing as "Claude Code".
        state.setSelectedAgent(id: resolved.id, name: resolved.displayName)
        // Persist the detected default ONLY when nothing was remembered — never
        // clobber a remembered-but-currently-uninstalled pick (the user may
        // reinstall it).
        if preferences?.selectedAgentID == nil {
            preferences?.selectedAgentID = resolved.id
        }
        // Seed the Model section for the resolved agent (Phase 2).
        refreshDevModelItems(forAgent: resolved.id, state: state)
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
            // Phase 3: if a localhost port was detected this session, LEARN this
            // folder for it (so the manual pick is remembered next time on that
            // port). The global last-used (`devProjectURL`) is updated above.
            rememberLocalhostPortMapping(state: state)
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
            // Re-capture `state` weakly in the main-actor hop: the inner closure
            // runs on a different executor than this detached task, so referencing
            // the task's `[weak state]` var directly is a cross-domain captured-var
            // race (an error in the Swift 6 language mode). Its own capture-list
            // entry is an immutable per-closure binding, so there's no shared var.
            await MainActor.run { [weak state] in
                guard let state, state.projectURL == url else { return }
                state.setProjectGitRepo(isRepo)
            }
        }
    }

    // MARK: - Trial model-lock upgrade

    /// Open the voluntary-upgrade paywall window from the trial model-lock
    /// upgrade popup (rather than jumping straight to the LemonSqueezy checkout).
    /// The paywall is where a trial user reviews plans and starts checkout, so
    /// the model-lock "Upgrade" button routes through the same surface as the
    /// menu-bar "Upgrade" row: set the `.voluntaryUpgrade` trigger (so the copy
    /// reads "Upgrade your plan") and present the window.
    private func openUpgradePaywall() {
        Log.billing.notice("model-lock: opening voluntary-upgrade paywall")
        Analytics.capture("paywall_opened", [
            "trigger": EntitlementStore.PaywallTrigger.voluntaryUpgrade.rawValue,
            "placement": "capture_toolbar"
        ])
        // Set the trigger on the shared EntitlementStore BEFORE teardown
        // (dismiss() nils `state`, but the store is long-lived so the
        // trigger persists for the paywall to read).
        state?.entitlements?.paywallTrigger = .voluntaryUpgrade
        // Tear down the .screenSaver-level overlay so it stops intercepting
        // mouse events / rendering above the paywall window. Without this,
        // the paywall opens BELOW the overlay and is un-clickable. The
        // overlay is rebuilt fresh on every present(), so dismissing is safe.
        dismiss()
        AppDelegate.openPaywall()
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
