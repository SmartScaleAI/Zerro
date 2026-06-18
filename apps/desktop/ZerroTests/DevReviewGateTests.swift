//
//  DevReviewGateTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 4) — the opt-in review-before-apply gate. Pins:
//   • Pref defaults OFF, persists, and is resettable.
//   • OFF ⇒ `awaitReviewApproval` returns true WITHOUT entering `.reviewingPrompt`
//     (the auto-apply path is byte-identical to before).
//   • ON ⇒ enters `.reviewingPrompt`; Approve → dispatch proceeds; Cancel → aborts
//     to idle with the gate resolving false (the agent never runs).
//   • Composition: confirmAnchors resolves FIRST, then reviewingPrompt; approving
//     both dispatches; cancelling review aborts.
//   • Teardown: a reset/quit while `.reviewingPrompt` resolves the continuation
//     false (no hang) and discards the checkpoint/marker.
//   • Bridge: `.reviewingPrompt` maps to `.reviewPrompt(agent:targets:prompt:)`.
//

import XCTest
@testable import Zerro

@MainActor
final class DevReviewGateTests: XCTestCase {

    // MARK: - Preference

    func testReviewBeforeApplyDefaultsOffPersistsAndResets() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        // Default OFF is the whole point — the headline auto-apply path is intact.
        XCTAssertFalse(prefs.devReviewBeforeApply, "review-before-apply defaults OFF")
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.devReviewBeforeApply))

        prefs.devReviewBeforeApply = true
        // Persists across stores over the same defaults.
        XCTAssertTrue(PreferencesStore(defaults: defaults).devReviewBeforeApply, "the toggle persists")

        prefs.resetToDefaults()
        XCTAssertFalse(prefs.devReviewBeforeApply, "reset restores default OFF")
    }

    // MARK: - Gate OFF (no behavior change)

    func testGateOffReturnsTrueWithoutEnteringReview() async {
        let app = AppState()
        let prefs = PreferencesStore(defaults: .ephemeralPreview()) // OFF by default
        app.preferences = prefs

        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed, "OFF ⇒ instant pass")
        XCTAssertNotEqual(app.state, .reviewingPrompt, "OFF must never enter the review state")
        XCTAssertTrue(app.devReviewPromptText.isEmpty, "OFF must not stash the prompt")
        _ = prefs // keep the weakly-held store alive for the call
    }

    func testGateWithNilPreferencesReturnsTrue() async {
        // No preferences wired (the fail-safe path) ⇒ treated as OFF.
        let app = AppState()
        let proceed = await app.awaitReviewApproval(gen: 0, prompt: "do X")
        XCTAssertTrue(proceed)
        XCTAssertNotEqual(app.state, .reviewingPrompt)
    }

    // MARK: - Gate ON

    func testGateOnEntersReviewThenApproveProceeds() async {
        let app = AppState()
        let prefs = onPrefs()
        app.preferences = prefs

        let task = Task { await app.awaitReviewApproval(gen: 0, prompt: "do X") }
        await settle { app.state == .reviewingPrompt }
        XCTAssertEqual(app.state, .reviewingPrompt, "ON ⇒ pauses on the review card")
        XCTAssertEqual(app.devReviewPromptText, "do X", "the exact prompt is shown")

        app.approveReviewAndProceed()
        let proceed = await task.value
        XCTAssertTrue(proceed, "Approve ⇒ the dispatch proceeds")
        // Approve gives immediate feedback by advancing to dispatching.
        XCTAssertEqual(app.state, .devAgentDispatching)
        _ = prefs // retain
    }

    func testGateOnCancelAbortsToIdle() async {
        let app = AppState()
        let prefs = onPrefs()
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

    // MARK: - Composition with confirmAnchors

    func testCompositionAnchorsResolveFirstThenReview() async {
        let app = AppState()
        let prefs = onPrefs()
        app.preferences = prefs
        // A low-confidence anchor forces the confirmAnchors gate.
        app.devResolvedAnchors = [lowConfidenceAnchor()]

        // Replicate the dispatch's composed confirmGate: anchors FIRST, then review.
        let task = Task { () -> Bool in
            guard await app.awaitAnchorConfirmation(gen: 0) else { return false }
            return await app.awaitReviewApproval(gen: 0, prompt: "do X")
        }

        await settle { app.state == .confirmAnchors }
        XCTAssertEqual(app.state, .confirmAnchors, "anchors resolve first")

        app.confirmAnchorsAndProceed()
        await settle { app.state == .reviewingPrompt }
        XCTAssertEqual(app.state, .reviewingPrompt, "then the review gate")

        app.approveReviewAndProceed()
        let proceed = await task.value
        XCTAssertTrue(proceed, "approving both ⇒ dispatch")
        _ = prefs
    }

    func testCompositionCancellingReviewAborts() async {
        let app = AppState()
        let prefs = onPrefs()
        app.preferences = prefs
        app.devResolvedAnchors = [lowConfidenceAnchor()]

        let task = Task { () -> Bool in
            guard await app.awaitAnchorConfirmation(gen: 0) else { return false }
            return await app.awaitReviewApproval(gen: 0, prompt: "do X")
        }

        await settle { app.state == .confirmAnchors }
        app.confirmAnchorsAndProceed()
        await settle { app.state == .reviewingPrompt }

        app.cancelReview()
        let proceed = await task.value
        XCTAssertFalse(proceed, "cancelling review ⇒ abort")
        await settle { app.state == .idle }
        XCTAssertEqual(app.state, .idle)
        _ = prefs
    }

    // MARK: - Teardown safety

    func testResetWhileReviewingResolvesFalseAndIdles() async {
        let app = AppState()
        let prefs = onPrefs()
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
        // Even if a marker somehow existed at the gate (it can, when
        // confirmAnchorsAndProceed ran first), the .reviewingPrompt quit branch
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

        guard case .reviewPrompt(let agent, _, let prompt)? = app.pillState else {
            return XCTFail("expected .reviewPrompt, got \(String(describing: app.pillState))")
        }
        XCTAssertFalse(agent.isEmpty, "the target agent name is surfaced")
        XCTAssertEqual(prompt, "make the button teal", "the exact prompt rides to the card")
    }

    // MARK: - Helpers

    private func onPrefs() -> PreferencesStore {
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.devReviewBeforeApply = true
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
