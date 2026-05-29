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
    /// drag-to-select region; `.window` is the CleanShot-style mode
    /// where moving the cursor highlights the window underneath and a
    /// click settles it (Space toggles between the two).
    enum Mode: Equatable {
        case area
        case window
    }

    private(set) var mode: Mode = .area

    /// One on-screen window the user can target in `.window` mode.
    /// `frame` is in the overlay's view-local, TOP-LEFT coordinate
    /// space (same as drag points) so the view can render it without
    /// further conversion. `id` is the `CGWindowID` threaded into the
    /// resulting `SelectionRect` for clean per-window capture.
    struct WindowCandidate: Identifiable, Equatable {
        let id: CGWindowID
        let frame: CGRect
        let title: String?
    }

    /// On-screen windows for the current display, front-to-back. Set
    /// by the controller when entering window mode.
    private(set) var windows: [WindowCandidate] = []

    /// Window currently under the cursor (not yet clicked). Drives the
    /// live hover highlight.
    private(set) var highlightedWindowID: CGWindowID?

    /// Window the user clicked to settle on. Once set, Enter confirms
    /// it. nil until a click lands on a candidate.
    private(set) var settledWindowID: CGWindowID?

    /// The candidate the user is acting on: the settled one if present,
    /// otherwise the hovered one.
    var activeWindow: WindowCandidate? {
        let target = settledWindowID ?? highlightedWindowID
        guard let target else { return nil }
        return windows.first { $0.id == target }
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
    ///   • window: a window the user has clicked to settle.
    var confirmableSelectionRect: CGRect? {
        switch mode {
        case .area:
            guard !isDragging, let rect = selectionRect,
                  rect.width >= Self.minimumSelectionSize,
                  rect.height >= Self.minimumSelectionSize else { return nil }
            return rect
        case .window:
            guard settledWindowID != nil, let candidate = activeWindow else { return nil }
            return candidate.frame
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
        if !isMicMenuOpen { highlightedMicIndex = nil }
    }

    func closeMicMenu() {
        isMicMenuOpen = false
        highlightedMicIndex = nil
    }

    func setHighlightedMicIndex(_ index: Int?) {
        if highlightedMicIndex != index { highlightedMicIndex = index }
    }

    // MARK: - Mutations driven by AreaSelectorEventView

    func beginDrag(at point: CGPoint) {
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

    // MARK: - Window-mode mutations

    /// Switch into window mode with a freshly enumerated candidate
    /// list. Clears any in-progress drag so the area selection doesn't
    /// bleed through the window-mode rendering.
    func enterWindowMode(windows: [WindowCandidate]) {
        mode = .window
        self.windows = windows
        dragOrigin = nil
        dragCurrent = nil
        isDragging = false
        settledWindowID = nil
        highlightedWindowID = nil
        isRecordButtonHovered = false
    }

    /// Return to free-draw area mode, discarding window state.
    func enterAreaMode() {
        mode = .area
        windows = []
        highlightedWindowID = nil
        settledWindowID = nil
        isRecordButtonHovered = false
    }

    /// Highlight the front-most window whose frame contains `point`
    /// (view-local, top-left). Front-to-back order means the first
    /// match wins. Once a window is settled (clicked), the highlight is
    /// locked to it — moving the cursor toward the floating Record
    /// button must not re-target or clear the selection. A fresh click
    /// re-settles (see `settleWindow`).
    func hoverWindow(at point: CGPoint) {
        guard settledWindowID == nil else { return }
        highlightedWindowID = windows.first { $0.frame.contains(point) }?.id
    }

    /// Settle on the window under `point`, if any. Returns the settled
    /// candidate so the controller can decide whether a click was a
    /// hit. A click on empty space is a no-op (keeps prior settle).
    @discardableResult
    func settleWindow(at point: CGPoint) -> WindowCandidate? {
        guard let hit = windows.first(where: { $0.frame.contains(point) }) else {
            return nil
        }
        settledWindowID = hit.id
        highlightedWindowID = hit.id
        return hit
    }

    // MARK: - Confirm / cancel

    func cancel() {
        onCancel?()
    }

    func confirm(with rect: SelectionRect) {
        onConfirm?(rect)
    }
}
