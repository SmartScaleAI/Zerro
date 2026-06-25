//
//  DevUnrestrictedWarningTests.swift
//  ZerroTests
//
//  Dev Mode — the §7 Unrestricted record-time warning. Pins the pure decision
//  logic (shown only for `.unrestricted` && !suppressed; suppress only on
//  Proceed+checkbox), the new preference (default false, persists, resettable),
//  and the record-time gate wiring in `startRecording` (Cancel aborts with the
//  recording never starting; the warning fires EVERY record until suppressed).
//

import XCTest
@testable import Zerro

@MainActor
final class DevUnrestrictedWarningTests: XCTestCase {

    // MARK: - shouldShow (pure)

    func testShowsForUnrestrictedWhenNotSuppressed() {
        XCTAssertTrue(DevUnrestrictedWarning.shouldShow(tier: .unrestricted, suppressed: false))
    }

    func testDoesNotShowWhenSuppressed() {
        XCTAssertFalse(DevUnrestrictedWarning.shouldShow(tier: .unrestricted, suppressed: true))
    }

    func testDoesNotShowForFencedTiers() {
        // The fenced tiers keep the agent inside the project — never warn.
        XCTAssertFalse(DevUnrestrictedWarning.shouldShow(tier: .askPermission, suppressed: false))
        XCTAssertFalse(DevUnrestrictedWarning.shouldShow(tier: .autoApprove, suppressed: false))
        // …even if the flag somehow got set.
        XCTAssertFalse(DevUnrestrictedWarning.shouldShow(tier: .askPermission, suppressed: true))
    }

    // MARK: - shouldSuppressAfter (pure)

    func testSuppressOnlyWhenProceedWithCheckbox() {
        XCTAssertTrue(DevUnrestrictedWarning.shouldSuppressAfter(
            .init(proceed: true, dontShowAgain: true)), "Proceed + checkbox ⇒ suppress")
        XCTAssertFalse(DevUnrestrictedWarning.shouldSuppressAfter(
            .init(proceed: true, dontShowAgain: false)), "Proceed without checkbox ⇒ keep showing")
        XCTAssertFalse(DevUnrestrictedWarning.shouldSuppressAfter(
            .init(proceed: false, dontShowAgain: true)), "Cancel ⇒ a checked box is ignored")
        XCTAssertFalse(DevUnrestrictedWarning.shouldSuppressAfter(.cancel))
    }

    // MARK: - Preference (default / persist / reset)

    func testSuppressionFlagDefaultsFalsePersistsAndResets() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertFalse(prefs.devUnrestrictedWarningSuppressed, "defaults false — warns until suppressed")
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(
            PreferencesStore.Keys.devUnrestrictedWarningSuppressed), "must be wiped by Reset to Defaults")

        prefs.devUnrestrictedWarningSuppressed = true
        XCTAssertTrue(PreferencesStore(defaults: defaults).devUnrestrictedWarningSuppressed,
                      "the flag persists across stores over the same defaults")

        prefs.resetToDefaults()
        XCTAssertFalse(prefs.devUnrestrictedWarningSuppressed, "reset restores the default (warns again)")
    }

    // MARK: - Gate flag-application wiring (no recording started)

    func testApplyDecisionProceedWithCheckboxSetsFlagAndProceeds() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        let app = AppState(); app.preferences = prefs
        let proceed = app.applyUnrestrictedWarningDecision(.init(proceed: true, dontShowAgain: true))
        XCTAssertTrue(proceed)
        XCTAssertTrue(prefs.devUnrestrictedWarningSuppressed)
        _ = prefs
    }

    func testApplyDecisionProceedWithoutCheckboxDoesNotSetFlag() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        let app = AppState(); app.preferences = prefs
        let proceed = app.applyUnrestrictedWarningDecision(.init(proceed: true, dontShowAgain: false))
        XCTAssertTrue(proceed)
        XCTAssertFalse(prefs.devUnrestrictedWarningSuppressed, "Proceed-without-checkbox must not suppress")
        _ = prefs
    }

    func testApplyDecisionCancelNeverSetsFlagEvenWithCheckbox() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        let app = AppState(); app.preferences = prefs
        let proceed = app.applyUnrestrictedWarningDecision(.init(proceed: false, dontShowAgain: true))
        XCTAssertFalse(proceed)
        XCTAssertFalse(prefs.devUnrestrictedWarningSuppressed, "Cancel must never suppress")
        _ = prefs
    }

    // MARK: - Record-time gate in startRecording (Cancel path is recording-free)

    func testCancelAbortsRecordingForUnrestrictedDevRun() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionTier = .unrestricted
        let app = AppState(); app.preferences = prefs
        var shown = 0
        app.presentUnrestrictedWarning = { shown += 1; return .cancel }

        app.startRecording(devMode: DevModeSelection(
            agentID: DevAgentRegistry.claudeCodeID, projectURL: URL(fileURLWithPath: "/tmp")))

        XCTAssertEqual(shown, 1, "an Unrestricted dev record shows the warning")
        XCTAssertEqual(app.state, .idle, "Cancel ⇒ the recording does not start")
        XCTAssertFalse(app.recordingIsDevMode, "no recording state was set on Cancel")
        XCTAssertFalse(prefs.devUnrestrictedWarningSuppressed, "Cancel never suppresses")
        _ = prefs
    }

    func testWarningFiresEveryRecordUntilSuppressed() {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionTier = .unrestricted
        let app = AppState(); app.preferences = prefs
        var shown = 0
        app.presentUnrestrictedWarning = { shown += 1; return .cancel }
        let dev = DevModeSelection(agentID: DevAgentRegistry.claudeCodeID, projectURL: URL(fileURLWithPath: "/tmp"))

        app.startRecording(devMode: dev)
        app.startRecording(devMode: dev)
        XCTAssertEqual(shown, 2, "the warning re-fires every record — there is no once-only state")
        _ = prefs
    }

    func testSuppressedUnrestrictedRunDoesNotShowWarning() {
        // Once suppressed, the gate is skipped. (We can't let startRecording proceed
        // into a real RecordingSession, so assert via the pure decision the gate uses.)
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionTier = .unrestricted
        prefs.devUnrestrictedWarningSuppressed = true
        XCTAssertFalse(DevUnrestrictedWarning.shouldShow(
            tier: prefs.devPermissionTier, suppressed: prefs.devUnrestrictedWarningSuppressed))
        _ = prefs
    }
}
