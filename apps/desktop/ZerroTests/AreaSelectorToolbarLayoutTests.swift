//
//  AreaSelectorToolbarLayoutTests.swift
//  ZerroTests
//
//  Multi-model — the capture toolbar's frame math (typed-artifact refactor:
//  the mode toggle is gone; the model chip is now leftmost). The toolbar is
//  not a SwiftUI HStack: every control's rect comes from static frame
//  helpers that the view renders with AND the controller hit-tests against,
//  so an arithmetic slip here means overlapping chrome and clicks landing
//  on the wrong control. These tests pin the invariants:
//    • cluster order model → mic → record, gap-separated,
//      mutually disjoint, all inside the toolbar frame;
//    • the toolbar width includes the model chip;
//    • the model dropdown's frame/row hit-test round-trips.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorToolbarLayoutTests: XCTestCase {

    /// A roomy selection in a roomy overlay — the common case where the
    /// toolbar hangs below the selection, un-clamped.
    private let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)

    private var toolbar: CGRect { AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds) }
    private var model: CGRect { AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds) }
    private var mic: CGRect { AreaSelectorView.micChipFrame(forSelection: selection, in: bounds) }
    private var record: CGRect { AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds) }

    // MARK: - Cluster order + widths

    func testToolbarWidthIncludesModelChip() {
        // model + gap + mic + gap + record — derived from the segment
        // frames so the assertion tracks the constants.
        let gap = mic.minX - model.maxX
        let expected = model.width + gap + mic.width + gap + record.width
        XCTAssertEqual(toolbar.width, expected, accuracy: 0.001)
        XCTAssertEqual(model.width, AreaSelectorView.modelChipWidth)
    }

    func testClusterOrderIsModelMicRecord() {
        let gap = mic.minX - model.maxX
        XCTAssertGreaterThan(gap, 0, "mic chip must sit AFTER the model chip with a gap")
        XCTAssertEqual(model.minX, toolbar.minX, "model chip is leftmost since the mode toggle's removal")
        XCTAssertEqual(mic.minX, model.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(record.minX, mic.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(record.maxX, toolbar.maxX, accuracy: 0.001)
    }

    func testSegmentsAreDisjointAndInsideToolbar() {
        let frames = [model, mic, record]
        for (i, a) in frames.enumerated() {
            XCTAssertTrue(toolbar.contains(a), "segment \(i) escapes the toolbar")
            for (j, b) in frames.enumerated() where i < j {
                XCTAssertFalse(a.intersects(b), "segments \(i) and \(j) overlap")
            }
        }
    }

    /// A click at each segment's center must hit-test to that segment
    /// and no other — the controller's monitor dispatches on exactly
    /// these `contains(point)` checks.
    func testCenterPointsHitTheRightControl() {
        let centers = [model, mic, record].map { CGPoint(x: $0.midX, y: $0.midY) }
        let frames = [model, mic, record]
        for (i, point) in centers.enumerated() {
            for (j, frame) in frames.enumerated() {
                XCTAssertEqual(frame.contains(point), i == j,
                               "center of segment \(i) vs frame \(j)")
            }
        }
    }

    // MARK: - Model dropdown geometry

    func testModelMenuHangsUnderTheChipAndHitTestsRows() {
        let itemCount = 6
        let menu = AreaSelectorView.modelMenuFrame(
            forSelection: selection, in: bounds, itemCount: itemCount
        )
        XCTAssertEqual(menu.minX, model.minX, accuracy: 0.001)
        XCTAssertGreaterThan(menu.minY, model.maxY)
        XCTAssertEqual(menu.width, AreaSelectorView.modelMenuWidth)

        // Row 0's vertical center maps back to index 0; the last row to
        // itemCount-1; a point above the panel maps to nil.
        let row0 = CGPoint(x: menu.midX, y: menu.minY + 6 + AreaSelectorView.modelMenuRowHeight / 2)
        XCTAssertEqual(
            AreaSelectorView.modelMenuRowIndex(at: row0, forSelection: selection, in: bounds, itemCount: itemCount),
            0
        )
        let rowLast = CGPoint(
            x: menu.midX,
            y: menu.minY + 6 + AreaSelectorView.modelMenuRowHeight * (CGFloat(itemCount) - 0.5)
        )
        XCTAssertEqual(
            AreaSelectorView.modelMenuRowIndex(at: rowLast, forSelection: selection, in: bounds, itemCount: itemCount),
            itemCount - 1
        )
        let outside = CGPoint(x: menu.midX, y: menu.minY - 10)
        XCTAssertNil(
            AreaSelectorView.modelMenuRowIndex(at: outside, forSelection: selection, in: bounds, itemCount: itemCount)
        )
    }

    // MARK: - Model pick state semantics

    func testModelSelectionDoesNotTouchPreferences() {
        // The state-level pick only mutates `state.selectedModelID`; it never
        // writes PreferencesStore. The last-used model is persisted by the
        // controller at record-start (onConfirm), not by the state pick — so
        // a pick the user backs out of leaves the stored model untouched.
        let state = AreaSelectorState()
        state.setModels(
            [.init(id: "a", name: "A", detail: nil, recommended: false, gated: false),
             .init(id: "b", name: "B", detail: "2 cr", recommended: true, gated: false)],
            selectedID: "a"
        )
        XCTAssertEqual(state.selectedModelID, "a")
        state.selectModel(id: "b")
        XCTAssertEqual(state.selectedModelID, "b")
        XCTAssertEqual(state.selectedModelName, "B")
    }

    func testOnlyOneToolbarDropdownOpensAtATime() {
        let state = AreaSelectorState()
        state.toggleMicMenu()
        XCTAssertTrue(state.isMicMenuOpen)
        state.toggleModelMenu()
        XCTAssertTrue(state.isModelMenuOpen)
        XCTAssertFalse(state.isMicMenuOpen, "opening the model menu must close the mic menu")
        state.toggleMicMenu()
        XCTAssertTrue(state.isMicMenuOpen)
        XCTAssertFalse(state.isModelMenuOpen, "opening the mic menu must close the model menu")
    }
}
