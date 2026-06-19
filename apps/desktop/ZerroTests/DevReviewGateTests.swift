//
//  DevReviewGateTests.swift
//  ZerroTests
//
//  Dev Mode — the Ask Permission review gate (the SOLE pre-edit checkpoint). Pins:
//   • `devPermissionMode` defaults `.autoApprove`, persists, is resettable, and
//     migrates the legacy `devReviewBeforeApply` Bool (true → .askPermission).
//   • `.autoApprove` ⇒ `awaitReviewApproval` returns true WITHOUT entering
//     `.reviewingPrompt` (the auto-apply path is byte-identical to before).
//   • `.askPermission` ⇒ enters `.reviewingPrompt`; Approve → dispatch proceeds;
//     Cancel → aborts to idle with the gate resolving false (the agent never runs).
//   • No confirmAnchors: a low-confidence anchor no longer pauses — it dispatches
//     under `.autoApprove`, or shows ONLY the review card under `.askPermission`.
//   • Teardown: a reset/quit while `.reviewingPrompt` resolves the continuation
//     false (no hang) and discards the checkpoint/marker.
//   • Bridge: `.reviewingPrompt` maps to `.reviewPrompt(agent:prompt:)`.
//

import XCTest
@testable import Zerro

@MainActor
final class DevReviewGateTests: XCTestCase {

    // MARK: - Preference

