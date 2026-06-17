//
//  DevPromptSelectionTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, M5/M7) — regression guard for the Phase-1 gap where the
//  BYOK generation call site hard-coded `composed()` (= normal), so a Dev Mode
//  recording silently generated with the CLIPBOARD prompt instead of the
//  repo-scoped dev prompt. The generation path now reads `generationPromptMode`;
//  this pins that a Dev recording resolves to `.dev` and that the dev prompt is a
//  distinct Goal/Changes/Scope spec.
//

import XCTest
@testable import Zerro

@MainActor
final class DevPromptSelectionTests: XCTestCase {

    func testDevRecordingSelectsTheDevPromptMode() {
        let app = AppState()

        app.recordingIsDevMode = false
        XCTAssertEqual(app.generationPromptMode, .normal, "a normal recording uses the normal prompt")

        app.recordingIsDevMode = true
        XCTAssertEqual(app.generationPromptMode, .dev, "a Dev Mode recording MUST use the dev prompt (the Phase-1 gap)")
    }

    func testDevPromptIsTheRepoScopedSpecAndDiffersFromNormal() {
        let dev = PromptGenerationSystemPrompt.composed(mode: .dev)
        let normal = PromptGenerationSystemPrompt.composed(mode: .normal)

        XCTAssertNotEqual(dev, normal, "the dev prompt must be a distinct prompt, not the clipboard one")
        // The dev body shape (§6) — the agent_prompt the coding agent consumes.
        XCTAssertTrue(dev.contains("Goal:"), "dev prompt produces a Goal/Changes/Scope spec")
        XCTAssertTrue(dev.contains("Changes:"))
        XCTAssertTrue(dev.contains("Scope:"))
        XCTAssertTrue(dev.contains("agent_prompt"), "dev mode always attaches an agent_prompt artifact")
        // The normal prompt is NOT the repo-scoped dev spec.
        XCTAssertFalse(normal.contains("repo-scoped coding instruction"))
    }

    func testEndToEndSeamSelectsDevPromptForADevRecording() {
        let app = AppState()
        app.recordingIsDevMode = true
        // What the generation path actually composes for this recording.
        let selected = PromptGenerationSystemPrompt.composed(mode: app.generationPromptMode)
        XCTAssertEqual(selected, PromptGenerationSystemPrompt.composed(mode: .dev))
    }
}
