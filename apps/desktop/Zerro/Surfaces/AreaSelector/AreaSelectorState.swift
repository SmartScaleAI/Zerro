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

    // MARK: - Model selection (multi-model — per-recording override)
    //
    // The toolbar carries a model chip so the generation model for THIS
    // recording can be chosen at capture time. Unlike the mic dropdown
    // (which persists immediately) and the mode toggle (which persists at
    // record-start), the model chip is a PER-RECORDING override: it seeds
    // from `PreferencesStore.selectedModelID` (the Preferences "Default
    // model") and a change here is handed to `startRecording` WITHOUT
    // touching the persisted default — the next recording starts back on
    // the default. Rendering + row hit-testing mirror the mic dropdown
    // (in-tree menu, controller-owned monitor) for the same .screenSaver
    // window-level reason.

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

    /// The model THIS recording will use. Seeded from the persisted
    /// default; a dropdown pick changes only this copy.
    private(set) var selectedModelID: String = ""

    /// Label for the toolbar chip.
    var selectedModelName: String {
        models.first { $0.id == selectedModelID }?.name ?? selectedModelID
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
