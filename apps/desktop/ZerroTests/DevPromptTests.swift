//
//  DevPromptTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 5) — the `mode:"dev"` system-prompt variant on
//  the BYOK path. Structural assertions (the dev prompt has no byte-mirror md
//  source; it stays in sync with the server's PROMPT_DEV by review). Also pins
//  that selecting a mode never disturbs the locked normal prompt.
//

import XCTest
@testable import Zerro

final class DevPromptTests: XCTestCase {

    func testNormalModeIsUnchangedByTheModeParameter() {
        // The no-arg and explicit-normal forms must both return the locked v2
        // prompt (byte-mirrored elsewhere) — Dev Mode must not perturb it.
        XCTAssertEqual(PromptGenerationSystemPrompt.composed(), PromptGenerationSystemPrompt.text)
        XCTAssertEqual(PromptGenerationSystemPrompt.composed(mode: .normal), PromptGenerationSystemPrompt.text)
    }

    func testDevModeSelectsTheDevPrompt() {
        let dev = PromptGenerationSystemPrompt.composed(mode: .dev)
        XCTAssertEqual(dev, PromptGenerationSystemPrompt.devText)
        XCTAssertNotEqual(dev, PromptGenerationSystemPrompt.text)
    }

    func testDevPromptCarriesTheRepoScopedContract() {
        let dev = PromptGenerationSystemPrompt.devText

        // Goal / Changes / Scope / user said body shape (design §6).
        XCTAssertTrue(dev.contains("Goal:"))
        XCTAssertTrue(dev.contains("Changes:"))
        XCTAssertTrue(dev.contains("Scope:"))
        XCTAssertTrue(dev.contains("user said:"))

        // Eyes/hands framing — the agent has the repo but not the recording.
        XCTAssertTrue(dev.contains("did NOT see the recording"))

        // Route context + runtime note + the CSS/quality constraints (§11 #1
        // failure mode) + anchor-by-visible-text.
        XCTAssertTrue(dev.contains("localhost"))
        XCTAssertTrue(dev.contains("hot reload"))
        XCTAssertTrue(dev.lowercased().contains("dark mode"))
        XCTAssertTrue(dev.contains("smallest change"))
        XCTAssertTrue(dev.contains("design token"))
        XCTAssertTrue(dev.contains("grepping"))

        // Still emits the agent_prompt artifact fence the client parser expects.
        XCTAssertTrue(dev.contains("type=\"agent_prompt\""))
        XCTAssertTrue(dev.contains("<<<ZERRO_ARTIFACT"))
        XCTAssertTrue(dev.contains("<<<END_ZERRO_ARTIFACT>>>"))
    }

    func testDevPromptCarriesTheDeixisAnchorContract() {
        // Phase 2 (M5/M7): the marked-reference input + the structured-anchor
        // return contract the client parses for the confirm gate.
        let dev = PromptGenerationSystemPrompt.devText
        XCTAssertTrue(dev.contains("DEIXIS REFERENCE"), "explains the crosshair-marked reference frames")
        XCTAssertTrue(dev.contains("zerro_anchors"), "asks for the structured anchor block")
        XCTAssertTrue(dev.contains("confidence"), "anchors carry the model's confidence (combined with the client's)")
        // The anchors block must stay OUTSIDE the artifact fence so ArtifactParser
        // doesn't swallow it and DevAnchorParser can read it.
        XCTAssertTrue(dev.contains("OUTSIDE"))
    }
}
