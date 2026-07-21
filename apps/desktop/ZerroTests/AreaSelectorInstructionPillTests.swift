//
//  AreaSelectorInstructionPillTests.swift
//  ZerroTests
//
//  The large centered resting instruction pill (CleanShot-style start
//  screen) renders only in area mode's initial resting state. These tests
//  pin `showsRestingInstructionPill` — the single visibility rule the view
//  gates on: visible before any drag, gone the instant a drag begins, and
//  never shown in full-screen mode (which keeps its own small top prompt)
//  or while the toolbar walkthrough runs.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorInstructionPillTests: XCTestCase {

    private let overlay = CGSize(width: 1728, height: 1117)

    func testRestingPillShowsOnFreshOverlay() {
        let state = AreaSelectorState()
        XCTAssertEqual(state.mode, .area)
        XCTAssertNil(state.selectionRect)
        XCTAssertTrue(state.showsRestingInstructionPill)
    }

    func testRestingPillHidesTheInstantADragBegins() {
        let state = AreaSelectorState()
        XCTAssertTrue(state.showsRestingInstructionPill)

        // mouseDown alone sets selectionRect (a zero-size rect) — the pill
        // must already be gone, before any movement.
        state.beginDrag(at: CGPoint(x: 300, y: 300))
        XCTAssertNotNil(state.selectionRect)
        XCTAssertFalse(state.showsRestingInstructionPill)

        // …and it stays gone through the in-flight drag and the settle.
        state.updateDrag(to: CGPoint(x: 700, y: 650))
        XCTAssertFalse(state.showsRestingInstructionPill)
        state.endDrag(at: CGPoint(x: 700, y: 650))
        XCTAssertFalse(state.showsRestingInstructionPill)
    }

    func testRestingPillNeverShowsInFullScreenMode() {
        let state = AreaSelectorState()
        state.enterFullScreenMode(overlaySize: overlay)
        XCTAssertEqual(state.mode, .fullScreen)
        // Full-screen clears the selection, but the resting pill is area-only
        // (the small top prompt owns full-screen).
        XCTAssertNil(state.selectionRect)
        XCTAssertFalse(state.showsRestingInstructionPill)
    }

    func testRestingPillHidesWhileWalkthroughRunsAndReturnsAfter() {
        let state = AreaSelectorState()
        state.startToolbarWalkthrough()
        XCTAssertFalse(state.showsRestingInstructionPill)

        state.endToolbarWalkthrough(completed: true)
        XCTAssertTrue(state.showsRestingInstructionPill)
    }
}
