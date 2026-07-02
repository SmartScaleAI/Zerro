//
//  ToolbarWalkthroughLayoutTests.swift
//  ZerroTests
//
//  First-run toolbar walkthrough — the Phase 2 geometry + Phase 3 routing.
//  Like the rest of the toolbar, none of the walkthrough chrome is a SwiftUI
//  layout: the spotlight, callout, and Back/Next buttons render at static
//  frames the controller's mouse monitor hit-tests against, so these pin:
//    • each step's anchor IS the matching control frame (no drift between
//      what the tour highlights and what the control renders at) — in the
//      layout the tour actually shows (Dev for agent/record);
//    • the callout + buttons stay inside the overlay (margin-clamped) in
//      both .area and .fullScreen;
//    • Back is absent (.zero) on the first step, present after;
//    • Next/Back are disjoint, and Next sits inside the callout panel;
//    • "Got it" (.record) measures a different Next width than "Next" —
//      the per-label measurement is real, not a fixed box;
//    • walkthroughHit routes a press to .next/.back and NOWHERE else —
//      toolbar controls are inert under the tour (the Phase 3 contract the
//      controller dispatches on).
//

import XCTest
@testable import Zerro

@MainActor
final class ToolbarWalkthroughLayoutTests: XCTestCase {

    /// A roomy selection in a roomy overlay — the toolbar centers inside the
    /// region, un-clamped, with space above it for the callout.
    private let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)
    /// In .fullScreen the whole overlay is the selection.
    private var fullScreenSelection: CGRect { CGRect(origin: .zero, size: bounds) }
    /// Mirrors the private `toolbarMargin` (8 * scale) the clamps use.
    private var margin: CGFloat { 8 * AreaSelectorView.toolbarScale }

    override func setUp() {
        super.setUp()
        // Both are shared mutable statics normally stashed by the controller /
        // view render — normalize them so the frames here are deterministic
        // regardless of what ran before in the (serial) suite.
        AreaSelectorView.fullScreenBottomInset = 0
        AreaSelectorView.modelButtonWidth = AreaSelectorView.measuredModelButtonWidth(forName: "Gemini 3.5 Flash")
    }

    /// The layout the tour shows for a step: Phase 1 forces Dev Mode ON
    /// (display-only) for the agent/record steps, Artifact otherwise.
    private func devMode(for step: ToolbarWalkthroughStep) -> Bool {
        step.showsDevControls
    }

    private func anchor(_ step: ToolbarWalkthroughStep, fullScreen: Bool = false) -> CGRect {
        AreaSelectorView.walkthroughAnchorFrame(
            for: step, forSelection: fullScreen ? fullScreenSelection : selection,
            in: bounds, fullScreen: fullScreen, devMode: devMode(for: step))
    }

    private func callout(_ step: ToolbarWalkthroughStep, fullScreen: Bool = false) -> CGRect {
        AreaSelectorView.walkthroughCalloutFrame(
            for: step, forSelection: fullScreen ? fullScreenSelection : selection,
            in: bounds, fullScreen: fullScreen, devMode: devMode(for: step))
    }

    private func nextButton(_ step: ToolbarWalkthroughStep, fullScreen: Bool = false) -> CGRect {
        AreaSelectorView.walkthroughNextButtonFrame(
            for: step, forSelection: fullScreen ? fullScreenSelection : selection,
            in: bounds, fullScreen: fullScreen, devMode: devMode(for: step))
    }

    private func backButton(_ step: ToolbarWalkthroughStep, fullScreen: Bool = false) -> CGRect {
        AreaSelectorView.walkthroughBackButtonFrame(
            for: step, forSelection: fullScreen ? fullScreenSelection : selection,
            in: bounds, fullScreen: fullScreen, devMode: devMode(for: step))
    }

    private func hit(_ point: CGPoint, _ step: ToolbarWalkthroughStep, fullScreen: Bool = false) -> AreaSelectorView.WalkthroughHit? {
        AreaSelectorView.walkthroughHit(
            at: point, for: step, forSelection: fullScreen ? fullScreenSelection : selection,
            in: bounds, fullScreen: fullScreen, devMode: devMode(for: step))
    }

    // MARK: - Anchors reuse the control frames verbatim

    func testAnchorsMatchControlFramesInAreaMode() {
        XCTAssertEqual(
            anchor(.mode),
            AreaSelectorView.devToggleFrame(forSelection: selection, in: bounds, fullScreen: false, devMode: false))
        XCTAssertEqual(
            anchor(.model),
            AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds, fullScreen: false, devMode: false))
        XCTAssertEqual(
            anchor(.mic),
            AreaSelectorView.micChipFrame(forSelection: selection, in: bounds, fullScreen: false, devMode: false))
        XCTAssertEqual(
            anchor(.agent),
            AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds, fullScreen: false))
        XCTAssertEqual(
            anchor(.record),
            AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, fullScreen: false, devMode: true))
    }

    func testAnchorsMatchControlFramesInFullScreen() {
        let rect = fullScreenSelection
        XCTAssertEqual(
            anchor(.mode, fullScreen: true),
            AreaSelectorView.devToggleFrame(forSelection: rect, in: bounds, fullScreen: true, devMode: false))
        XCTAssertEqual(
            anchor(.model, fullScreen: true),
            AreaSelectorView.modelChipFrame(forSelection: rect, in: bounds, fullScreen: true, devMode: false))
        XCTAssertEqual(
            anchor(.mic, fullScreen: true),
            AreaSelectorView.micChipFrame(forSelection: rect, in: bounds, fullScreen: true, devMode: false))
        XCTAssertEqual(
            anchor(.agent, fullScreen: true),
            AreaSelectorView.devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: true))
        XCTAssertEqual(
            anchor(.record, fullScreen: true),
            AreaSelectorView.recordButtonFrame(forSelection: rect, in: bounds, fullScreen: true, devMode: true))
    }

    // MARK: - Callout + buttons stay on screen

    private func assertInsideBounds(_ frame: CGRect, _ label: String) {
        XCTAssertGreaterThanOrEqual(frame.minX, margin - 0.001, "\(label) escapes the left margin")
        XCTAssertLessThanOrEqual(frame.maxX, bounds.width - margin + 0.001, "\(label) escapes the right margin")
        XCTAssertGreaterThanOrEqual(frame.minY, margin - 0.001, "\(label) escapes the top margin")
        XCTAssertLessThanOrEqual(frame.maxY, bounds.height - margin + 0.001, "\(label) escapes the bottom margin")
    }

    func testCalloutAndButtonsInsideBoundsEveryStepBothModes() {
        for fullScreen in [false, true] {
            for step in ToolbarWalkthroughStep.allCases {
                let mode = fullScreen ? "fullScreen" : "area"
                assertInsideBounds(callout(step, fullScreen: fullScreen), "callout(\(step.analyticsName), \(mode))")
                assertInsideBounds(nextButton(step, fullScreen: fullScreen), "next(\(step.analyticsName), \(mode))")
                if step != .mode {
                    assertInsideBounds(backButton(step, fullScreen: fullScreen), "back(\(step.analyticsName), \(mode))")
                }
            }
        }
    }

    // MARK: - Back button presence

    func testBackFrameZeroAtFirstStepOnly() {
        XCTAssertEqual(backButton(.mode), .zero, "Back is hidden on the first step")
        for step in ToolbarWalkthroughStep.allCases where step != .mode {
            let back = backButton(step)
            XCTAssertGreaterThan(back.width, 0, "\(step.analyticsName) shows Back")
            XCTAssertGreaterThan(back.height, 0, "\(step.analyticsName) shows Back")
        }
    }

    // MARK: - Footer button relationships

    func testNextInsidePanelAndDisjointFromBack() {
        for step in ToolbarWalkthroughStep.allCases {
            let panel = callout(step)
            let next = nextButton(step)
            XCTAssertTrue(panel.contains(next), "\(step.analyticsName): Next sits inside the callout panel")
            if step != .mode {
                let back = backButton(step)
                XCTAssertTrue(panel.contains(back), "\(step.analyticsName): Back sits inside the callout panel")
                XCTAssertFalse(next.intersects(back), "\(step.analyticsName): Back/Next overlap")
            }
        }
    }

    /// ".record" renders "Got it" — a different label measurement than
    /// "Next". Pins that the button width tracks its label rather than a
    /// fixed box (the hit rect must match the drawn capsule exactly).
    func testGotItMeasuresDifferentWidthThanNext() {
        let next = nextButton(.model).width
        let gotIt = nextButton(.record).width
        XCTAssertGreaterThan(abs(gotIt - next), 1, "'Got it' and 'Next' must measure differently")
    }

    // MARK: - walkthroughHit routing (the Phase 3 dispatch contract)

    func testHitRoutesNextAndBackCenters() {
        for fullScreen in [false, true] {
            for step in ToolbarWalkthroughStep.allCases {
                let next = nextButton(step, fullScreen: fullScreen)
                XCTAssertEqual(
                    hit(CGPoint(x: next.midX, y: next.midY), step, fullScreen: fullScreen),
                    .next, "\(step.analyticsName): Next center routes to .next")
                if step != .mode {
                    let back = backButton(step, fullScreen: fullScreen)
                    XCTAssertEqual(
                        hit(CGPoint(x: back.midX, y: back.midY), step, fullScreen: fullScreen),
                        .back, "\(step.analyticsName): Back center routes to .back")
                }
            }
        }
    }

    /// On the first step Back is hidden: a press where Back WOULD render
    /// (bottom-left of the content inset) must be inert, not a phantom .back.
    func testHitIgnoresHiddenBackOnFirstStep() {
        let panel = callout(.mode)
        let whereBackWouldBe = CGPoint(
            x: panel.minX + AreaSelectorView.walkthroughCalloutPad + 4,
            y: panel.maxY - AreaSelectorView.walkthroughCalloutPad - AreaSelectorView.walkthroughButtonHeight / 2
        )
        XCTAssertNil(hit(whereBackWouldBe, .mode), "no phantom Back on the first step")
    }

    /// Toolbar controls are inert while the tour runs: a press dead-center on
    /// a control (even the spotlighted one) is NOT a callout button, so the
    /// helper returns nil and the controller consumes the click.
    func testHitReturnsNilOnToolbarControls() {
        // The spotlighted Record pill on the record step.
        let record = AreaSelectorView.recordButtonFrame(
            forSelection: selection, in: bounds, fullScreen: false, devMode: true)
        XCTAssertNil(
            hit(CGPoint(x: record.midX, y: record.midY), .record),
            "Record must not fire under the tour")
        // The spotlighted model chip on the model step.
        let model = AreaSelectorView.modelChipFrame(
            forSelection: selection, in: bounds, fullScreen: false, devMode: false)
        XCTAssertNil(
            hit(CGPoint(x: model.midX, y: model.midY), .model),
            "the model chip must not open its menu under the tour")
        // And a random point in the dimmed capture area.
        XCTAssertNil(hit(CGPoint(x: 40, y: 40), .mic), "dimmed area is inert")
    }
}
