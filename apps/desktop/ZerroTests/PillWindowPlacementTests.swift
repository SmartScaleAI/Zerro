//
//  PillWindowPlacementTests.swift
//  ZerroTests
//
//  H-07 — the pill must appear on the display the recording actually
//  targets, not unconditionally on NSScreen.main. The NSWindow placement
//  and the didChangeScreenParameters wiring are review-verified; the
//  testable invariant is the target-screen resolution rule, factored into
//  `PillWindowController.resolveTargetScreen`:
//
//    • recorded display present  → that screen (never main)
//    • recorded display gone     → main
//    • no recorded display known → main
//
//  The helper is generic over the screen type so these tests drive it with
//  a plain value type instead of constructing NSScreens (which can't be
//  faked in a unit test).
//

import XCTest
@testable import Zerro

final class PillWindowPlacementTests: XCTestCase {

    /// Stand-in for NSScreen: just an identity + a display ID.
    private struct FakeScreen: Equatable {
        let name: String
        let displayID: CGDirectDisplayID?
    }

    private let builtIn = FakeScreen(name: "built-in", displayID: 1)
    private let external = FakeScreen(name: "external", displayID: 42)

    private func resolve(
        recordedDisplayID: CGDirectDisplayID?,
        screens: [FakeScreen],
        main: FakeScreen?
    ) -> FakeScreen? {
        PillWindowController.resolveTargetScreen(
            recordedDisplayID: recordedDisplayID,
            screens: screens,
            displayID: { $0.displayID },
            main: main
        )
    }

    /// The core H-07 fix: recording on the external display must place the
    /// pill there even though main is the built-in.
    func testRecordedDisplayPresentWinsOverMain() {
        let target = resolve(
            recordedDisplayID: 42,
            screens: [builtIn, external],
            main: builtIn
        )
        XCTAssertEqual(target, external,
                       "The pill belongs on the recorded display, not on main")
    }

    /// Recorded display unplugged mid-lifecycle → fall back to main rather
    /// than returning nil (which would strand the pill at stale coordinates).
    func testRecordedDisplayGoneFallsBackToMain() {
        let target = resolve(
            recordedDisplayID: 42,
            screens: [builtIn],
            main: builtIn
        )
        XCTAssertEqual(target, builtIn)
    }

    /// No recording in flight (launch-time pills like the recovery offer)
    /// → the historical main-screen behavior.
    func testNilRecordedDisplayUsesMain() {
        let target = resolve(
            recordedDisplayID: nil,
            screens: [builtIn, external],
            main: builtIn
        )
        XCTAssertEqual(target, builtIn)
    }

    /// A screen whose deviceDescription carries no display ID must never
    /// match (mirrors RecordingSession's refuse-to-guess posture).
    func testNilScreenIDNeverMatches() {
        let anonymous = FakeScreen(name: "anonymous", displayID: nil)
        let target = resolve(
            recordedDisplayID: 42,
            screens: [anonymous, builtIn],
            main: builtIn
        )
        XCTAssertEqual(target, builtIn,
                       "A nil screen ID is not a wildcard — fall back to main")
    }

    /// Degenerate no-displays world: nothing to place on, resolve to nil so
    /// the caller keeps the last good frame instead of crashing.
    func testNoScreensResolvesNil() {
        XCTAssertNil(resolve(recordedDisplayID: 42, screens: [], main: nil))
    }
}
