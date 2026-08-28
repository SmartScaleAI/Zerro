//
//  ChatOnlyResultCardTests.swift
//  ZerroTests
//
//  Guards the chat-only (artifact == nil) result card after the "Write agent
//  prompt" convert affordance was removed. The card no longer carries any
//  conversion state — `OutputCardView`/`PillView` have no `conversion`/
//  `onConvert` parameters, so the compiler is the primary guarantee there is
//  no convert footer to render. These render-smoke tests pin the remaining
//  behavior: a chat-only response still lays out cleanly with its text and
//  the dismiss chrome — no layout break.
//
//  The card offers the two-tier copy model: the footer Copy copies the
//  whole response and the artifact well's corner icon copies the artifact
//  body alone. Three seams cover it deterministically without UI automation:
//  `AppState.resultFullCopyPayload` supplies the whole-response payload
//  (summary + artifact, snippet fenced), `AppState.resultCopyPayload` the
//  artifact-scope payload (both falling back to the raw `generatedPrompt`),
//  and `OutputCardView.showsCopyAction` decides whether the footer renders
//  the Copy button at all.
//

import AppKit
import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class ChatOnlyResultCardTests: XCTestCase {

    private func render(_ view: some View) throws -> NSImage {
        let wrapped = view.padding(40).background(Color.vfPanelBackground)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image")
    }

    /// The expanded chat-only card with a longer explanation lays out:
    /// chat text + dismiss, with no convert footer.
    func testChatOnlyExpandedLongTextRenders() throws {
        let view = PillView(
            state: .resultExpanded,
            result: ResultPresentation(
                chatText: "That hydration error comes from rendering a non-deterministic "
                    + "value during SSR \u{2014} the server and client markup disagree. "
                    + "Nothing on screen needs a code change, so there\u{2019}s nothing to "
                    + "hand to an agent here.",
                artifact: nil
            )
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// The expanded chat-only card with a short explanation still lays out —
    /// text + dismiss only, no convert footer.
    func testChatOnlyExpandedShortTextRenders() throws {
        let view = PillView(
            state: .resultExpanded,
            result: ResultPresentation(
                chatText: "The lockfile is stale \u{2014} re-run install to clear it.",
                artifact: nil
            )
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// The expanded artifact card lays out with the merged single scroll and
    /// both copy affordances: the corner icon on the artifact well and the
    /// Copy footer. A regression in either (or in the shared scroll
    /// wrapping summary + well) fails the render here.
    func testArtifactExpandedWithTwoTierCopyRenders() throws {
        let view = PillView(
            state: .resultExpanded,
            result: ResultPresentation(
                chatText: "Here is a prompt you can hand straight to your agent.",
                artifact: sampleArtifact
            )
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// The compact chat-only capsule (the collapsed result) also lays out.
    func testChatOnlyCompactRenders() throws {
        let view = PillView(
            state: .resultCompact,
            result: ResultPresentation(
                chatText: "The lockfile is stale \u{2014} re-run install to clear it.",
                artifact: nil
            )
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// The expanded chat-only card with copyable text guards the footer-with-
    /// Copy layout: a future regression that breaks the chat-only footer (e.g.
    /// dropping the Copy branch) fails the render here, alongside the
    /// `showsCopyAction` assertions below.
    func testChatOnlyExpandedWithCopyRenders() throws {
        let view = PillView(
            state: .resultExpanded,
            result: ResultPresentation(
                chatText: "That hydration error comes from rendering a non-deterministic "
                    + "value during SSR \u{2014} the server and client markup disagree.",
                artifact: nil
            )
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    // MARK: Copy payload seam (AppState)

    /// A chat-only response (`output.artifact == nil`) copies the chat
    /// text — the data the Copy button writes to the pasteboard.
    func testResultCopyPayloadReturnsChatTextForChatOnly() {
        let appState = AppState()
        appState.generatedPrompt = "<<<raw model output>>>"
        appState.output = Output(
            chatText: "Nothing on screen needs a code change.",
            artifact: nil,
            isValid: true,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(appState.resultCopyPayload, "Nothing on screen needs a code change.")
    }

    /// When the chat text is empty (the malformed fail-safe path), the payload
    /// falls back to the raw `generatedPrompt` — never nil/empty, so the button
    /// always has something to copy. This is exactly what the card's `chatText`
    /// prop mirrors upstream, so the footer never shows a dead Copy button.
    func testResultCopyPayloadFallsBackToGeneratedPromptWhenChatEmpty() {
        let appState = AppState()
        appState.generatedPrompt = "the raw fallback text"
        appState.output = Output(
            chatText: "",
            artifact: nil,
            isValid: false,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(appState.resultCopyPayload, "the raw fallback text")
    }

    // MARK: Full-copy payload seam (AppState.resultFullCopyPayload)

    /// The footer Copy with an artifact joins the summary and the artifact
    /// body with a blank line — the whole response in one paste.
    func testResultFullCopyPayloadJoinsSummaryAndArtifactBody() {
        let appState = AppState()
        appState.output = Output(
            chatText: "Here is a prompt for that refactor.",
            artifact: Artifact(
                type: .agentPrompt, rawType: "agent_prompt",
                title: "Fix the bug", body: "Do the thing."
            ),
            isValid: true,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(
            appState.resultFullCopyPayload,
            "Here is a prompt for that refactor.\n\nDo the thing."
        )
    }

    /// A `snippet` body is fenced as a markdown code block so it pastes as
    /// code into docs/Slack/editors; other types are appended raw (above).
    func testResultFullCopyPayloadFencesSnippetBody() {
        let appState = AppState()
        appState.output = Output(
            chatText: "This one-liner clears the cache.",
            artifact: Artifact(
                type: .snippet, rawType: "snippet",
                title: "Clear the cache", body: "rm -rf node_modules/.cache"
            ),
            isValid: true,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(
            appState.resultFullCopyPayload,
            "This one-liner clears the cache.\n\n```\nrm -rf node_modules/.cache\n```"
        )
    }

    /// An artifact with no summary copies the body alone — no leading blank
    /// line.
    func testResultFullCopyPayloadOmitsEmptySummary() {
        let appState = AppState()
        appState.output = Output(
            chatText: "  \n",
            artifact: Artifact(
                type: .document, rawType: "document",
                title: "Release note", body: "The full note text."
            ),
            isValid: true,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(appState.resultFullCopyPayload, "The full note text.")
    }

    /// A chat-only response copies the chat text — same as the artifact-scope
    /// payload, so the footer Copy never surprises on a plain answer.
    func testResultFullCopyPayloadReturnsChatTextForChatOnly() {
        let appState = AppState()
        appState.generatedPrompt = "<<<raw model output>>>"
        appState.output = Output(
            chatText: "Nothing on screen needs a code change.",
            artifact: nil,
            isValid: true,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(appState.resultFullCopyPayload, "Nothing on screen needs a code change.")
    }

    /// Empty chat + malformed parse falls back to the raw `generatedPrompt` —
    /// never nil/empty, mirroring `resultCopyPayload`.
    func testResultFullCopyPayloadFallsBackToGeneratedPromptWhenChatEmpty() {
        let appState = AppState()
        appState.generatedPrompt = "the raw fallback text"
        appState.output = Output(
            chatText: "",
            artifact: nil,
            isValid: false,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(appState.resultFullCopyPayload, "the raw fallback text")
    }

    // MARK: Copy visibility seam (OutputCardView.showsCopyAction)

    private func makeCard(
        artifact: Artifact?,
        chatText: String,
        failure: OutputCardView.FailureConfig? = nil,
        devResult: OutputCardView.DevResultConfig? = nil
    ) -> OutputCardView {
        OutputCardView(
            artifact: artifact,
            chatText: chatText,
            noNarration: false,
            stoppedBySleep: false,
            onCopy: {},
            onCollapse: {},
            onDismiss: {},
            failure: failure,
            devResult: devResult
        )
    }

    private var sampleArtifact: Artifact {
        Artifact(type: .agentPrompt, rawType: "agent_prompt", title: "Fix the bug", body: "Do the thing.")
    }

    /// An artifact result always offers Copy (its per-type label).
    func testShowsCopyActionForArtifact() {
        XCTAssertTrue(makeCard(artifact: sampleArtifact, chatText: "").showsCopyAction)
    }

    /// A chat-only result with explanation text offers the plain Copy action.
    func testShowsCopyActionForChatOnlyWithText() {
        XCTAssertTrue(makeCard(artifact: nil, chatText: "Here is why.").showsCopyAction)
    }

    /// A chat-only result with NO text has nothing to copy — no dead button.
    func testHidesCopyActionForChatOnlyWithoutText() {
        XCTAssertFalse(makeCard(artifact: nil, chatText: "").showsCopyAction)
    }

    /// The failure footer owns its own actions (Retry / Cancel) — Copy yields.
    func testHidesCopyActionForFailure() {
        let failure = OutputCardView.FailureConfig(
            headline: "Generation failed",
            detail: "The model returned an error."
        )
        XCTAssertFalse(makeCard(artifact: nil, chatText: "Here is why.", failure: failure).showsCopyAction)
    }

    /// The dev-result footer owns Undo/Accept — Copy yields.
    func testHidesCopyActionForDevResult() {
        let dev = OutputCardView.DevResultConfig(
            title: "Changes applied",
            summary: "Recolored the button.",
            diffText: "diff --git a/App.css b/App.css"
        )
        XCTAssertFalse(makeCard(artifact: nil, chatText: "", devResult: dev).showsCopyAction)
    }
}