    func testPermissionModeDefaultsAutoApprovePersistsAndResets() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        // Default Auto Approve is the whole point — the headline auto-apply path is intact.
        XCTAssertEqual(prefs.devPermissionMode, .autoApprove, "permission mode defaults to Auto Approve")
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.devPermissionMode))

        prefs.devPermissionMode = .askPermission
        // Persists across stores over the same defaults.
        XCTAssertEqual(PreferencesStore(defaults: defaults).devPermissionMode, .askPermission, "the mode persists")

        prefs.resetToDefaults()
        XCTAssertEqual(prefs.devPermissionMode, .autoApprove, "reset restores default Auto Approve")
    }

    func testMigratesLegacyReviewBeforeApplyBool() {
        // A store that only ever wrote the old Bool (true) migrates to Ask Permission.
        let onDefaults = UserDefaults.ephemeralPreview()
        onDefaults.set(true, forKey: PreferencesStore.Keys.legacyDevReviewBeforeApply)
        XCTAssertEqual(PreferencesStore(defaults: onDefaults).devPermissionMode, .askPermission,
                       "legacy true → .askPermission")

        // The old Bool false → Auto Approve (the default behavior).
        let offDefaults = UserDefaults.ephemeralPreview()
        offDefaults.set(false, forKey: PreferencesStore.Keys.legacyDevReviewBeforeApply)
        XCTAssertEqual(PreferencesStore(defaults: offDefaults).devPermissionMode, .autoApprove,
                       "legacy false → .autoApprove")

        // The NEW key wins over a stale legacy Bool when both are present.
        let bothDefaults = UserDefaults.ephemeralPreview()
        bothDefaults.set(true, forKey: PreferencesStore.Keys.legacyDevReviewBeforeApply)
        bothDefaults.set(DevPermissionMode.autoApprove.rawValue, forKey: PreferencesStore.Keys.devPermissionMode)
        XCTAssertEqual(PreferencesStore(defaults: bothDefaults).devPermissionMode, .autoApprove,
                       "the explicit new value wins over the legacy Bool")
    }

    // MARK: - Auto Approve (no behavior change)

    func testAutoApproveReturnsTrueWithoutEnteringReview() async {
        let app = AppState()
        let prefs = PreferencesStore(defaults: .ephemeralPreview()) // .autoApprove by default
        app.preferences = prefs

        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed, "Auto Approve ⇒ instant pass")
        XCTAssertNotEqual(app.state, .reviewingPrompt, "Auto Approve must never enter the review state")
        XCTAssertTrue(app.devReviewPromptText.isEmpty, "Auto Approve must not stash the prompt")
        _ = prefs // keep the weakly-held store alive for the call
    }

    func testGateWithNilPreferencesReturnsTrue() async {
        // No preferences wired (the fail-safe path) ⇒ treated as Auto Approve.
        let app = AppState()
        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed)
        XCTAssertNotEqual(app.state, .reviewingPrompt)
    }

    // MARK: - Ask Permission

    func testAskPermissionEntersReviewThenApproveProceeds() async {
        let app = AppState()
        let prefs = askPrefs()
        app.preferences = prefs

        let task = Task { await app.awaitReviewApproval(gen: 0, prompt: "do X") }
        await settle { app.state == .reviewingPrompt }
        XCTAssertEqual(app.state, .reviewingPrompt, "Ask Permission ⇒ pauses on the review card")
        XCTAssertEqual(app.devReviewPromptText, "do X", "the exact prompt is shown")

        app.approveReviewAndProceed()
        let proceed = await task.value
        XCTAssertTrue(proceed, "Approve ⇒ the dispatch proceeds")
        // Approve gives immediate feedback by advancing to dispatching.
        XCTAssertEqual(app.state, .devAgentDispatching)
        _ = prefs // retain
    }

    func testAskPermissionCancelAbortsToIdle() async {
        let app = AppState()
        let prefs = askPrefs()
        app.preferences = prefs

        let task = Task { await app.awaitReviewApproval(gen: 0, prompt: "do X") }
        await settle { app.state == .reviewingPrompt }

        app.cancelReview()
        let proceed = await task.value
        XCTAssertFalse(proceed, "Cancel ⇒ the gate resolves false (no dispatch)")

        await settle { app.state == .idle }
        XCTAssertEqual(app.state, .idle, "Cancel aborts cleanly to idle")
        _ = prefs
    }

    func testApproveAndCancelAreNoOpsOutsideReviewState() {
        let app = AppState()
        app.state = .idle
        // Double-tap / stale-tap safety: neither resolver does anything unless the
        // review gate is actually showing.
        app.approveReviewAndProceed()
        app.cancelReview()
        XCTAssertEqual(app.state, .idle, "resolvers are no-ops outside .reviewingPrompt")
    }

    // MARK: - No confirmAnchors (a low-confidence anchor never pauses on its own)

    func testLowConfidenceAnchorUnderAutoApproveDoesNotPause() async {
        let app = AppState()
        let prefs = PreferencesStore(defaults: .ephemeralPreview()) // .autoApprove
        app.preferences = prefs
        // A low-confidence anchor used to force a separate confirm gate; it must
        // now resolve and dispatch with no pre-edit pause.
        app.devResolvedAnchors = [lowConfidenceAnchor()]

        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed, "Auto Approve ⇒ a low-confidence anchor still dispatches immediately")
        XCTAssertNotEqual(app.state, .reviewingPrompt, "no pre-edit pause under Auto Approve")
        _ = prefs
    }

    func testLowConfidenceAnchorUnderAskPermissionShowsOnlyReview() async {
        let app = AppState()
        let prefs = askPrefs()
        app.preferences = prefs
        app.devResolvedAnchors = [lowConfidenceAnchor()]

        // The review card is the SINGLE pre-edit checkpoint — even with a low
        // anchor, the dispatch lands directly on `.reviewingPrompt` (no separate
        // confirm state), and approving it dispatches.
        let task = Task { await app.awaitReviewApproval(gen: 0, prompt: "do X") }
        await settle { app.state == .reviewingPrompt }
        XCTAssertEqual(app.state, .reviewingPrompt, "the review card is the only pre-edit gate")

        app.approveReviewAndProceed()
        let proceed = await task.value
        XCTAssertTrue(proceed, "approving the single review gate ⇒ dispatch")
        _ = prefs
    }

    // MARK: - Teardown safety

    func testResetWhileReviewingResolvesFalseAndIdles() async {
        let app = AppState()
        let prefs = askPrefs()
        app.preferences = prefs
        app.recordingIsDevMode = true

        let task = Task { await app.awaitReviewApproval(gen: 0, prompt: "do X") }
        await settle { app.state == .reviewingPrompt }

        // A reset while suspended must unblock the gate (no hang) and idle.
        app.resetToIdle()
        let proceed = await task.value
        XCTAssertFalse(proceed, "reset resolves the gate false")
        await settle { app.state == .idle }
        XCTAssertEqual(app.state, .idle)
        _ = prefs
    }

    func testQuitAtReviewingPromptDiscardsAndLeavesNoMarker() {
        let app = AppState()
        app.devRecoveryStore = DevRecoveryStore(fileURL: makeTempFile())
        // Even if a marker somehow existed at the gate (approveReviewAndProceed
        // persists one before the dispatch flip), the .reviewingPrompt quit branch
        // discards the snapshot and clears it — no marker may survive pointing at
        // a discarded snapshot.
        app.devRecoveryStore.save(sampleMarker())
        app.state = .reviewingPrompt
        app.prepareForTermination()
        XCTAssertNil(app.devRecoveryStore.load(), "a .reviewingPrompt quit must leave no marker")
    }

    func testReviewingPromptCountsAsDevBusy() {
        let app = AppState()
        app.state = .reviewingPrompt
        XCTAssertTrue(app.isDevBusy, ".reviewingPrompt must read as dev-busy (hotkey flashes)")
    }

    // MARK: - Bridge

    func testBridgeMapsReviewingPromptToReviewPrompt() {
        let app = AppState()
        app.recordingAgentID = "claude-code"
        app.devReviewPromptText = "make the button teal"
        app.state = .reviewingPrompt

        guard case .reviewPrompt(let agent, let prompt)? = app.pillState else {
            return XCTFail("expected .reviewPrompt, got \(String(describing: app.pillState))")
        }
        XCTAssertFalse(agent.isEmpty, "the target agent name is surfaced")
        XCTAssertEqual(prompt, "make the button teal", "the exact prompt rides to the card")
    }

    // MARK: - Helpers

    private func askPrefs() -> PreferencesStore {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionMode = .askPermission
        return prefs
    }

    private func lowConfidenceAnchor() -> ResolvedDeixisAnchor {
        ResolvedDeixisAnchor(
            refIndex: 0,
            candidate: CandidateAnchor(
                phrase: "the header", phraseStart: 0, phraseEnd: 0, targetSeconds: 0,
                point: DeixisPoint(x: 0.5, y: 0.5), source: .dwell, dwellConfidence: 0.1
            ),
            ocrStrings: [],
            markedJPEGBase64: nil,
            clientConfidence: 0.1
        )
    }

    private func sampleMarker() -> DevRecoveryMarker {
        DevRecoveryMarker(
            projectPath: "/tmp/p", baseSha: "abc123", stashSha: nil,
            untrackedSnapshotPath: nil, untrackedRelativePaths: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), agentName: "Claude Code"
        )
    }

    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-review-marker-\(UUID().uuidString).json")
    }

    /// Spin the main actor until `condition` holds or a short budget elapses.
    private func settle(_ condition: () -> Bool, timeoutMs: Int = 1000) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
    }
}
