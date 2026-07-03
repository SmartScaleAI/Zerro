//
//  ToolbarWalkthroughStateTests.swift
//  ZerroTests
//
//  Phase 1 of the first-run toolbar walkthrough — the step model + state
//  machine in `AreaSelectorState` and the one-time seen flag in
//  `PreferencesStore`. Pins (mirroring OnboardingStepTests):
//    • step ORDER + count are a shipped contract (advance/back are rawValue
//      arithmetic; `analyticsName` is the funnel step id and must stay
//      constant across releases);
//    • the Dev Mode display borrow: the agent/record steps force `isDevMode`
//      ON for display, stepping back out drops it, and end (complete OR Esc)
//      restores the user's real pre-tour value — the model itself never
//      touches preferences (it holds no store, by design);
//    • Back clamps at the first step;
//    • the seen flag defaults false, persists, and is resettable.
//

import XCTest
@testable import Zerro

@MainActor
final class ToolbarWalkthroughStateTests: XCTestCase {

    // MARK: - Step model

    /// Toolbar order (left→right) is a shipped contract — advance/back are
    /// `rawValue ± 1`, so an out-of-order insert silently skips a control.
    func testStepOrderAndCount() {
        XCTAssertEqual(
            ToolbarWalkthroughStep.allCases,
            [.mode, .model, .mic, .agent, .record]
        )
    }

    /// Stable analytics ids — must never change once shipped.
    func testAnalyticsNames() {
        XCTAssertEqual(ToolbarWalkthroughStep.mode.analyticsName, "mode")
        XCTAssertEqual(ToolbarWalkthroughStep.model.analyticsName, "model")
        XCTAssertEqual(ToolbarWalkthroughStep.mic.analyticsName, "mic")
        XCTAssertEqual(ToolbarWalkthroughStep.agent.analyticsName, "agent")
        XCTAssertEqual(ToolbarWalkthroughStep.record.analyticsName, "record")
    }

