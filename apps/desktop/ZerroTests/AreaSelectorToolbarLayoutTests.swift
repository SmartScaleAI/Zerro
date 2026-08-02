//
//  AreaSelectorToolbarLayoutTests.swift
//  ZerroTests
//
//  Ask Mode's compact overlay toolbar now contains only Record.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorToolbarLayoutTests: XCTestCase {
    private let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)

    private var toolbar: CGRect {
        AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds)
    }

    private var record: CGRect {
        AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds)
    }

    func testAskToolbarContainsOnlySymmetricallyInsetRecordButton() {
        XCTAssertEqual(record.width, AreaSelectorView.recordButtonWidth)
        XCTAssertTrue(toolbar.contains(record))
        XCTAssertEqual(record.minX - toolbar.minX, toolbar.maxX - record.maxX, accuracy: 0.001)
        XCTAssertEqual(record.midY, toolbar.midY, accuracy: 0.001)
        XCTAssertEqual(toolbar.width, AreaSelectorView.toolbarClusterWidth(), accuracy: 0.001)
    }

    func testToolbarScaleIsAppliedToMetrics() {
        let scale = AreaSelectorView.toolbarScale
        XCTAssertGreaterThanOrEqual(scale, 1.0)
        XCTAssertEqual(AreaSelectorView.toolbarHeight, 40 * scale, accuracy: 0.001)
        XCTAssertEqual(AreaSelectorView.recordButtonWidth, 118 * scale, accuracy: 0.001)
        XCTAssertEqual(AreaSelectorView.iconButtonWidth, 46 * scale, accuracy: 0.001)
        XCTAssertEqual(AreaSelectorView.scaled(14), 14 * scale, accuracy: 0.001)
    }

    func testToolbarCentersInComfortablyLargeSelection() {
        let big = CGRect(x: 200, y: 150, width: 900, height: 500)
        let frame = AreaSelectorView.toolbarFrame(forSelection: big, in: bounds)
        XCTAssertEqual(frame.midX, big.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, big.midY, accuracy: 0.001)
        XCTAssertTrue(big.contains(frame))
    }

    func testToolbarDropsBelowSelectionTooNarrowToCenter() {
        let narrow = CGRect(x: 400, y: 200, width: 120, height: 500)
        let frame = AreaSelectorView.toolbarFrame(forSelection: narrow, in: bounds)
        XCTAssertGreaterThanOrEqual(frame.minY, narrow.maxY)
        XCTAssertEqual(frame.midX, narrow.midX, accuracy: 0.001)
        XCTAssertFalse(narrow.contains(frame))
    }
}
