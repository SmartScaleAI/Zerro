//
//  AreaSelectorTooSmallTests.swift
//  ZerroTests
//
//  "Selection too small" feedback — an area selection under
//  `minimumSelectionSize` on either axis flags `isSelectionTooSmall`
//  (red border + explanatory pill), and Return/Enter on such a
//  selection is refused VISIBLY (the pulse counter bumps, bouncing the
//  pill's icon) instead of silently no-oping. Pure state + the
//  controller's confirm gate; the rendered pill is eyeballed via the
//  snapshot harness / on hardware.
//

import AppKit
import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorTooSmallTests: XCTestCase {

    private let overlay = CGSize(width: 1728, height: 1117)

    /// Draw and settle a selection of `size` starting at (200, 200).
    private func settle(_ size: CGSize, in state: AreaSelectorState) {
        state.beginDrag(at: CGPoint(x: 200, y: 200))
        let end = CGPoint(x: 200 + size.width, y: 200 + size.height)
        state.updateDrag(to: end)
        state.endDrag(at: end)
    }

    // MARK: - Flag boundaries

    func testTooSmallBoundaries() {
        // Per-axis rule with a `>=` gate: 100 exactly is enough.
        let cases: [(CGSize, Bool)] = [
            (CGSize(width: 99, height: 200), true),
            (CGSize(width: 200, height: 99), true),
            (CGSize(width: 100, height: 100), false),
            (CGSize(width: 150, height: 150), false),
        ]
        for (size, expected) in cases {
            let state = AreaSelectorState()
            state.setOverlaySize(overlay)
            settle(size, in: state)
            XCTAssertEqual(state.isSelectionTooSmall, expected, "\(size)")
            // The flag is the inverse of the settled toolbar gate.
            XCTAssertEqual(state.confirmableSelectionRect == nil, expected, "\(size)")
        }
    }

    func testFalseWithoutASelectionAndInFullScreen() {
        let state = AreaSelectorState()
        state.setOverlaySize(overlay)
        XCTAssertFalse(state.isSelectionTooSmall, "no selection yet")

        state.enterFullScreenMode(overlaySize: overlay)
        XCTAssertFalse(state.isSelectionTooSmall, "full-screen is always confirmable")
    }

    func testFlagWaitsForTheDragToSettle() {
        let state = AreaSelectorState()
        state.setOverlaySize(overlay)
        // Quiet mid-drag even while undersized — every drag starts small, so
        // the red feedback would otherwise flash at the start of every
        // selection.
        state.beginDrag(at: CGPoint(x: 200, y: 200))
        state.updateDrag(to: CGPoint(x: 250, y: 250))
        XCTAssertTrue(state.isDragging)
        XCTAssertFalse(state.isSelectionTooSmall, "no red feedback while still dragging")

        // Releasing an undersized rect raises the flag.
        state.endDrag(at: CGPoint(x: 250, y: 250))
        XCTAssertTrue(state.isSelectionTooSmall, "red feedback appears on release")

        // A new drag lowers it again immediately, and settling large keeps
        // it down.
        state.beginDrag(at: CGPoint(x: 200, y: 200))
        XCTAssertFalse(state.isSelectionTooSmall, "starting a fresh drag clears the error")
        state.updateDrag(to: CGPoint(x: 350, y: 350))
        state.endDrag(at: CGPoint(x: 350, y: 350))
        XCTAssertFalse(state.isSelectionTooSmall)
    }

    // MARK: - Confirm gate (Return/Enter)

    func testReturnRefusesUndersizedSelectionVisibly() {
        let controller = AreaSelectorWindowController()
        let state = AreaSelectorState()
        state.setOverlaySize(overlay)
        var confirmed: SelectionRect?
        state.onConfirm = { confirmed = $0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false
        )

        // Wide but short (the 494×43 case): refused — onConfirm never fires —
        // and the refusal pulses the standing message instead of no-oping.
        settle(CGSize(width: 494, height: 43), in: state)
        controller.confirmCurrentSelection(window: window, state: state)
        XCTAssertNil(confirmed)
        XCTAssertEqual(state.undersizedConfirmPulse, 1)

        // A second Return keeps pulsing (each refusal is visible).
        controller.confirmCurrentSelection(window: window, state: state)
        XCTAssertEqual(state.undersizedConfirmPulse, 2)

        // Grown past the minimum on both axes: confirm goes through.
        settle(CGSize(width: 300, height: 200), in: state)
        controller.confirmCurrentSelection(window: window, state: state)
        XCTAssertNotNil(confirmed)
        XCTAssertEqual(state.undersizedConfirmPulse, 2, "no extra pulse on success")
    }

    // MARK: - Copy

    func testMessageCopyInterpolatesTheMinimum() {
        let m = Int(AreaSelectorState.minimumSelectionSize)
        XCTAssertTrue(AreaSelectorView.tooSmallMessageText.contains("\(m) \u{00D7} \(m)"),
                      "the pill copy must carry the real gate value")
    }
}
