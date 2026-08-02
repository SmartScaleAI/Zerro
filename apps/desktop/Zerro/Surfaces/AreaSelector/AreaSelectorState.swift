//
//  AreaSelectorState.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Per-session state container for the area-selector overlay. The
//  AreaSelectorWindowController constructs a fresh instance every
//  time it presents the overlay, wires the confirm/cancel callbacks,
//  and routes mouse + key events from the custom NSView through
//  mutating methods on this model.
//
//  Coordinate space: dragOrigin and dragCurrent are in view-local
//  points with TOP-LEFT origin (matching SwiftUI's space). The
//  custom NSView captures NSEvent locations in window coords
//  (bottom-left origin) and relies on `isFlipped = true` to convert
//  them into top-left when `convert(_:from: nil)` is called — so by
//  the time points reach this model, they already live in the
//  SwiftUI-friendly space. View-local → screen-global conversion
//  for the Phase 7 handoff happens in the window controller, not
//  here.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AreaSelectorState {
    /// Invoked when the user accepts a selection. Wired in
    /// Checkpoint 3 — defined now so the controller's present()
    /// signature is stable.
    var onConfirm: ((SelectionRect) -> Void)?

    /// Invoked when the user dismisses without selecting (ESC).
    var onCancel: (() -> Void)?

    // MARK: - Capture mode

    /// Which selection affordance is active. `.area` is the default
    /// drag-to-select region; `.fullScreen` selects the entire display
    /// the overlay is on. Space enters `.fullScreen` one-way; drawing a
    /// new drag rectangle returns to `.area`.
    enum Mode: Equatable {
        case area
        case fullScreen
    }

    private(set) var mode: Mode = .area

    /// Overlay bounds (view-local, top-left) in points, set by the
    /// controller at present time. Used to build the full-display
    /// `confirmableSelectionRect` in `.fullScreen` mode — the whole
    /// overlay covers exactly one display.
    private(set) var overlaySize: CGSize = .zero

    func setOverlaySize(_ size: CGSize) {
        overlaySize = size
    }

    // MARK: - Drag state

    /// Which part of an existing selection a press grabbed. Drives both the
    /// resize math and the hover cursor. Corners move two edges; edge
    /// midpoints move one.
    enum Handle: Equatable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// What the in-flight left-drag is doing. `.none` between gestures — the
    /// controller's dragged/up routing keys off this, so a press that was
    /// consumed by a toolbar control (neither `beginDrag` nor `beginEdit`
    /// ran) can never resize or move the settled selection.
    enum DragInteraction: Equatable {
        case none
        case creating                 // drawing a new rect (the original behavior)
        case resizing(Handle)         // dragging a handle of a settled rect
        case moving                   // dragging the interior of a settled rect
    }

    private(set) var interaction: DragInteraction = .none

    /// Anchor captured at grab time so a move is computed as a delta from the
    /// gesture start rather than the absolute cursor position (prevents the
    /// rect "jumping" so its origin snaps under the cursor on first move).
    private var dragAnchorRect: CGRect?      // selection rect at mouseDown
    private var dragAnchorPoint: CGPoint?    // cursor location at mouseDown

    /// View-local point (top-left origin) of the mouseDown that
    /// started the current selection. nil before any drag has
    /// started; persists after mouseUp so the rect remains rendered
    /// for confirm.
    private(set) var dragOrigin: CGPoint?

    /// View-local point (top-left origin) of the latest cursor
    /// position. nil before any drag has started; persists after
    /// mouseUp.
    private(set) var dragCurrent: CGPoint?

    /// True between mouseDown and mouseUp — for create, resize, and move
    /// gestures alike. Drives the 4-handle (during-drag) vs. 8-handle
    /// (settled) visual branch and nils `confirmableSelectionRect`, so the
    /// toolbar hides while actively adjusting exactly as it does during the
    /// initial draw.
    private(set) var isDragging: Bool = false

    /// The current selection in view-local, top-left coordinates,
    /// normalized so width and height are always non-negative.
    /// This is the only direction-normalization site — view and
    /// callers treat the rect as already valid.
    var selectionRect: CGRect? {
        guard let origin = dragOrigin, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
    }

    /// True in the area mode's initial resting state — before any drag has
    /// begun and with no walkthrough running. Drives the large centered
    /// instruction pill: it disappears the instant `beginDrag` sets a
    /// selection rect, and never shows in `.fullScreen` (that mode keeps
    /// its own small top prompt).
    var showsRestingInstructionPill: Bool {
        mode == .area && selectionRect == nil && toolbarWalkthroughStep == nil
    }

    // MARK: - Confirmable selection

    /// Minimum confirmable selection, in view-local points (per axis).
    /// Selections smaller than this are treated like a zero-size
    /// selection — confirm is a no-op. Rationale: a region this small
    /// carries almost no useful visual context for the model, and after
    /// retina backing-scale and H.264's even-dimension requirement, tiny
    /// regions risk a degenerate or zero-frame capture. 150pt sits well
    /// above any encoder floor while still allowing a "narrate one panel"
    /// selection. Shared by the controller's confirm gate and the view's
    /// Record-button visibility.
    static let minimumSelectionSize: CGFloat = 150

    /// The settled, confirmable selection in view-local (top-left)
    /// coordinates, or nil if there's nothing to confirm yet. Drives
    /// both the floating Record button's appearance and the controller's
    /// click hit-test:
    ///   • area: a finished drag (not in flight) meeting the min size.
    ///   • fullScreen: the whole overlay (== the whole display).
    var confirmableSelectionRect: CGRect? {
        switch mode {
        case .area:
            guard !isDragging, let rect = selectionRect,
                  rect.width >= Self.minimumSelectionSize,
                  rect.height >= Self.minimumSelectionSize else { return nil }
            return rect
        case .fullScreen:
            guard overlaySize.width > 0, overlaySize.height > 0 else { return nil }
            return CGRect(origin: .zero, size: overlaySize)
        }
    }

    /// True in `.area` mode when a SETTLED selection is below
    /// `minimumSelectionSize` on either axis — drawn but not large enough to
    /// record. Drives every red "too small" affordance (border, handles,
    /// readout, message). Deliberately quiet while `isDragging`: every drag
    /// STARTS undersized, so live-red would flash at the beginning of each
    /// selection — the error only appears once the user releases an
    /// undersized rect. The exact inverse of what makes
    /// `confirmableSelectionRect` non-nil in `.area` mode.
    var isSelectionTooSmall: Bool {
        guard mode == .area, !isDragging, let rect = selectionRect else { return false }
        return rect.width < Self.minimumSelectionSize || rect.height < Self.minimumSelectionSize
    }

    /// Monotonic counter bumped when Return/Enter is refused on an
    /// undersized selection. The view keys a brief icon bounce on the
    /// too-small message off changes, so the refusal reads as feedback
    /// rather than a silent no-op (the message itself is already standing —
    /// it follows `isSelectionTooSmall`).
    private(set) var undersizedConfirmPulse: Int = 0

    func noteUndersizedConfirmAttempt() {
        undersizedConfirmPulse += 1
    }

    /// Hover feedback for the floating Record button. The overlay's
    /// SwiftUI tree is hit-test-disabled (events flow through the
    /// controller's monitor), so the controller computes this by
    /// hit-testing the button frame on mouse-move and the view just
    /// reflects it.
    private(set) var isRecordButtonHovered: Bool = false

    func setRecordButtonHovered(_ hovered: Bool) {
        if isRecordButtonHovered != hovered { isRecordButtonHovered = hovered }
    }

    // MARK: - Dev Mode (Phase 1)
    //
    // Dev Mode is selected by its dedicated global shortcut. When active, the
    // recording is handed to a local coding agent
    // (Claude Code in Phase 1) that edits files in `projectURL`, instead of
    // the normal clipboard hand-off. This state holds the fixed launch mode +
    // the two Dev-Mode-critical selections (agent + folder); the controller owns
    // persistence (PreferencesStore) and the folder picker, mirroring how it
    // owns the agent/project picker. Everything here is inert in normal mode
    // (`isDevMode == false`), so non-Dev recordings behave exactly as today.

    /// Whether the Dev shortcut opened this recording flow. Dev Mode adds the
    /// consolidated agent/project settings control to the toolbar.
    private(set) var isDevMode: Bool = false

    /// The coding agent this recording will dispatch to (registry wire id,
    /// e.g. "claude-code"). nil when no agent is installed/selected — which
    /// blocks the Record action (see `devRequirementsMet`). Phase 1 ships a
    /// single agent; the chip is a confirmation, not a picker.
    private(set) var selectedAgentID: String?

    /// Display label for the agent chip. Phase 1 hard-shows "Claude Code";
    /// Milestone 2 sources this from `DevAgentRegistry`.
    private(set) var selectedAgentName: String = "Claude Code"

    /// The project folder the agent runs in (`cwd`). nil until the user picks
    /// one; an unset folder shows the chip's amber/dashed attention state and
    /// blocks the Record action.
    private(set) var projectURL: URL?

    /// Folder chip label: the project directory's name, or nil when unset
    /// (the view renders the "Select folder" attention state).
    var projectDisplayName: String? {
        projectURL?.lastPathComponent
    }

    /// Transient, inline "you can't record yet" message set by the
    /// record-time validation gate (e.g. no folder picked). Cleared once the
    /// blocking condition is resolved. Never persisted.
    private(set) var devValidationMessage: String?

    /// Whether the Record action may proceed in Dev Mode: both an agent and a
    /// project folder must be chosen. Always true in normal mode.
    var devRequirementsMet: Bool {
        !isDevMode || (selectedAgentID != nil && projectURL != nil)
    }

    /// At-a-glance readiness for the compact dev-settings icon's status dot:
    /// green when an agent is installed/selected AND a folder is set, amber when
    /// either is missing. Distinct from `devRequirementsMet` only in framing —
    /// this drives the dot; the record gate drives blocking. Meaningful only in
    /// Dev Mode (the dot renders only then).
    var isDevReady: Bool {
        selectedAgentID != nil && projectURL != nil
    }

    // MARK: - Dev-settings menu (compact toolbar)
    //
    // The compact toolbar collapses the agent + folder chips into ONE
    // dev-settings icon whose dropdown lists the detected agents and the
    // project folder. Rendered in-tree like the model/mic dropdowns (the
    // overlay sits at `.screenSaver`, above NSMenu's window level), so the
    // controller's mouse monitor hit-tests its rows the same way.

    /// One row of the dev-settings menu's Agent section — display data the
    /// controller precomputes from `DevAgentDetection` at present time (the view
    /// stays free of registry/PATH reads). `installed` drives the "Detected"
    /// badge vs. the dim "Install" hint.
    struct DevAgentMenuItem: Identifiable, Equatable {
        /// `DevAgentEntry.id` (e.g. "claude-code").
        let id: String
        /// `DevAgentEntry.displayName`.
        let name: String
        /// Whether the CLI resolved on PATH this launch.
        let installed: Bool
    }

    /// Agent rows for the dev-settings menu, set by the controller once detection
    /// lands. Empty until then (Phase 1 ships one agent — Claude Code).
    private(set) var devAgentMenuItems: [DevAgentMenuItem] = []

    func setDevAgentMenuItems(_ items: [DevAgentMenuItem]) {
        devAgentMenuItems = items
    }

    private(set) var isDevSettingsMenuOpen: Bool = false

    /// Row under the cursor while the dev-settings menu is open (hover highlight).
    /// Indexes the menu's Agent rows; nil when nothing/elsewhere is hovered.
    private(set) var highlightedDevAgentIndex: Int?

    /// One-shot guard: the dev-settings menu auto-opens on the FIRST Dev entry
    /// this session (or whenever the folder is unset) so setup is discoverable,
    /// then stays closed on subsequent entries. Reset per overlay presentation
    /// (a fresh `AreaSelectorState` is built each time).
    private var hasAutoOpenedDevSettings: Bool = false

    func toggleDevSettingsMenu() {
        isDevSettingsMenuOpen.toggle()
        if isDevSettingsMenuOpen {
            // Compact by default: all three sections (Agent / Model / Permissions)
            // start collapsed to summary rows.
            expandedDevSection = nil
            // Open on the selected model so a deep pick isn't hidden.
            resetDevModelScrollToSelection()
        } else {
            clearDevMenuTransientState()
        }
    }

    func closeDevSettingsMenu() {
        isDevSettingsMenuOpen = false
        clearDevMenuTransientState()
    }

    /// Reset the dev-menu's transient hover / highlight / expansion state.
    private func clearDevMenuTransientState() {
        highlightedDevAgentIndex = nil
        highlightedDevModelIndex = nil
        highlightedDevPermissionIndex = nil
        isAutoDetectInfoHovered = false
        isPermissionSafetyHovered = false
        hoveredPermissionOptionSafety = nil
        hoveredDevSummary = nil
        expandedDevSection = nil
        localhostNotice = nil
    }

    func setHighlightedDevAgentIndex(_ index: Int?) {
        if highlightedDevAgentIndex != index { highlightedDevAgentIndex = index }
    }

    // MARK: - Permissions section

    /// The checkmarked permission tier in the Permissions section — mirrors
    /// `PreferencesStore.devPermissionTier`. Seeded from prefs when the overlay is
    /// built; updated when a Permissions row is selected.
    private(set) var devPermissionTier: DevPermissionTier = .askPermission

    func setDevPermissionTier(_ tier: DevPermissionTier) {
        if devPermissionTier != tier { devPermissionTier = tier }
    }

    /// Row under the cursor while the Permissions section is hovered; nil otherwise.
    private(set) var highlightedDevPermissionIndex: Int?

    func setHighlightedDevPermissionIndex(_ index: Int?) {
        if highlightedDevPermissionIndex != index { highlightedDevPermissionIndex = index }
    }

    // MARK: - Model section (Phase 2)

    /// One row in the dev-settings Model section. Mirrors `DevAgentMenuItem`.
    struct DevModelMenuItem: Identifiable, Equatable {
        /// The exact `--model` id (e.g. "claude-opus-4-8").
        let id: String
        /// The menu label (e.g. "Claude Opus 4.8").
        let name: String
    }

    /// Model rows for the dev-settings Model section, set by the controller for
    /// the CURRENTLY-SELECTED agent (anthropic/openai manifest, or the Cursor
    /// CLI). Ordered newest-first; empty for an agent with no model picker.
    private(set) var devModelMenuItems: [DevModelMenuItem] = []

    /// The model_id checkmarked in the Model section — the resolved pick for the
    /// selected agent (remembered, else newest/rank-0). nil when no models.
    private(set) var selectedDevModelID: String?

    /// Row under the cursor while the Model section is hovered; nil otherwise.
    private(set) var highlightedDevModelIndex: Int?

    /// Replace the Model section's rows + checkmarked pick. Called by the
    /// controller whenever the selected agent changes (the list is per-agent).
    func setDevModelMenuItems(_ items: [DevModelMenuItem], selectedID: String?) {
        devModelMenuItems = items
        selectedDevModelID = selectedID
        // The list just swapped (agent change) or refreshed — drop a now-stale
        // scroll offset and reveal the selected pick.
        resetDevModelScrollToSelection()
    }

    /// Update only the checkmarked pick (a Model row was selected).
    func setSelectedDevModelID(_ id: String?) {
        if selectedDevModelID != id { selectedDevModelID = id }
    }

    func setHighlightedDevModelIndex(_ index: Int?) {
        if highlightedDevModelIndex != index { highlightedDevModelIndex = index }
    }

    /// Index of the TOP visible Model row — the scroll position of the capped
    /// Model viewport (a long list, e.g. Cursor's, scrolls instead of growing the
    /// menu off-screen). Always 0 for a short list (≤ `maxVisibleModelRows`).
    /// Driven by the scroll-wheel via the controller's event monitor; read by the
    /// renderer and the model-row hit-test, which must agree on it.
    private(set) var devModelScrollOffset: Int = 0

    /// Largest valid offset for the current list — pins the last page flush to the
    /// viewport bottom. 0 when the list fits (no scrolling).
    private var maxDevModelScrollOffset: Int {
        max(0, devModelMenuItems.count - AreaSelectorView.maxVisibleModelRows)
    }

    /// Set the Model scroll offset, clamped to `0...maxDevModelScrollOffset`.
    func setDevModelScrollOffset(_ offset: Int) {
        let clamped = min(max(offset, 0), maxDevModelScrollOffset)
        if devModelScrollOffset != clamped { devModelScrollOffset = clamped }
    }

    /// Position the viewport so the currently-selected model is visible — called
    /// when the menu opens or the model list swaps (agent change), so a deep pick
    /// isn't hidden on open and a stale offset from the previous list is dropped.
    /// Clamps the selected index to the top of the viewport; falls back to 0.
    func resetDevModelScrollToSelection() {
        guard devModelMenuItems.count > AreaSelectorView.maxVisibleModelRows,
              let selectedDevModelID,
              let idx = devModelMenuItems.firstIndex(where: { $0.id == selectedDevModelID })
        else { devModelScrollOffset = 0; return }
        devModelScrollOffset = min(idx, maxDevModelScrollOffset)
    }

    /// Called when a Dev shortcut presents the overlay. Auto-opens the
    /// dev-settings menu the first time this overlay presentation, or any time
    /// the folder is still unset, so the user can finish
    /// setup; otherwise leaves it closed.
    func handleDevModeEntered() {
        if !hasAutoOpenedDevSettings || projectURL == nil {
            isDevSettingsMenuOpen = true
            resetDevModelScrollToSelection()
        }
        hasAutoOpenedDevSettings = true
    }

    /// True while agent detection is in flight (the login-shell PATH probe runs
    /// off the main thread). The agent chip shows a neutral "checking" state
    /// rather than the install attention state until it resolves.
    private(set) var isDetectingAgent: Bool = false

    func setDetectingAgent(_ detecting: Bool) {
        if isDetectingAgent != detecting { isDetectingAgent = detecting }
    }

    /// In Dev Mode with detection finished and no usable agent (Phase 1: Claude
    /// Code not installed). Drives the agent chip's attention state + the
    /// install-hint validation message. Always false in normal mode and while
    /// detection is still running.
    var isAgentMissing: Bool {
        isDevMode && !isDetectingAgent && selectedAgentID == nil
    }

    /// Git-repo status of the picked `projectURL` (Milestone 7): nil while
    /// unknown/checking, true/false once the async `git rev-parse` lands. Dev
    /// Mode requires a git repo for its checkpoint/revert safety net, so a
    /// non-repo folder is surfaced as a NON-BLOCKING attention state on the
    /// folder chip — the user learns before recording, not at the checkpoint
    /// gate. The controller owns the probe (mirrors agent detection).
    private(set) var projectIsGitRepo: Bool?

    /// True while the git-repo probe for the current folder is in flight.
    private(set) var isCheckingGitRepo: Bool = false

    /// Folder picked but confirmed NOT inside a git work tree. Drives the folder
    /// chip's "not a git repo" attention note. False while unknown/checking and
    /// in normal mode.
    var isProjectNotGitRepo: Bool {
        isDevMode && projectURL != nil && projectIsGitRepo == false
    }

    func setCheckingGitRepo(_ checking: Bool) {
        if isCheckingGitRepo != checking { isCheckingGitRepo = checking }
    }

    /// Apply the async git-repo probe result for the current folder.
    func setProjectGitRepo(_ isRepo: Bool) {
        isCheckingGitRepo = false
        projectIsGitRepo = isRepo
    }

    /// Hover state for the Dev-settings icon. The controller hit-tests its frame
    /// on mouse-move and the view reflects the highlight + tooltip.
    private(set) var isDevSettingsHovered: Bool = false

    func setDevSettingsHovered(_ hovered: Bool) {
        if isDevSettingsHovered != hovered { isDevSettingsHovered = hovered }
    }

    /// Seed the Dev Mode selections at presentation time from persisted prefs
    /// and agent detection.
    func setDevState(isDevMode: Bool, agentID: String?, agentName: String, projectURL: URL?) {
        self.isDevMode = isDevMode
        self.selectedAgentID = agentID
        self.selectedAgentName = agentName
        self.projectURL = projectURL
    }

    func setProjectURL(_ url: URL?) {
        projectURL = url
        // A new folder invalidates the prior git-repo verdict; the controller
        // kicks off a fresh probe.
        projectIsGitRepo = nil
        isCheckingGitRepo = false
        if url != nil { devValidationMessage = nil }
        // Any explicit set means the folder is the user's pick, not an auto-match
        // — drop the hint flag (the auto path re-sets it afterward). And a folder
        // choice dismisses any standing localhost notice.
        projectAutoMatchedFromPort = false
        localhostNotice = nil
    }

    func setSelectedAgent(id: String?, name: String) {
        selectedAgentID = id
        selectedAgentName = name
    }

    // MARK: - Localhost auto-match (Phase 3)

    /// The localhost port detected from the browser this session (hit OR miss), so
    /// a subsequent folder pick / record can LEARN the `port → folder` mapping.
    /// nil when nothing was detected. Per-presentation (a fresh state each open).
    private(set) var detectedLocalhostPort: Int?

    /// Whether the CURRENT folder was auto-filled from a port-map hit — drives the
    /// "matched to localhost:<port>" hint near the Project row. Cleared the moment
    /// the user changes the folder (it's then their pick, not auto).
    private(set) var projectAutoMatchedFromPort: Bool = false

    /// Mirrors `PreferencesStore.devAutoDetectProject` for the dev-settings menu's
    /// "Auto-Detect Project" toggle row. Seeded + persisted by the controller (like
    /// the mic selection); drives the row's switch. Default OFF.
    private(set) var autoDetectProjectEnabled: Bool = false

    func setAutoDetectProjectEnabled(_ on: Bool) {
        if autoDetectProjectEnabled != on { autoDetectProjectEnabled = on }
    }

    /// Hover state for the Auto-Detect row's info icon, driving the custom tooltip
    /// (the overlay is hit-test-disabled, so `.help` never fires). Set by the
    /// controller's mouse-move hit-test; cleared when the dev-settings menu closes.
    private(set) var isAutoDetectInfoHovered: Bool = false

    func setAutoDetectInfoHovered(_ hovered: Bool) {
        if isAutoDetectInfoHovered != hovered { isAutoDetectInfoHovered = hovered }
    }

    /// Hover state for the Permissions SUMMARY row's safety icon (git-shield / ⚠),
    /// driving its custom tooltip (the overlay is hit-test-disabled, so `.help`
    /// never fires). Set by the controller's mouse-move hit-test; cleared when the
    /// menu closes. Does NOT affect the row's open/close click.
    private(set) var isPermissionSafetyHovered: Bool = false

    func setPermissionSafetyHovered(_ hovered: Bool) {
        if isPermissionSafetyHovered != hovered { isPermissionSafetyHovered = hovered }
    }

    /// Which EXPANDED permission option row's safety icon is hovered (0 = Ask
    /// Permission … 2 = Unrestricted), or nil. Drives that option's custom tooltip;
    /// hover-only, never affects selection. Cleared when the menu closes.
    private(set) var hoveredPermissionOptionSafety: Int? = nil

    func setHoveredPermissionOptionSafety(_ index: Int?) {
        if hoveredPermissionOptionSafety != index { hoveredPermissionOptionSafety = index }
    }

    // MARK: Dev-settings accordion (compact summary rows)

    /// The three collapsible dev-settings sections. Each renders as a single
    /// summary row showing the current selection; clicking it expands that
    /// section's full option list (one open at a time).
    enum DevMenuSection: Equatable, Sendable { case agent, model, permissions }

    /// Which dev-settings section is currently expanded, or nil when all three are
    /// collapsed to summary rows (the default). Drives both the renderer and the
    /// hit-test geometry, so it MUST be passed to the layout helpers.
    private(set) var expandedDevSection: DevMenuSection? = nil

    /// Toggle a section's expansion (collapsing any other). Expanding Model resets
    /// its scroll to the current selection so a deep pick isn't hidden.
    func toggleDevSection(_ section: DevMenuSection) {
        if expandedDevSection == section {
            expandedDevSection = nil
        } else {
            expandedDevSection = section
            // A freshly expanded section's option hover starts clear.
            highlightedDevAgentIndex = nil
            highlightedDevModelIndex = nil
            highlightedDevPermissionIndex = nil
            if section == .model { resetDevModelScrollToSelection() }
        }
    }

    /// Collapse all sections back to summary rows (e.g. ESC while a section is open).
    func collapseDevSections() {
        if expandedDevSection != nil { expandedDevSection = nil }
    }

    /// Which summary row is hovered (for its highlight), or nil. Purely cosmetic.
    private(set) var hoveredDevSummary: DevMenuSection? = nil

    func setHoveredDevSummary(_ section: DevMenuSection?) {
        if hoveredDevSummary != section { hoveredDevSummary = section }
    }

    /// A one-time, non-blocking `.denied` note (after the user denies the
    /// Automation prompt): a floating capsule, not part of the menu's hit-test
    /// geometry, cleared on the next action. The old `.primer` pre-prompt note is
    /// gone — enabling the dev-settings "Auto-Detect Project" toggle is now the
    /// primer (the prompt fires with obvious context, so no pre-explainer is owed).
    enum LocalhostNotice: Equatable { case denied }
    private(set) var localhostNotice: LocalhostNotice?

    func showLocalhostNotice(_ notice: LocalhostNotice) {
        if localhostNotice != notice { localhostNotice = notice }
    }

    func dismissLocalhostNotice() {
        if localhostNotice != nil { localhostNotice = nil }
    }

    /// HIT — a mapped folder was found for the detected port: pre-fill it and flag
    /// it for the hint. (Goes through `setProjectURL`, then sets the auto flag.)
    func setAutoMatchedProject(_ url: URL, port: Int) {
        setProjectURL(url)
        detectedLocalhostPort = port
        projectAutoMatchedFromPort = true
    }

    /// MISS — a localhost port was detected but isn't mapped yet: remember the
    /// port so a later folder pick / record learns the mapping. Does NOT touch the
    /// already-set (last-used) folder — a failed detection never clears a folder.
    func noteDetectedLocalhostPort(_ port: Int) {
        if detectedLocalhostPort != port { detectedLocalhostPort = port }
    }

    func setDevValidationMessage(_ message: String?) {
        devValidationMessage = message
    }

    // MARK: - Toolbar walkthrough (first-run coach-marks — state machine)
    //
    // First-run tour of the controls available in the shortcut-selected mode.
    // This model owns only the step cursor; rendering, Back/Next
    // hit-testing, the seen-flag write, and analytics are controller/view
    // work in later phases. Deliberately free of preference writes and
    // analytics calls so the machine stays unit-testable in isolation.

    /// The active walkthrough step, or nil when the walkthrough is inactive.
    /// Observable so the scrim/callout layers (later phases) react to step
    /// changes the same way they react to hover flags.
    private(set) var toolbarWalkthroughStep: ToolbarWalkthroughStep? = nil

    private var toolbarWalkthroughSteps: [ToolbarWalkthroughStep] {
        ToolbarWalkthroughStep.steps(isDevMode: isDevMode)
    }

    var toolbarWalkthroughPosition: Int? {
        guard let step = toolbarWalkthroughStep else { return nil }
        return toolbarWalkthroughSteps.firstIndex(of: step)
    }

    var toolbarWalkthroughCount: Int { toolbarWalkthroughSteps.count }

    /// Begin the walkthrough at the first control for this fixed mode.
    func startToolbarWalkthrough() {
        toolbarWalkthroughStep = toolbarWalkthroughSteps.first
    }

    /// Advance one step ("Next"). From the last step ("Got it") this ends
    /// the walkthrough as completed.
    func advanceToolbarWalkthrough() {
        guard let step = toolbarWalkthroughStep else { return }
        guard let index = toolbarWalkthroughSteps.firstIndex(of: step) else { return }
        let nextIndex = index + 1
        if toolbarWalkthroughSteps.indices.contains(nextIndex) {
            toolbarWalkthroughStep = toolbarWalkthroughSteps[nextIndex]
        } else {
            endToolbarWalkthrough(completed: true)
        }
    }

    /// Step back one ("Back" — hidden on the first step).
    func toolbarWalkthroughBack() {
        guard let step = toolbarWalkthroughStep,
              let index = toolbarWalkthroughSteps.firstIndex(of: step), index > 0
        else { return }
        toolbarWalkthroughStep = toolbarWalkthroughSteps[index - 1]
    }

    /// End the walkthrough. `completed` distinguishes "Got it" from Esc for
    /// analytics; both clear the cursor identically.
    func endToolbarWalkthrough(completed: Bool) {
        toolbarWalkthroughStep = nil
    }

    // MARK: - Mutations driven by AreaSelectorEventView

    func beginDrag(at point: CGPoint) {
        // Starting a drag supersedes a prior full-screen selection: drawing
        // a rectangle returns to a normal area selection (Space is one-way
        // into full-screen, but a fresh drag drops back out).
        mode = .area
        dragOrigin = point
        dragCurrent = point
        isDragging = true
        interaction = .creating
    }

    func updateDrag(to point: CGPoint) {
        dragCurrent = point
    }

    func endDrag(at point: CGPoint) {
        dragCurrent = point
        isDragging = false
        interaction = .none
    }

    // MARK: - Editing a settled selection (resize / move)

    /// Begin editing an existing, settled selection. Normalizes the stored
    /// points so dragOrigin == top-left and dragCurrent == bottom-right,
    /// which lets the resize math touch exactly one coordinate per moved
    /// edge. No-op without a selection or for a non-edit `kind` — only the
    /// controller's handle/interior hit-test calls this, always with
    /// `.resizing` or `.moving`.
    func beginEdit(_ kind: DragInteraction, at point: CGPoint) {
        guard let rect = selectionRect else { return }
        switch kind {
        case .resizing, .moving: break
        case .none, .creating: return
        }
        dragOrigin = CGPoint(x: rect.minX, y: rect.minY)  // top-left
        dragCurrent = CGPoint(x: rect.maxX, y: rect.maxY) // bottom-right
        dragAnchorRect = rect
        dragAnchorPoint = point
        interaction = kind
        isDragging = true   // hide the toolbar while adjusting, like a create drag
        mode = .area        // editing is only meaningful in area mode
    }

    /// Drag the grabbed handle to `point`, updating only the coordinate(s)
    /// that handle owns. Each axis PINS at `minimumSelectionSize` rather
    /// than flipping through the opposite edge — a deliberate edge drag
    /// "sticks" at the floor, so the region never drops below the
    /// confirmable minimum mid-resize.
    func updateResize(to point: CGPoint) {
        guard case .resizing(let handle) = interaction,
              var origin = dragOrigin, var current = dragCurrent else { return }
        let minSize = Self.minimumSelectionSize
        // origin = top-left, current = bottom-right (beginEdit normalized).
        switch handle {
        case .left, .topLeft, .bottomLeft:
            origin.x = min(point.x, current.x - minSize)
        case .right, .topRight, .bottomRight:
            current.x = max(point.x, origin.x + minSize)
        default:
            break
        }
        switch handle {
        case .top, .topLeft, .topRight:
            origin.y = min(point.y, current.y - minSize)
        case .bottom, .bottomLeft, .bottomRight:
            current.y = max(point.y, origin.y + minSize)
        default:
            break
        }
        dragOrigin = origin
        dragCurrent = current
    }

    /// Translate the whole selection by the delta from the grab point,
    /// clamped inside the overlay bounds so the region can't be shoved
    /// off-screen. Size never changes.
    func updateMove(to point: CGPoint) {
        guard interaction == .moving,
              let anchorRect = dragAnchorRect, let anchorPoint = dragAnchorPoint else { return }
        var rect = anchorRect.offsetBy(
            dx: point.x - anchorPoint.x,
            dy: point.y - anchorPoint.y
        )
        let maxX = max(0, overlaySize.width - rect.width)
        let maxY = max(0, overlaySize.height - rect.height)
        rect.origin.x = min(max(0, rect.origin.x), maxX)
        rect.origin.y = min(max(0, rect.origin.y), maxY)
        dragOrigin = CGPoint(x: rect.minX, y: rect.minY)
        dragCurrent = CGPoint(x: rect.maxX, y: rect.maxY)
    }

    /// End a resize/move gesture: the selection settles and the toolbar
    /// (via `confirmableSelectionRect`) reappears, exactly as after an
    /// initial draw.
    func endEdit() {
        isDragging = false
        interaction = .none
        dragAnchorRect = nil
        dragAnchorPoint = nil
    }

    // MARK: - Full-screen mode

    /// Switch into full-screen mode (Space). Selects the entire display
    /// the overlay is on. One-way: there is no Space toggle back — the
    /// user draws a new drag rectangle (see `beginDrag`) to return to an
    /// area selection. Clears any in-flight drag so a half-drawn rect
    /// doesn't bleed through. `overlaySize` is the overlay's view-local
    /// bounds, supplied by the controller, used to build the full-display
    /// `confirmableSelectionRect`.
    func enterFullScreenMode(overlaySize: CGSize) {
        mode = .fullScreen
        self.overlaySize = overlaySize
        dragOrigin = nil
        dragCurrent = nil
        isDragging = false
        interaction = .none
        dragAnchorRect = nil
        dragAnchorPoint = nil
        isRecordButtonHovered = false
    }

    // MARK: - Confirm / cancel

    func cancel() {
        onCancel?()
    }

    func confirm(with rect: SelectionRect) {
        onConfirm?(rect)
    }
}

