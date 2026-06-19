//
//  AreaSelectorFullScreenTests.swift
//  ZerroTests
//
//  Full-screen selection — pressing Space in the area-selector overlay
//  selects the entire display the overlay is on (replacing the removed
//  CleanShot-style window mode). These tests pin the one-way state
//  transition, the full-display confirmable rect, and the bottom-center
//  toolbar geometry. The controller's view-local→global SelectionRect
//  handoff needs a live NSWindow, so it's verified manually on hardware;
//  here we cover the pure state + frame-math surface.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorFullScreenTests: XCTestCase {

    private let overlay = CGSize(width: 1728, height: 1117)

    // MARK: - State transitions

    func testSpaceEntersFullScreenMode() {
        let state = AreaSelectorState()
        XCTAssertEqual(state.mode, .area)

        state.enterFullScreenMode(overlaySize: overlay)

        XCTAssertEqual(state.mode, .fullScreen)
    }

    func testFullScreenConfirmableRectEqualsTheWholeOverlay() {
        let state = AreaSelectorState()
        // Before entering full-screen there's nothing to confirm (no drag).
        XCTAssertNil(state.confirmableSelectionRect)

        state.enterFullScreenMode(overlaySize: overlay)

        XCTAssertEqual(
            state.confirmableSelectionRect,
            CGRect(origin: .zero, size: overlay),
            "full-screen selection must be the whole display"
        )
    }

    func testFullScreenClearsAnyInFlightDrag() {
        let state = AreaSelectorState()
        // A half-drawn drag in flight…
        state.beginDrag(at: CGPoint(x: 100, y: 100))
        state.updateDrag(to: CGPoint(x: 400, y: 400))
        XCTAssertNotNil(state.selectionRect)

        state.enterFullScreenMode(overlaySize: overlay)

        XCTAssertFalse(state.isDragging)
        XCTAssertNil(state.selectionRect, "entering full-screen drops the drag rect")
    }

    func testDrawingADragSupersedesFullScreen() {
        let state = AreaSelectorState()
        state.enterFullScreenMode(overlaySize: overlay)
        XCTAssertEqual(state.mode, .fullScreen)

        // Drawing a new rectangle returns to a normal area selection
        // (Space is one-way INTO full-screen; a fresh drag drops back out).
        state.beginDrag(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(state.mode, .area)

        state.updateDrag(to: CGPoint(x: 600, y: 500))
        state.endDrag(at: CGPoint(x: 600, y: 500))
        XCTAssertEqual(
            state.confirmableSelectionRect,
            CGRect(x: 200, y: 200, width: 400, height: 300)
        )
    }

    // MARK: - Bottom-center toolbar geometry

    func testFullScreenToolbarIsPinnedBottomCenter() {
        // No Dock (inset 0) → floats `fullScreenDockGap` above the bottom edge.
        let frame = AreaSelectorView.fullScreenToolbarFrame(in: overlay)

        // Horizontally centered.
        XCTAssertEqual(frame.midX, overlay.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, overlay.height - AreaSelectorView.fullScreenDockGap, accuracy: 0.001)
        XCTAssertEqual(frame.height, AreaSelectorView.toolbarHeight, accuracy: 0.001)
    }

    func testFullScreenToolbarFloatsAboveTheDock() {
        let dock: CGFloat = 70
        let frame = AreaSelectorView.fullScreenToolbarFrame(in: overlay, bottomInset: dock)
        // Bottom edge sits `fullScreenDockGap` above the Dock's top, still centered.
        XCTAssertEqual(frame.midX, overlay.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, overlay.height - dock - AreaSelectorView.fullScreenDockGap, accuracy: 0.001)
        // The bigger inset raises it relative to the hidden-Dock case.
        let hidden = AreaSelectorView.fullScreenToolbarFrame(in: overlay, bottomInset: 0)
        XCTAssertLessThan(frame.maxY, hidden.maxY)
        XCTAssertLessThan(hidden.maxY, overlay.height, "never flush against the very bottom edge")
    }

    func testFullScreenFlagRoutesToBottomCenterFrame() {
        // The `fullScreen: true` path ignores the selection rect and pins
        // bottom-center — passing the full-bounds rect through it must NOT
        // anchor under the (full-screen) selection.
        let full = CGRect(origin: .zero, size: overlay)
        let viaFlag = AreaSelectorView.toolbarFrame(forSelection: full, in: overlay, fullScreen: true)
        let direct = AreaSelectorView.fullScreenToolbarFrame(in: overlay)
        XCTAssertEqual(viaFlag, direct)
    }

    func testFullScreenSegmentsAreDisjointAndCentered() {
        let full = CGRect(origin: .zero, size: overlay)
        let modeSwitch = AreaSelectorView.devToggleFrame(forSelection: full, in: overlay, fullScreen: true)
        let model = AreaSelectorView.modelChipFrame(forSelection: full, in: overlay, fullScreen: true)
        let mic = AreaSelectorView.micChipFrame(forSelection: full, in: overlay, fullScreen: true)
        let record = AreaSelectorView.recordButtonFrame(forSelection: full, in: overlay, fullScreen: true)
        let toolbar = AreaSelectorView.fullScreenToolbarFrame(in: overlay)

        // Compact order: mode switch → model → mic → record, gap-separated, all
        // inside the toolbar. The mode switch is leftmost (inset by the same
        // margin Record is inset from the trailing edge).
        let gap = mic.minX - model.maxX
        XCTAssertGreaterThan(gap, 0)
        XCTAssertLessThan(modeSwitch.maxX, model.minX, "mode switch leads the cluster")
        let leadingInset = modeSwitch.minX - toolbar.minX
        XCTAssertEqual(record.maxX, toolbar.maxX - leadingInset, accuracy: 0.001, "symmetric insets")
        for frame in [modeSwitch, model, mic, record] {
            XCTAssertTrue(toolbar.contains(frame))
        }
        XCTAssertFalse(modeSwitch.intersects(model))
        XCTAssertFalse(model.intersects(mic))
        XCTAssertFalse(mic.intersects(record))
    }
}
