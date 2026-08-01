//
//  ToolbarWalkthroughLayoutTests.swift
//  ZerroTests
//
//  Mode-specific walkthrough geometry for Record and Dev settings.
//

import XCTest
@testable import Zerro

@MainActor
final class ToolbarWalkthroughLayoutTests: XCTestCase {
    private let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)
    private var fullScreenSelection: CGRect { CGRect(origin: .zero, size: bounds) }
    private var margin: CGFloat { 8 * AreaSelectorView.toolbarScale }

    override func setUp() {
        super.setUp()
        AreaSelectorView.fullScreenBottomInset = 0
    }

    private func anchor(
        _ step: ToolbarWalkthroughStep,
        fullScreen: Bool = false,
        devMode: Bool
    ) -> CGRect {
        AreaSelectorView.walkthroughAnchorFrame(
            for: step,
            forSelection: fullScreen ? fullScreenSelection : selection,
            in: bounds,
            fullScreen: fullScreen,
            devMode: devMode
        )
    }

    private func callout(_ step: ToolbarWalkthroughStep, devMode: Bool) -> CGRect {
        AreaSelectorView.walkthroughCalloutFrame(
            for: step,
            forSelection: selection,
            in: bounds,
            fullScreen: false,
            devMode: devMode
        )
    }

    private func nextButton(_ step: ToolbarWalkthroughStep, devMode: Bool) -> CGRect {
        AreaSelectorView.walkthroughNextButtonFrame(
            for: step,
            forSelection: selection,
            in: bounds,
            fullScreen: false,
            devMode: devMode
        )
    }

    private func backButton(_ step: ToolbarWalkthroughStep, devMode: Bool) -> CGRect {
        AreaSelectorView.walkthroughBackButtonFrame(
            for: step,
            forSelection: selection,
            in: bounds,
            fullScreen: false,
            devMode: devMode
        )
    }

    private func hit(
        _ point: CGPoint,
        step: ToolbarWalkthroughStep,
        devMode: Bool
    ) -> AreaSelectorView.WalkthroughHit? {
        AreaSelectorView.walkthroughHit(
            at: point,
            for: step,
            forSelection: selection,
            in: bounds,
            fullScreen: false,
            devMode: devMode
        )
    }

    func testAnchorsReuseRenderedControlFrames() {
        XCTAssertEqual(
            anchor(.record, devMode: false),
            AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds)
        )
        XCTAssertEqual(
            anchor(.agent, devMode: true),
            AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        )
        XCTAssertEqual(
            anchor(.record, devMode: true),
            AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: true)
        )
    }

    func testFullScreenAnchorsReuseRenderedControlFrames() {
        XCTAssertEqual(
            anchor(.record, fullScreen: true, devMode: false),
            AreaSelectorView.recordButtonFrame(
                forSelection: fullScreenSelection,
                in: bounds,
                fullScreen: true
            )
        )
        XCTAssertEqual(
            anchor(.agent, fullScreen: true, devMode: true),
            AreaSelectorView.devSettingsIconFrame(
                forSelection: fullScreenSelection,
                in: bounds,
                fullScreen: true
            )
        )
    }

    func testModeSpecificFirstStepHasNoBackButton() {
        XCTAssertEqual(backButton(.record, devMode: false), .zero)
        XCTAssertEqual(backButton(.agent, devMode: true), .zero)
        XCTAssertGreaterThan(backButton(.record, devMode: true).width, 0)
    }

    func testCalloutsAndButtonsStayInsideBounds() {
        for (step, devMode) in [(ToolbarWalkthroughStep.record, false), (.agent, true), (.record, true)] {
            for frame in [callout(step, devMode: devMode), nextButton(step, devMode: devMode)] {
                XCTAssertGreaterThanOrEqual(frame.minX, margin - 0.001)
                XCTAssertLessThanOrEqual(frame.maxX, bounds.width - margin + 0.001)
                XCTAssertGreaterThanOrEqual(frame.minY, margin - 0.001)
                XCTAssertLessThanOrEqual(frame.maxY, bounds.height - margin + 0.001)
            }
        }
    }

    func testFooterButtonsRouteAndDoNotOverlap() {
        let next = nextButton(.record, devMode: true)
        let back = backButton(.record, devMode: true)
        let panel = callout(.record, devMode: true)
        XCTAssertTrue(panel.contains(next))
        XCTAssertTrue(panel.contains(back))
        XCTAssertFalse(next.intersects(back))
        XCTAssertEqual(hit(CGPoint(x: next.midX, y: next.midY), step: .record, devMode: true), .next)
        XCTAssertEqual(hit(CGPoint(x: back.midX, y: back.midY), step: .record, devMode: true), .back)
    }

    func testRecordControlIsInertUnderWalkthrough() {
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds)
        XCTAssertNil(
            hit(CGPoint(x: record.midX, y: record.midY), step: .record, devMode: false)
        )
    }
}
