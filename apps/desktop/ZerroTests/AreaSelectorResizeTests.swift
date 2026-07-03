//
//  AreaSelectorResizeTests.swift
//  ZerroTests
//
//  Resizable / movable area selection — after a region settles, the 8
//  handles resize it (corners move two edges, edge midpoints one) and
//  dragging the interior moves it. These tests pin the pure state math
//  (grab/resize/move/clamp), the static handle/interior hit-testing the
//  controller's monitor routes through, and the handle→cursor mapping.
//  The controller's live NSEvent routing + the actual cursor glyphs are
//  verified manually on hardware, mirroring AreaSelectorFullScreenTests.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorResizeTests: XCTestCase {

    private let overlay = CGSize(width: 1728, height: 1117)
    /// The settled region every test starts from.
    private let rect = CGRect(x: 200, y: 200, width: 400, height: 300)

    /// A state with a settled, confirmable selection of `rect`.
    private func settledState() -> AreaSelectorState {
        let state = AreaSelectorState()
        state.setOverlaySize(overlay)
        state.beginDrag(at: CGPoint(x: rect.minX, y: rect.minY))
        state.updateDrag(to: CGPoint(x: rect.maxX, y: rect.maxY))
        state.endDrag(at: CGPoint(x: rect.maxX, y: rect.maxY))
        return state
    }

    // MARK: - Handle hit-testing

    func testEachHandleResolvesAtItsOwnPoint() {
        let cases: [(AreaSelectorState.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
        for (expected, point) in cases {
            XCTAssertEqual(
                AreaSelectorView.handleHitTest(at: point, selection: rect),
                expected,
                "exact handle point must resolve to \(expected)"
            )
        }
    }

    func testHitSlopCatchesANearMiss() {
        let slop = AreaSelectorView.handleHitSlop
        // Just inside the slop around the bottom-right corner, outside the rect.
        let near = CGPoint(x: rect.maxX + slop - 1, y: rect.maxY + slop - 1)
        XCTAssertEqual(AreaSelectorView.handleHitTest(at: near, selection: rect), .bottomRight)
        // Just beyond the slop resolves to nothing.
        let far = CGPoint(x: rect.maxX + slop + 1, y: rect.maxY + slop + 1)
        XCTAssertNil(AreaSelectorView.handleHitTest(at: far, selection: rect))
    }

    func testEdgeIsGrabbableAnywhereAlongItsSegment() {
        // Well away from the midpoint dot, still on the edge line.
        let onTop = CGPoint(x: rect.minX + 100, y: rect.minY)
        XCTAssertEqual(AreaSelectorView.handleHitTest(at: onTop, selection: rect), .top)
        // Slightly outside the edge line, within the slop band.
        let nearLeft = CGPoint(x: rect.minX - 10, y: rect.midY + 40)
        XCTAssertEqual(AreaSelectorView.handleHitTest(at: nearLeft, selection: rect), .left)
    }

    func testCornersWinOverEdgesInTheOverlapZone() {
        // On the top edge line but within the corner zone: corner wins.
        let overlap = CGPoint(x: rect.minX + AreaSelectorView.handleHitSlop - 1, y: rect.minY)
        XCTAssertEqual(AreaSelectorView.handleHitTest(at: overlap, selection: rect), .topLeft)
    }

    func testInteriorHit() {
        // Center: interior, and not a handle.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        XCTAssertTrue(AreaSelectorView.isInteriorHit(center, selection: rect))
        XCTAssertNil(AreaSelectorView.handleHitTest(at: center, selection: rect))
        // Inside the rect but within the edge band: handle territory, not interior.
        let nearEdge = CGPoint(x: rect.midX, y: rect.minY + 5)
        XCTAssertFalse(AreaSelectorView.isInteriorHit(nearEdge, selection: rect))
        XCTAssertEqual(AreaSelectorView.handleHitTest(at: nearEdge, selection: rect), .top)
        // Outside the rect entirely.
        let outside = CGPoint(x: rect.maxX + 200, y: rect.maxY + 200)
        XCTAssertFalse(AreaSelectorView.isInteriorHit(outside, selection: rect))
    }

    // MARK: - Resize math

    func testRightHandleMovesOnlyMaxX() {
        let state = settledState()
        state.beginEdit(.resizing(.right), at: CGPoint(x: rect.maxX, y: rect.midY))
        state.updateResize(to: CGPoint(x: rect.maxX + 80, y: rect.midY + 50))

        XCTAssertEqual(
            state.selectionRect,
            CGRect(x: rect.minX, y: rect.minY, width: rect.width + 80, height: rect.height),
            "an edge handle moves exactly one edge; the cursor's other axis is ignored"
        )
    }

    func testTopHandleMovesOnlyMinY() {
        let state = settledState()
        state.beginEdit(.resizing(.top), at: CGPoint(x: rect.midX, y: rect.minY))
        state.updateResize(to: CGPoint(x: rect.midX - 60, y: rect.minY - 40))

        XCTAssertEqual(
            state.selectionRect,
            CGRect(x: rect.minX, y: rect.minY - 40, width: rect.width, height: rect.height + 40)
        )
    }

    func testBottomRightCornerMovesBothEdgesAndAnchorsTheOpposite() throws {
        let state = settledState()
        state.beginEdit(.resizing(.bottomRight), at: CGPoint(x: rect.maxX, y: rect.maxY))
        state.updateResize(to: CGPoint(x: rect.maxX + 30, y: rect.maxY - 20))

        let result = try XCTUnwrap(state.selectionRect)
        XCTAssertEqual(result.minX, rect.minX, "opposite corner stays put")
        XCTAssertEqual(result.minY, rect.minY, "opposite corner stays put")
        XCTAssertEqual(result.maxX, rect.maxX + 30)
        XCTAssertEqual(result.maxY, rect.maxY - 20)
    }

    func testResizePinsAtTheMinimumSize() throws {
        let state = settledState()
        let minSize = AreaSelectorState.minimumSelectionSize
        state.beginEdit(.resizing(.right), at: CGPoint(x: rect.maxX, y: rect.midY))
        // Drag far past the left edge — the width pins at the floor instead of
        // collapsing or flipping through.
        state.updateResize(to: CGPoint(x: rect.minX - 500, y: rect.midY))

        let result = try XCTUnwrap(state.selectionRect)
        XCTAssertEqual(result.width, minSize, "width pins at minimumSelectionSize")
        XCTAssertEqual(result.minX, rect.minX, "the anchored edge never moves")
        XCTAssertEqual(result.height, rect.height)

        // Same on the vertical axis via a corner.
        state.endEdit()
        state.beginEdit(.resizing(.topLeft), at: CGPoint(x: result.minX, y: result.minY))
        state.updateResize(to: CGPoint(x: result.maxX + 500, y: result.maxY + 500))
        let pinned = try XCTUnwrap(state.selectionRect)
        XCTAssertEqual(pinned.width, minSize)
        XCTAssertEqual(pinned.height, minSize)

        // A pinned rect settles confirmable — Record comes right back.
        state.endEdit()
        XCTAssertNotNil(state.confirmableSelectionRect)
    }

    // MARK: - Move math

    func testMoveTranslatesWithoutResizing() {
        let state = settledState()
        let grab = CGPoint(x: rect.midX + 10, y: rect.midY - 10)
        state.beginEdit(.moving, at: grab)
        // Delta-based: the rect shifts by the drag delta from the grab point,
        // it does NOT snap its origin under the cursor.
        state.updateMove(to: CGPoint(x: grab.x + 55, y: grab.y + 25))

        XCTAssertEqual(state.selectionRect, rect.offsetBy(dx: 55, dy: 25))
    }

    func testMoveClampsInsideTheOverlay() {
        let state = settledState()
        let grab = CGPoint(x: rect.midX, y: rect.midY)
        state.beginEdit(.moving, at: grab)

        // Shove far past the top-left: pins at the origin, size unchanged.
        state.updateMove(to: CGPoint(x: grab.x - 5000, y: grab.y - 5000))
        XCTAssertEqual(state.selectionRect, CGRect(origin: .zero, size: rect.size))

        // Shove far past the bottom-right: pins flush to the overlay edge.
        state.updateMove(to: CGPoint(x: grab.x + 5000, y: grab.y + 5000))
        XCTAssertEqual(
            state.selectionRect,
            CGRect(
                x: overlay.width - rect.width,
                y: overlay.height - rect.height,
                width: rect.width, height: rect.height
            )
        )
    }

    // MARK: - Gesture bookkeeping

    func testBeginEditSetsInteractionAndHidesTheToolbar() {
        let state = settledState()
        XCTAssertEqual(state.interaction, .none)
        XCTAssertNotNil(state.confirmableSelectionRect)

        state.beginEdit(.resizing(.left), at: CGPoint(x: rect.minX, y: rect.midY))

        XCTAssertEqual(state.interaction, .resizing(.left))
        XCTAssertTrue(state.isDragging)
        XCTAssertNil(state.confirmableSelectionRect, "toolbar hides while adjusting")

        state.endEdit()

        XCTAssertEqual(state.interaction, .none)
        XCTAssertFalse(state.isDragging)
        XCTAssertEqual(state.confirmableSelectionRect, rect, "settles right back")
    }

    func testCreateDragTracksInteractionToo() {
        let state = AreaSelectorState()
        state.setOverlaySize(overlay)
        XCTAssertEqual(state.interaction, .none)
        state.beginDrag(at: .zero)
        XCTAssertEqual(state.interaction, .creating)
        state.endDrag(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(state.interaction, .none)
    }

    func testFreshDragAfterAnEditStartsANewRect() {
        let state = settledState()
        state.beginEdit(.moving, at: CGPoint(x: rect.midX, y: rect.midY))
        state.updateMove(to: CGPoint(x: rect.midX + 40, y: rect.midY))
        state.endEdit()

        state.beginDrag(at: CGPoint(x: 900, y: 700))
        XCTAssertEqual(state.interaction, .creating)
        state.updateDrag(to: CGPoint(x: 1100, y: 900))
        state.endDrag(at: CGPoint(x: 1100, y: 900))
        XCTAssertEqual(
            state.confirmableSelectionRect,
            CGRect(x: 900, y: 700, width: 200, height: 200)
        )
    }

    func testEditMutationsAreNoOpsOutsideTheirGesture() {
        let state = settledState()
        // No beginEdit: neither mutation may disturb the settled rect.
        state.updateResize(to: CGPoint(x: 50, y: 50))
        state.updateMove(to: CGPoint(x: 50, y: 50))
        XCTAssertEqual(state.selectionRect, rect)

        // A resize gesture ignores move updates and vice versa.
        state.beginEdit(.resizing(.right), at: CGPoint(x: rect.maxX, y: rect.midY))
        state.updateMove(to: CGPoint(x: 0, y: 0))
        XCTAssertEqual(state.selectionRect, rect, "updateMove is inert while resizing")
        state.endEdit()
    }

    func testBeginEditWithoutASelectionOrWithANonEditKindIsInert() {
        let empty = AreaSelectorState()
        empty.setOverlaySize(overlay)
        empty.beginEdit(.moving, at: .zero)
        XCTAssertEqual(empty.interaction, .none)
        XCTAssertFalse(empty.isDragging)

        let state = settledState()
        state.beginEdit(.creating, at: .zero)
        XCTAssertEqual(state.interaction, .none, "beginEdit only accepts edit kinds")
        state.beginEdit(.none, at: .zero)
        XCTAssertEqual(state.interaction, .none)
    }

    // MARK: - Mode gating

    func testEnterFullScreenClearsAnInFlightEdit() {
        let state = settledState()
        state.beginEdit(.resizing(.bottom), at: CGPoint(x: rect.midX, y: rect.maxY))

        state.enterFullScreenMode(overlaySize: overlay)

        XCTAssertEqual(state.interaction, .none)
        XCTAssertFalse(state.isDragging)
        // And a stale updateResize can't touch anything afterward.
        state.updateResize(to: .zero)
        XCTAssertNil(state.selectionRect)
    }

    // MARK: - Cursor mapping

    func testHandleToFrameResizePositionMapping() {
        let cases: [(AreaSelectorState.Handle, NSCursor.FrameResizePosition)] = [
            (.topLeft, .topLeft), (.top, .top), (.topRight, .topRight),
            (.right, .right), (.bottomRight, .bottomRight), (.bottom, .bottom),
            (.bottomLeft, .bottomLeft), (.left, .left),
        ]
        for (handle, expected) in cases {
            XCTAssertEqual(
                AreaSelectorWindowController.frameResizePosition(for: handle),
                expected
            )
        }
    }
}