// MARK: - Toolbar walkthrough steps

/// Stops used by the mode-specific first-run toolbar walkthrough.
enum ToolbarWalkthroughStep: Int, CaseIterable {
    case agent = 0
    case record

    static func steps(isDevMode: Bool) -> [ToolbarWalkthroughStep] {
        isDevMode ? [.agent, .record] : [.record]
    }

    /// Stable identifier for analytics — decoupled from `rawValue` (an index
    /// that shifts if steps are reordered/inserted), so it must stay constant
    /// across releases (mirrors `OnboardingStep.analyticsName`).
    var analyticsName: String {
        switch self {
        case .agent:  return "agent"
        case .record: return "record"
        }
    }

    /// Callout headline.
    var title: String {
        switch self {
        case .agent:  return "Set up your coding agent"
        case .record: return "Start recording"
        }
    }

    /// Callout body copy.
    var body: String {
        switch self {
        case .agent:
            return "In Dev Mode, choose which agent runs and which project folder it edits."
        case .record:
            return "Press this (or Return) to begin. You get up to 3 minutes."
        }
    }

    /// Whether the control exists only in the Dev toolbar. Drives the
    /// "Dev Mode only" callout badge.
    var isDevModeOnly: Bool {
        switch self {
        case .agent:  return true
        case .record: return false
        }
    }
}