    func testEveryStepHasCopy() {
        for step in ToolbarWalkthroughStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step.analyticsName) needs a title")
            XCTAssertFalse(step.body.isEmpty, "\(step.analyticsName) needs body copy")
        }
    }

    /// Only the agent + record steps borrow the Dev layout (the
    /// agent-settings icon exists only in Dev Mode).
    func testShowsDevControlsSplit() {
        XCTAssertFalse(ToolbarWalkthroughStep.mode.showsDevControls)
        XCTAssertFalse(ToolbarWalkthroughStep.model.showsDevControls)
        XCTAssertFalse(ToolbarWalkthroughStep.mic.showsDevControls)
        XCTAssertTrue(ToolbarWalkthroughStep.agent.showsDevControls)
        XCTAssertTrue(ToolbarWalkthroughStep.record.showsDevControls)
    }

    // MARK: - State machine

    func testStartEntersFirstStep() {
        let state = AreaSelectorState()
        XCTAssertNil(state.toolbarWalkthroughStep, "inactive before start")
        state.startToolbarWalkthrough()
        XCTAssertEqual(state.toolbarWalkthroughStep, .mode)
        XCTAssertFalse(state.isDevMode, "the first step teaches the Artifact layout")
    }

    /// The snapshot is taken at start: a dev-on user sees the Artifact layout
    /// on step 1 (display borrow), and end hands the real value back.
    func testStartSnapshotsPreWalkthroughDevValue() {
        let state = AreaSelectorState()
        state.setDevMode(true)
        state.startToolbarWalkthrough()
        XCTAssertFalse(state.isDevMode, "step 1 displays Artifact even for a dev-on user")
        state.endToolbarWalkthrough(completed: false)
        XCTAssertTrue(state.isDevMode, "end restores the value captured at start")
    }

    /// "Next" walks mode → model → mic → agent → record; "Got it" (advance
    /// from the last step) ends the tour.
    func testAdvanceWalksAllStepsThenEnds() {
        let state = AreaSelectorState()
        state.startToolbarWalkthrough()
        var visited: [ToolbarWalkthroughStep] = [state.toolbarWalkthroughStep!]
        for _ in 1..<ToolbarWalkthroughStep.allCases.count {
            state.advanceToolbarWalkthrough()
            visited.append(state.toolbarWalkthroughStep!)
        }
        XCTAssertEqual(visited, ToolbarWalkthroughStep.allCases)

        state.advanceToolbarWalkthrough()
        XCTAssertNil(state.toolbarWalkthroughStep, "advancing from .record ends the walkthrough")
        XCTAssertFalse(state.isDevMode, "completion restores the pre-tour (off) mode")
    }

    /// Stepping into the dev steps flips the display mode on; stepping back
    /// out flips it off — all without a controller in sight.
    func testDevStepsForceDevModeForDisplay() {
        let state = AreaSelectorState()
        state.startToolbarWalkthrough()   // .mode
        state.advanceToolbarWalkthrough() // .model
        state.advanceToolbarWalkthrough() // .mic
        XCTAssertFalse(state.isDevMode)
        state.advanceToolbarWalkthrough() // .agent
        XCTAssertEqual(state.toolbarWalkthroughStep, .agent)
        XCTAssertTrue(state.isDevMode, "the agent step needs the dev-settings icon on screen")
        state.advanceToolbarWalkthrough() // .record
        XCTAssertTrue(state.isDevMode, "record is taught in the Dev layout it just revealed")

        state.toolbarWalkthroughBack()    // .agent
        state.toolbarWalkthroughBack()    // .mic
        XCTAssertEqual(state.toolbarWalkthroughStep, .mic)
        XCTAssertFalse(state.isDevMode, "backing out of the dev steps drops the display borrow")
    }

    /// End from a dev-displayed step restores a dev-OFF user — for both the
    /// "Got it" completion and the Esc dismiss.
    func testEndRestoresDevOffUser() {
        for completed in [true, false] {
            let state = AreaSelectorState()
            state.startToolbarWalkthrough()
            state.advanceToolbarWalkthrough() // .model
            state.advanceToolbarWalkthrough() // .mic
            state.advanceToolbarWalkthrough() // .agent
            XCTAssertTrue(state.isDevMode)
            state.endToolbarWalkthrough(completed: completed)
            XCTAssertNil(state.toolbarWalkthroughStep)
            XCTAssertFalse(state.isDevMode, "end(completed: \(completed)) restores dev OFF")
        }
    }

    /// End from an Artifact-displayed step restores a dev-ON user — again for
    /// both completion and Esc dismiss.
    func testEndRestoresDevOnUser() {
        for completed in [true, false] {
            let state = AreaSelectorState()
            state.setDevMode(true)
            state.startToolbarWalkthrough() // .mode displays Artifact
            XCTAssertFalse(state.isDevMode)
            state.endToolbarWalkthrough(completed: completed)
            XCTAssertNil(state.toolbarWalkthroughStep)
            XCTAssertTrue(state.isDevMode, "end(completed: \(completed)) restores dev ON")
        }
    }

    /// Back clamps at the first step — never negative, never ends the tour.
    func testBackClampsAtFirstStep() {
        let state = AreaSelectorState()
        state.startToolbarWalkthrough()
        state.toolbarWalkthroughBack()
        XCTAssertEqual(state.toolbarWalkthroughStep, .mode, "back at the first step is a no-op")

        state.advanceToolbarWalkthrough() // .model
        state.toolbarWalkthroughBack()    // .mode
        state.toolbarWalkthroughBack()    // still .mode
        XCTAssertEqual(state.toolbarWalkthroughStep, .mode)
    }

    // MARK: - Seen flag (PreferencesStore)

    func testSeenFlagDefaultsFalse() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        XCTAssertFalse(prefs.toolbarWalkthroughSeen, "fresh install → walkthrough not yet seen")
    }

    func testSeenFlagPersistsAcrossStores() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        prefs.toolbarWalkthroughSeen = true
        XCTAssertTrue(
            PreferencesStore(defaults: defaults).toolbarWalkthroughSeen,
            "seen persists to a new store over the same defaults"
        )
    }

    func testSeenFlagResettable() {
        XCTAssertTrue(
            PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.toolbarWalkthroughSeen),
            "the key is wiped by Reset to Defaults (QA re-trigger path)"
        )

        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.toolbarWalkthroughSeen = true
        prefs.resetToDefaults()
        XCTAssertFalse(prefs.toolbarWalkthroughSeen, "reset re-arms the walkthrough")
    }
}
