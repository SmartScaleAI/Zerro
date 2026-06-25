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

    /// View-local point (top-left origin) of the mouseDown that
    /// started the current selection. nil before any drag has
    /// started; persists after mouseUp so the rect remains rendered
    /// for confirm.
    private(set) var dragOrigin: CGPoint?

    /// View-local point (top-left origin) of the latest cursor
    /// position. nil before any drag has started; persists after
    /// mouseUp.
    private(set) var dragCurrent: CGPoint?

    /// True between mouseDown and mouseUp. Drives the 4-handle
    /// (during-drag) vs. 8-handle (settled) visual branch — the
    /// 8-handle settled branch arrives in Checkpoint 3.
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

    // MARK: - Confirmable selection

    /// Minimum confirmable selection, in view-local points (per axis).
    /// Selections smaller than this are treated like a zero-size
    /// selection — confirm is a no-op. Rationale: a sub-100pt region
    /// carries almost no useful visual context for the model, and after
    /// retina backing-scale and H.264's even-dimension requirement, tiny
    /// regions risk a degenerate or zero-frame capture. 100pt sits above
    /// any encoder floor while still allowing a "narrate one panel"
    /// selection. Shared by the controller's confirm gate and the view's
    /// Record-button visibility.
    static let minimumSelectionSize: CGFloat = 100

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

    /// Hover feedback for the floating Record button. The overlay's
    /// SwiftUI tree is hit-test-disabled (events flow through the
    /// controller's monitor), so the controller computes this by
    /// hit-testing the button frame on mouse-move and the view just
    /// reflects it.
    private(set) var isRecordButtonHovered: Bool = false

    func setRecordButtonHovered(_ hovered: Bool) {
        if isRecordButtonHovered != hovered { isRecordButtonHovered = hovered }
    }

    // MARK: - Microphone selection
    //
    // The overlay toolbar carries a mic picker so the input device can
    // be chosen right before recording without opening Settings. The
    // controller owns enumeration (AVCaptureDevice) and persistence
    // (PreferencesStore); this model just holds the display list +
    // current selection so the view can render the chip, and the
    // controller pops an NSMenu on click.

    /// A selectable audio input. `id` is the `AVCaptureDevice.uniqueID`
    /// (empty string is the "System Default" sentinel, matching
    /// PreferencesStore.microphoneDeviceID).
    struct AudioInputDevice: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Connected input devices, set by the controller at present time.
    private(set) var microphones: [AudioInputDevice] = []

    /// Currently selected device id ("" = System Default). Mirrors the
    /// persisted preference; the controller keeps the two in sync.
    private(set) var selectedMicrophoneID: String = ""

    /// Label for the toolbar chip: the selected device's name, or
    /// "System Default" when the selection is empty or no longer resolves
    /// to a connected device.
    var selectedMicrophoneName: String {
        if let match = microphones.first(where: { $0.id == selectedMicrophoneID }) {
            return match.name
        }
        return "System Default"
    }

    private(set) var isMicChipHovered: Bool = false

    func setMicChipHovered(_ hovered: Bool) {
        if isMicChipHovered != hovered { isMicChipHovered = hovered }
    }

    func setMicrophones(_ devices: [AudioInputDevice], selectedID: String) {
        microphones = devices
        selectedMicrophoneID = selectedID
    }

    func selectMicrophone(id: String) {
        selectedMicrophoneID = id
    }

    // MARK: - Mic dropdown
    //
    // The picker is rendered inside the overlay's SwiftUI tree (not a
    // native NSMenu) because the overlay window sits at `.screenSaver`
    // level — above the pop-up-menu window level — so an NSMenu would
    // draw on top but never receive the clicks (the overlay swallows
    // them). Rendering in-tree lets the controller's existing mouse
    // monitor hit-test the rows the same way it does the chip and the
    // Record button.

    /// Ordered dropdown rows: "System Default" first, then each
    /// connected device. Index 0 is always System Default.
    var micMenuItems: [AudioInputDevice] {
        [AudioInputDevice(id: "", name: "System Default")] + microphones
    }

    private(set) var isMicMenuOpen: Bool = false

    /// Row currently under the cursor while the dropdown is open, for the
    /// hover highlight. nil when nothing is hovered.
    private(set) var highlightedMicIndex: Int?

    func toggleMicMenu() {
        isMicMenuOpen.toggle()
        if isMicMenuOpen {
            // Only one toolbar dropdown at a time (see toggleModelMenu).
            closeModelMenu()
            closeDevSettingsMenu()
            closeUpgradePopup()
        } else {
            highlightedMicIndex = nil
        }
    }

    func closeMicMenu() {
        isMicMenuOpen = false
        highlightedMicIndex = nil
    }

    func setHighlightedMicIndex(_ index: Int?) {
        if highlightedMicIndex != index { highlightedMicIndex = index }
    }

    // MARK: - Model selection (multi-model — last-used model)
    //
    // The toolbar's model chip is the only model picker. It seeds from
    // `PreferencesStore.selectedModelID` (the last model the user recorded
    // with) and a pick is held in this state until record-start, where the
    // controller writes it back as the new last-used (see
    // AreaSelectorWindowController.onConfirm) — so picking a model and
    // recording makes it stick, while abandoning the overlay leaves the
    // stored model untouched. Like the mode toggle, the pick persists at
    // record-start (the mic dropdown, by contrast, persists immediately).
    // Rendering + row hit-testing mirror the mic dropdown (in-tree menu,
    // controller-owned monitor) for the same .screenSaver window-level reason.

    /// One row of the model dropdown — display data precomputed by the
    /// controller at present time (the view stays free of registry +
    /// entitlement reads).
    struct ModelMenuItem: Identifiable, Equatable {
        /// Registry wire id (`ModelEntry.id`).
        let id: String
        /// `ModelEntry.displayName`.
        let name: String
        /// Trailing detail: "4 cr · ~62 left" (Managed/Trial), "Add
        /// Gemini key" (BYOK key-gated), or nil (BYOK with key — credits
        /// are meaningless, no column).
        let detail: String?
        /// True for the registry's recommended entry (badge).
        let recommended: Bool
        /// BYOK key-gating: rendered dimmed + unselectable.
        let gated: Bool
    }

    /// Dropdown rows, cheapest-first (registry order). Set by the
    /// controller at present time.
    private(set) var models: [ModelMenuItem] = []

    /// The model THIS recording will use. Seeded from the last-used model; a
    /// dropdown pick changes only this copy until the controller persists it
    /// back as last-used at record-start.
    private(set) var selectedModelID: String = ""

    /// Label for the toolbar chip — the EFFECTIVE model's name, so a locked
    /// trial user always reads "Gemini 3.5 Flash" regardless of any prior pick.
    var selectedModelName: String {
        models.first { $0.id == effectiveModelID }?.name ?? effectiveModelID
    }

    private(set) var isModelChipHovered: Bool = false

    func setModelChipHovered(_ hovered: Bool) {
        if isModelChipHovered != hovered { isModelChipHovered = hovered }
    }

    private(set) var isModelMenuOpen: Bool = false

    /// Row under the cursor while the dropdown is open (hover highlight).
    private(set) var highlightedModelIndex: Int?

    func setModels(_ items: [ModelMenuItem], selectedID: String) {
        models = items
        selectedModelID = selectedID
    }

    func selectModel(id: String) {
        selectedModelID = id
    }

    /// Open/close the model dropdown. Only one toolbar dropdown may be
    /// open at a time, so opening this one closes the mic menu.
    func toggleModelMenu() {
        isModelMenuOpen.toggle()
        if isModelMenuOpen {
            closeMicMenu()
            closeDevSettingsMenu()
            closeUpgradePopup()
        } else {
            highlightedModelIndex = nil
        }
    }

    func closeModelMenu() {
        isModelMenuOpen = false
        highlightedModelIndex = nil
    }

    func setHighlightedModelIndex(_ index: Int?) {
        if highlightedModelIndex != index { highlightedModelIndex = index }
    }

    // MARK: - Trial model-picker lock (premium-model gating)
    //
    // While the user is on the `.trial` entitlement, the ONLY model they may use
    // is the free model (Gemini 3.5 Flash) — every other model is "premium" and
    // gated behind upgrade (Cursor's free-vs-premium pattern). The chip then
    // shows the free model + a lock glyph, and tapping it opens the upgrade
    // popup instead of the model list. `.byok`/`.managed` users are never locked.

    /// The long-lived entitlement store, injected at present time. It's
    /// `@Observable`, so reading `entitlements?.state` through the lock flag
    /// below makes the chip + popup react to a plan change (trial → managed)
    /// without a relaunch. nil in tests/previews → never locked (existing
    /// behavior), so the picker keeps the full model list.
    private(set) var entitlements: EntitlementStore?

    func setEntitlements(_ store: EntitlementStore?) {
        entitlements = store
    }

    /// The only model a trial user may use; matches `ModelRegistry`'s recommended
    /// free model. Generation is forced to this id while locked.
    static let lockedModelID = "gemini-3.5-flash"

    /// True while the model picker is locked to the free model — i.e. the user is
    /// on `.trial`. Drives the chip's lock glyph, the tap interception, and the
    /// forced effective model below.
    var isModelPickerLocked: Bool {
        if case .trial = entitlements?.state { return true }
        return false
    }

    /// The model id generation must actually use: forced to the free model while
    /// locked, otherwise the user's persisted pick. Computed at the point of use
    /// so the stored preference is NEVER overwritten — upgrading restores it.
    var effectiveModelID: String {
        isModelPickerLocked ? Self.lockedModelID : selectedModelID
    }

    // MARK: - Upgrade popup (trial model-lock)
    //
    // Rendered in-tree like the model/mic dropdowns (same `.screenSaver`
    // window-level reason) and anchored to the model chip. Mutually exclusive
    // with every toolbar dropdown.

    private(set) var isUpgradePopupOpen: Bool = false

    /// Hover state for the popup's Upgrade button (the overlay is hit-test-
    /// disabled, so the controller sets this on mouse-move and the view reflects
    /// it as a subtle brighten).
    private(set) var isUpgradeButtonHovered: Bool = false

    func setUpgradeButtonHovered(_ hovered: Bool) {
        if isUpgradeButtonHovered != hovered { isUpgradeButtonHovered = hovered }
    }

    /// Open/close the upgrade popup. Only one toolbar surface at a time, so
    /// opening it closes every dropdown.
    func toggleUpgradePopup() {
        isUpgradePopupOpen.toggle()
        if isUpgradePopupOpen {
            closeModelMenu()
            closeMicMenu()
            closeDevSettingsMenu()
        } else {
            isUpgradeButtonHovered = false
        }
    }

    func closeUpgradePopup() {
        isUpgradePopupOpen = false
        isUpgradeButtonHovered = false
    }

    // MARK: - Dev Mode (Phase 1)
    //
    // Dev Mode is a standalone mode switch on the toolbar's left — not a
    // setting. When on, the recording is handed to a local coding agent
    // (Claude Code in Phase 1) that edits files in `projectURL`, instead of
    // the normal clipboard hand-off. This state holds the toggle + the two
    // Dev-Mode-critical selections (agent + folder); the controller owns
    // persistence (PreferencesStore) and the folder picker, mirroring how it
    // owns the mic/model pickers. Everything here is inert in normal mode
    // (`isDevMode == false`), so non-Dev recordings behave exactly as today.

    /// Whether Dev Mode is engaged for this recording. Flipping it on grows
    /// the toolbar cluster from `model · mic · record` to
    /// `model · mic · agent · folder · record`.
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
            // Only one toolbar dropdown at a time.
            closeModelMenu()
            closeMicMenu()
            closeUpgradePopup()
            // Open on the selected model so a deep pick isn't hidden.
            resetDevModelScrollToSelection()
        } else {
            highlightedDevAgentIndex = nil
            highlightedDevModelIndex = nil
            highlightedDevPermissionIndex = nil
            isAutoDetectInfoHovered = false
            isPermissionInfoHovered = false
            localhostNotice = nil
        }
    }

    func closeDevSettingsMenu() {
        isDevSettingsMenuOpen = false
        highlightedDevAgentIndex = nil
        highlightedDevModelIndex = nil
        highlightedDevPermissionIndex = nil
        isAutoDetectInfoHovered = false
        isPermissionInfoHovered = false
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

    /// Called when Dev Mode is entered (Dev segment clicked, or seeded-on at
    /// present time). Auto-opens the dev-settings menu the first time this
    /// session, or any time the folder is still unset, so the user can finish
    /// setup; otherwise leaves it closed.
    func handleDevModeEntered() {
        if !hasAutoOpenedDevSettings || projectURL == nil {
            isDevSettingsMenuOpen = true
            closeModelMenu()
            closeMicMenu()
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

    /// Hover state for the compact mode switch's two segments + the dev-settings
    /// icon. Mirror the chip-hover pattern: the controller hit-tests the frames
    /// on mouse-move and the view reflects these (fill highlight + tooltip).
    private(set) var isModeArtifactHovered: Bool = false
    private(set) var isModeDevHovered: Bool = false
    private(set) var isDevSettingsHovered: Bool = false

    func setModeArtifactHovered(_ hovered: Bool) {
        if isModeArtifactHovered != hovered { isModeArtifactHovered = hovered }
    }

    func setModeDevHovered(_ hovered: Bool) {
        if isModeDevHovered != hovered { isModeDevHovered = hovered }
    }

    func setDevSettingsHovered(_ hovered: Bool) {
        if isDevSettingsHovered != hovered { isDevSettingsHovered = hovered }
    }

    /// Clear every toolbar control-hover flag. Used when a click relocates the
    /// toolbar (the mode switch resizes the container) and no mouse-move fires to
    /// refresh them — the next move re-establishes hover.
    func resetToolbarHovers() {
        isModeArtifactHovered = false
        isModeDevHovered = false
        isDevSettingsHovered = false
        isModelChipHovered = false
        isMicChipHovered = false
        isRecordButtonHovered = false
        isUpgradeButtonHovered = false
    }

    /// Seed the Dev Mode selections at present time from persisted prefs +
    /// agent detection (mirrors `setMicrophones`/`setModels`).
    func setDevState(isDevMode: Bool, agentID: String?, agentName: String, projectURL: URL?) {
        self.isDevMode = isDevMode
        self.selectedAgentID = agentID
        self.selectedAgentName = agentName
        self.projectURL = projectURL
    }

    /// Flip the mode switch. Toggling on while requirements are already met
    /// leaves the chips as-is; toggling off clears any inline validation
    /// message (it only applies to Dev Mode).
    func toggleDevMode() {
        setDevMode(!isDevMode)
    }

    /// Set the mode explicitly — the compact mode switch maps each segment to a
    /// mode (Artifact = off, Dev = on) rather than flipping, so clicking the
    /// already-active segment is a no-op. Turning Dev off clears any inline
    /// validation message and closes the dev-settings menu (both Dev-only);
    /// either change closes the model/mic dropdowns.
    func setDevMode(_ on: Bool) {
        guard isDevMode != on else { return }
        isDevMode = on
        if !on {
            devValidationMessage = nil
            closeDevSettingsMenu()
        }
        closeMicMenu()
        closeModelMenu()
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

    /// Hover state for the Permissions header's info icon, driving its custom
    /// tooltip (the overlay is hit-test-disabled, so `.help` never fires). Set by
    /// the controller's mouse-move hit-test; cleared when the menu closes.
    private(set) var isPermissionInfoHovered: Bool = false

    func setPermissionInfoHovered(_ hovered: Bool) {
        if isPermissionInfoHovered != hovered { isPermissionInfoHovered = hovered }
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

    // MARK: - Mutations driven by AreaSelectorEventView

    func beginDrag(at point: CGPoint) {
        // Starting a drag supersedes a prior full-screen selection: drawing
        // a rectangle returns to a normal area selection (Space is one-way
        // into full-screen, but a fresh drag drops back out).
        mode = .area
        dragOrigin = point
        dragCurrent = point
        isDragging = true
    }

    func updateDrag(to point: CGPoint) {
        dragCurrent = point
    }

    func endDrag(at point: CGPoint) {
        dragCurrent = point
        isDragging = false
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
