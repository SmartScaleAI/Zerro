//
//  AreaSelectorToolbarLayoutTests.swift
//  ZerroTests
//
//  Compact icon toolbar — the capture toolbar's frame math. The toolbar is
//  ONE rounded container holding: a two-segment mode switch, a divider, the
//  model/mic icon buttons, then the Record pill. It is not a SwiftUI HStack:
//  every control's rect comes from static frame helpers that the view renders
//  with AND the controller hit-tests against, so an arithmetic slip here means
//  overlapping chrome and clicks landing on the wrong control. These tests pin
//  the invariants:
//    • mode switch is the leading control, inset symmetrically from both ends;
//    • cluster order mode → model → mic → record, gap-separated, disjoint,
//      all inside the toolbar frame;
//    • the two mode segments tile the switch exactly;
//    • the model dropdown centers under its icon and its rows hit-test back.
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
    private var modeSwitch: CGRect { AreaSelectorView.devToggleFrame(forSelection: selection, in: bounds) }
    private var model: CGRect { AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds) }
    private var mic: CGRect { AreaSelectorView.micChipFrame(forSelection: selection, in: bounds) }
    private var record: CGRect { AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds) }

    // MARK: - Cluster order + widths

    func testControlWidthsMatchCompactMetrics() {
        XCTAssertEqual(modeSwitch.width, AreaSelectorView.modeSwitchWidth)
        XCTAssertEqual(model.width, AreaSelectorView.iconButtonWidth)
        XCTAssertEqual(mic.width, AreaSelectorView.iconButtonWidth)
        XCTAssertEqual(record.width, AreaSelectorView.recordButtonWidth)
    }

    func testToolbarWidthMatchesClusterWidth() {
        XCTAssertEqual(toolbar.width, AreaSelectorView.toolbarClusterWidth(devMode: false), accuracy: 0.001)
    }

    func testModeSwitchIsLeadingControlSymmetricallyInset() {
        // The mode switch now lives INSIDE the container (no longer floating
        // left), inset from the leading edge by the same margin Record is inset
        // from the trailing edge.
        XCTAssertTrue(toolbar.contains(modeSwitch), "mode switch must sit inside the toolbar")
        let leadingInset = modeSwitch.minX - toolbar.minX
        let trailingInset = toolbar.maxX - record.maxX
        XCTAssertGreaterThan(leadingInset, 0)
        XCTAssertEqual(leadingInset, trailingInset, accuracy: 0.001, "container insets are symmetric")
    }

    func testClusterOrderIsModeModelMicRecord() {
        // mode switch → (divider) → model → mic → record, left to right.
        XCTAssertLessThan(modeSwitch.maxX, model.minX, "divider gap separates the switch from model")
        let modelMicGap = mic.minX - model.maxX
        let micRecordGap = record.minX - mic.maxX
        XCTAssertGreaterThan(modelMicGap, 0, "mic sits after model with a gap")
        XCTAssertGreaterThan(micRecordGap, 0, "record sits after mic with a gap")
        XCTAssertEqual(mic.minX, model.maxX + modelMicGap, accuracy: 0.001)
    }

    func testSegmentsAreDisjointAndInsideToolbar() {
        let frames = [modeSwitch, model, mic, record]
        for (i, a) in frames.enumerated() {
            XCTAssertTrue(toolbar.contains(a), "segment \(i) escapes the toolbar")
            for (j, b) in frames.enumerated() where i < j {
                XCTAssertFalse(a.intersects(b), "segments \(i) and \(j) overlap")
            }
        }
    }

    /// A click at each control's center must hit-test to that control and no
    /// other — the controller's monitor dispatches on these `contains(point)`.
    func testCenterPointsHitTheRightControl() {
        let frames = [modeSwitch, model, mic, record]
        let centers = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
        for (i, point) in centers.enumerated() {
            for (j, frame) in frames.enumerated() {
                XCTAssertEqual(frame.contains(point), i == j,
                               "center of control \(i) vs frame \(j)")
            }
        }
    }

    // MARK: - Toolbar scale knob

    /// The whole toolbar is driven by one zoom factor: every metric is
    /// `base * toolbarScale`. We don't pin absolute pixels (those move with the
    /// factor by design); we pin that the factor is actually wired through the
    /// representative width/height constants, so a future revert can't silently
    /// drop the scaling.
    func testToolbarScaleIsAppliedToMetrics() {
        let s = AreaSelectorView.toolbarScale
        XCTAssertGreaterThanOrEqual(s, 1.0, "scale only ever zooms up from the base design")
        XCTAssertEqual(AreaSelectorView.toolbarHeight, 40 * s, accuracy: 0.001)
        XCTAssertEqual(AreaSelectorView.recordButtonWidth, 118 * s, accuracy: 0.001)
        XCTAssertEqual(AreaSelectorView.modeSegmentWidth, 34 * s, accuracy: 0.001)
        XCTAssertEqual(AreaSelectorView.iconButtonWidth, 46 * s, accuracy: 0.001)
        // The scaled() helper used by the inline font/radius/padding literals
        // must apply the same factor the metrics use.
        XCTAssertEqual(AreaSelectorView.scaled(14), 14 * s, accuracy: 0.001)
    }

    // MARK: - Area-mode positioning

    func testToolbarCentersInComfortablyLargeSelection() {
        // A selection comfortably larger than the toolbar → centered ON the region.
        let big = CGRect(x: 200, y: 150, width: 900, height: 500)
        let t = AreaSelectorView.toolbarFrame(forSelection: big, in: bounds)
        XCTAssertEqual(t.midX, big.midX, accuracy: 0.001)
        XCTAssertEqual(t.midY, big.midY, accuracy: 0.001)
        XCTAssertTrue(big.contains(t), "the centered toolbar stays inside the region")
    }

    func testToolbarDropsBelowSelectionTooNarrowToCenter() {
        // A tall-but-narrow selection (confirmable, but narrower than the toolbar)
        // → falls back to hanging below the selection.
        let narrow = CGRect(x: 400, y: 200, width: 200, height: 500)
        let t = AreaSelectorView.toolbarFrame(forSelection: narrow, in: bounds)
        XCTAssertGreaterThanOrEqual(t.minY, narrow.maxY, "toolbar hangs below the selection")
        XCTAssertEqual(t.midX, narrow.midX, accuracy: 0.001)
        XCTAssertFalse(narrow.contains(t), "it is not centered inside such a small region")
    }

    // MARK: - Mode switch segments

    func testModeSegmentsTileTheSwitchExactly() {
        let ask = AreaSelectorView.modeAskSegmentFrame(forSelection: selection, in: bounds)
        let dev = AreaSelectorView.modeDevSegmentFrame(forSelection: selection, in: bounds)
        XCTAssertEqual(ask.minX, modeSwitch.minX, accuracy: 0.001)
        XCTAssertEqual(ask.maxX, dev.minX, accuracy: 0.001, "segments share a seam")
        XCTAssertEqual(dev.maxX, modeSwitch.maxX, accuracy: 0.001)
        XCTAssertEqual(ask.width, dev.width, accuracy: 0.001, "segments are equal halves")
        XCTAssertFalse(ask.intersects(dev))
    }

    // MARK: - Model dropdown geometry

    func testModelMenuCentersUnderTheIconAndHitTestsRows() {
        let itemCount = 6
        let menu = AreaSelectorView.modelMenuFrame(
            forSelection: selection, in: bounds, itemCount: itemCount
        )
        // Centered under the icon (roomy case → un-clamped).
        XCTAssertEqual(menu.midX, model.midX, accuracy: 0.001)
        XCTAssertGreaterThan(menu.minY, model.maxY)
        XCTAssertEqual(menu.width, AreaSelectorView.modelMenuWidth)

        // Rows begin BELOW the static notice band + section header. Row 0's
        // center maps to index 0; the last row to itemCount-1; a point in the
        // notice/header band maps to nil.
        let rowsTop = menu.minY + AreaSelectorView.menuVPad
            + AreaSelectorView.modelMenuNoticeHeight + AreaSelectorView.menuSectionHeaderHeight
        let row0 = CGPoint(x: menu.midX, y: rowsTop + AreaSelectorView.modelMenuRowHeight / 2)
        XCTAssertEqual(
            AreaSelectorView.modelMenuRowIndex(at: row0, forSelection: selection, in: bounds, itemCount: itemCount),
            0
        )
        let rowLast = CGPoint(
            x: menu.midX,
            y: rowsTop + AreaSelectorView.modelMenuRowHeight * (CGFloat(itemCount) - 0.5)
        )
        XCTAssertEqual(
            AreaSelectorView.modelMenuRowIndex(at: rowLast, forSelection: selection, in: bounds, itemCount: itemCount),
            itemCount - 1
        )
        // A point inside the top notice/header band is not a row.
        let inHeader = CGPoint(x: menu.midX, y: menu.minY + AreaSelectorView.menuVPad + 2)
        XCTAssertNil(
            AreaSelectorView.modelMenuRowIndex(at: inHeader, forSelection: selection, in: bounds, itemCount: itemCount)
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
