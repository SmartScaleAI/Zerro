//
//  AreaSelectorState.swift
//  VisualFlowAI
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

    // MARK: - Confirm / cancel

    func cancel() {
        onCancel?()
    }

    func confirm(with rect: SelectionRect) {
        onConfirm?(rect)
    }
}
