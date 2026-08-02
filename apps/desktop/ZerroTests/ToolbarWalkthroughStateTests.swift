//
//  ToolbarWalkthroughStateTests.swift
//  ZerroTests
//
//  Mode-specific first-run toolbar walkthrough state and preference migration.
//

import XCTest
@testable import Zerro

@MainActor
final class ToolbarWalkthroughStateTests: XCTestCase {

    func testStepOrderAndModeSequences() {
        XCTAssertEqual(ToolbarWalkthroughStep.allCases, [.agent, .record])
        XCTAssertEqual(ToolbarWalkthroughStep.steps(isDevMode: false), [.record])
        XCTAssertEqual(ToolbarWalkthroughStep.steps(isDevMode: true), [.agent, .record])
    }

    func testAnalyticsNamesAndCopy() {
        XCTAssertEqual(ToolbarWalkthroughStep.agent.analyticsName, "agent")
        XCTAssertEqual(ToolbarWalkthroughStep.record.analyticsName, "record")
        for step in ToolbarWalkthroughStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.body.isEmpty)
        }
    }

    func testAskWalkthroughSkipsDevSettingsAndKeepsModeFixed() {
        let state = AreaSelectorState()
        state.startToolbarWalkthrough()
        XCTAssertEqual(state.toolbarWalkthroughStep, .record)
        XCTAssertEqual(state.toolbarWalkthroughCount, 1)
        XCTAssertFalse(state.isDevMode)
        state.advanceToolbarWalkthrough()
        XCTAssertNil(state.toolbarWalkthroughStep)
        XCTAssertFalse(state.isDevMode)
    }

    func testDevWalkthroughIncludesSettingsAndKeepsModeFixed() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: nil, agentName: "Claude Code", projectURL: nil)
        state.startToolbarWalkthrough()
        XCTAssertEqual(state.toolbarWalkthroughCount, 2)

        var visited: [ToolbarWalkthroughStep] = [.agent]
        while state.toolbarWalkthroughStep != .record {
            state.advanceToolbarWalkthrough()
            visited.append(state.toolbarWalkthroughStep!)
        }
        XCTAssertEqual(visited, [.agent, .record])
        XCTAssertTrue(state.isDevMode)
        state.endToolbarWalkthrough(completed: false)
        XCTAssertNil(state.toolbarWalkthroughStep)
        XCTAssertTrue(state.isDevMode)
    }

    func testBackClampsAtFirstStepAndReturnsToAgentInDevMode() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: nil, agentName: "Claude Code", projectURL: nil)
        state.startToolbarWalkthrough()
        state.toolbarWalkthroughBack()
        XCTAssertEqual(state.toolbarWalkthroughStep, .agent)
        state.advanceToolbarWalkthrough()
        XCTAssertEqual(state.toolbarWalkthroughStep, .record)
        state.toolbarWalkthroughBack()
        XCTAssertEqual(state.toolbarWalkthroughStep, .agent)
    }

    func testModeSpecificSeenFlagsDefaultPersistAndReset() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertFalse(prefs.askToolbarWalkthroughSeen)
        XCTAssertFalse(prefs.devToolbarWalkthroughSeen)

        prefs.askToolbarWalkthroughSeen = true
        prefs.devToolbarWalkthroughSeen = true
        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.askToolbarWalkthroughSeen)
        XCTAssertTrue(reloaded.devToolbarWalkthroughSeen)

        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.askToolbarWalkthroughSeen))
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.devToolbarWalkthroughSeen))
        reloaded.resetToDefaults()
        XCTAssertFalse(reloaded.askToolbarWalkthroughSeen)
        XCTAssertFalse(reloaded.devToolbarWalkthroughSeen)
    }

    func testLegacySeenFlagMigratesToBothModes() {
        let defaults = UserDefaults.ephemeralPreview()
        defaults.set(true, forKey: PreferencesStore.Keys.toolbarWalkthroughSeen)
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertTrue(prefs.askToolbarWalkthroughSeen)
        XCTAssertTrue(prefs.devToolbarWalkthroughSeen)
    }
}
