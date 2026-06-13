//
//  PillWindowFittingTests.swift
//  ZerroTests
//
//  Regression pin for the launch-QA "pill disappears after stop" bug.
//
//  During the .processing → .resultExpanded morph, NSHostingView.fittingSize
//  was observed to transiently report 0×0 (the SwiftUI tree hadn't committed
//  the morphed state when the controller forced layout). The window frame was
//  driven to that value, shrinking the pill into nothing — and because the
//  0×0 fit raced the settled-size re-fit, whichever landed LAST won: on the
//  unlucky ordering the pill stayed invisible with the state machine
//  healthily sitting at .done.
//
//  The fix gates every reposition on `isRenderableFitting`: a degenerate
//  fitting size is never applied — the window keeps its last good frame and
//  the content-size observation re-fits once layout settles. These tests pin
//  that gate. (The transient 0×0 itself is AppKit/SwiftUI layout timing and
//  is not reproducible in a unit test; the gate is the testable invariant.)
//

import XCTest
@testable import Zerro

final class PillWindowFittingTests: XCTestCase {

    func testDegenerateFittingSizesAreRejected() {
        XCTAssertFalse(PillWindowController.isRenderableFitting(.zero),
                       "0×0 is the observed mid-morph value — must never reach the window frame")
        XCTAssertFalse(PillWindowController.isRenderableFitting(CGSize(width: 760, height: 0)))
        XCTAssertFalse(PillWindowController.isRenderableFitting(CGSize(width: 0, height: 375)))
        XCTAssertFalse(PillWindowController.isRenderableFitting(CGSize(width: 0.5, height: 0.5)),
                       "sub-point sizes are layout noise, not a renderable pill")
    }

    func testRealPillSizesAreAccepted() {
        // The two real geometries the controller drives between: the locked
        // 392×50 capsule and the 760-wide expanded result (content-driven
        // height, 375 is the simulated-result measurement).
        XCTAssertTrue(PillWindowController.isRenderableFitting(CGSize(width: 392, height: 50)))
        XCTAssertTrue(PillWindowController.isRenderableFitting(CGSize(width: 760, height: 375)))
        // Smallest plausible content — still renderable, must not be gated.
        XCTAssertTrue(PillWindowController.isRenderableFitting(CGSize(width: 1, height: 1)))
    }
}
