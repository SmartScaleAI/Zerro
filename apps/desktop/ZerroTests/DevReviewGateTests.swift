//
//  DevReviewGateTests.swift
//  ZerroTests
//
//  Dev Mode — the Ask Permission review gate (the SOLE pre-edit checkpoint). Pins:
//   • `devPermissionTier` defaults `.askPermission` for everyone, persists, is
//     resettable, and migrates the old two-tier `devPermissionMode` raw value
//     (askPermission/autoApprove 1:1) + the legacy `devReviewBeforeApply` Bool.
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

    func testPermissionTierDefaultsAskPermissionPersistsAndResets() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        // §4: fresh install starts on Ask Permission for EVERYONE (the safe,
        // fenced, review-gated tier).
        XCTAssertEqual(prefs.devPermissionTier, .askPermission, "permission tier defaults to Ask Permission")
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.devPermissionTier))

        // The last-used tier is remembered (persists across stores over the same defaults).
        prefs.devPermissionTier = .unrestricted
        XCTAssertEqual(PreferencesStore(defaults: defaults).devPermissionTier, .unrestricted, "the tier persists")

        prefs.resetToDefaults()
        XCTAssertEqual(prefs.devPermissionTier, .askPermission, "reset restores default Ask Permission")
    }

    func testMigratesLegacyPermissionModeAndReviewBool() {
        // The old two-tier `devPermissionMode` raw values map 1:1 onto the new tier.
        let askDefaults = UserDefaults.ephemeralPreview()
        askDefaults.set("askPermission", forKey: PreferencesStore.Keys.legacyDevPermissionMode)
        XCTAssertEqual(PreferencesStore(defaults: askDefaults).devPermissionTier, .askPermission,
                       "legacy mode askPermission → .askPermission")

        let autoDefaults = UserDefaults.ephemeralPreview()
        autoDefaults.set("autoApprove", forKey: PreferencesStore.Keys.legacyDevPermissionMode)
        XCTAssertEqual(PreferencesStore(defaults: autoDefaults).devPermissionTier, .autoApprove,
                       "legacy mode autoApprove → .autoApprove (preserved, not reset to the new default)")

        // The even-older review-before-apply Bool: true → Ask Permission, false → Auto-Approve.
        let onDefaults = UserDefaults.ephemeralPreview()
        onDefaults.set(true, forKey: PreferencesStore.Keys.legacyDevReviewBeforeApply)
        XCTAssertEqual(PreferencesStore(defaults: onDefaults).devPermissionTier, .askPermission,
                       "legacy bool true → .askPermission")

        let offDefaults = UserDefaults.ephemeralPreview()
        offDefaults.set(false, forKey: PreferencesStore.Keys.legacyDevReviewBeforeApply)
        XCTAssertEqual(PreferencesStore(defaults: offDefaults).devPermissionTier, .autoApprove,
                       "legacy bool false → .autoApprove")

        // The NEW tier key wins over BOTH legacy keys when present.
        let bothDefaults = UserDefaults.ephemeralPreview()
        bothDefaults.set(true, forKey: PreferencesStore.Keys.legacyDevReviewBeforeApply)
        bothDefaults.set("autoApprove", forKey: PreferencesStore.Keys.legacyDevPermissionMode)
        bothDefaults.set(DevPermissionTier.unrestricted.rawValue, forKey: PreferencesStore.Keys.devPermissionTier)
        XCTAssertEqual(PreferencesStore(defaults: bothDefaults).devPermissionTier, .unrestricted,
                       "the explicit new tier wins over the legacy keys")
    }

    // MARK: - Auto Approve (no behavior change)

    func testAutoApproveReturnsTrueWithoutEnteringReview() async {
        let app = AppState()
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionTier = .autoApprove
        app.preferences = prefs

        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed, "Auto Approve ⇒ instant pass")
        XCTAssertNotEqual(app.state, .reviewingPrompt, "Auto Approve must never enter the review state")
        XCTAssertTrue(app.devReviewPromptText.isEmpty, "Auto Approve must not stash the prompt")
        _ = prefs // keep the weakly-held store alive for the call
    }

    func testUnrestrictedReturnsTrueWithoutEnteringReview() async {
        // Unrestricted skips the review gate too (only Ask Permission reviews).
        let app = AppState()
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionTier = .unrestricted
        app.preferences = prefs

        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed, "Unrestricted ⇒ instant pass")
        XCTAssertNotEqual(app.state, .reviewingPrompt, "Unrestricted must never enter the review state")
        _ = prefs
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
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devPermissionTier = .autoApprove
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
        prefs.devPermissionTier = .askPermission
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
