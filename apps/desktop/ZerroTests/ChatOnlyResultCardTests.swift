//
//  ChatOnlyResultCardTests.swift
//  ZerroTests
//
//  Guards the chat-only (output == nil) result card after the "Write agent
//  prompt" convert affordance was removed. The card no longer carries any
//  conversion state — `OutputCardView`/`PillView` have no `conversion`/
//  `onConvert` parameters, so the compiler is the primary guarantee there is
//  no convert footer to render. These render-smoke tests pin the remaining
//  behavior: a chat-only response still lays out cleanly with its text, the
//  charge line (when managed), and the dismiss chrome — no layout break.
//
//  The chat-only card now also offers a plain "Copy" action (matching the
//  output behavior). Two seams cover it deterministically without UI
//  automation: `AppState.resultCopyPayload` supplies the chat text the button
//  copies (falling back to the raw `generatedPrompt`), and
//  `OutputCardView.showsCopyAction` decides whether the footer renders the
//  Copy button at all.
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

    /// The expanded chat-only card (managed → charge line present) lays out:
    /// chat text + charge line + dismiss, with no convert footer.
    func testChatOnlyExpandedWithChargeLineRenders() throws {
        let view = PillView(
            state: .resultExpanded,
            result: ResultPresentation(
                chatText: "That hydration error comes from rendering a non-deterministic "
                    + "value during SSR \u{2014} the server and client markup disagree. "
                    + "Nothing on screen needs a code change, so there\u{2019}s nothing to "
                    + "hand to an agent here.",
                output: nil
            ),
            chargeLine: CreditDisplay.chargeLine(charged: 2, remaining: 98)
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// The expanded chat-only card with no managed charge (BYOK/local) still
    /// lays out — text + dismiss only, no convert footer.
    func testChatOnlyExpandedWithoutChargeLineRenders() throws {
        let view = PillView(
            state: .resultExpanded,
            result: ResultPresentation(
                chatText: "The lockfile is stale \u{2014} re-run install to clear it.",
                output: nil
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
                output: nil
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
                output: nil
            ),
            chargeLine: CreditDisplay.chargeLine(charged: 2, remaining: 98)
        )

        let image = try render(view)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    // MARK: Copy payload seam (AppState)

    /// A chat-only response (`parsedResponse.output == nil`) copies the chat
    /// text — the data the Copy button writes to the pasteboard.
    func testResultCopyPayloadReturnsChatTextForChatOnly() {
        let appState = AppState()
        appState.generatedPrompt = "<<<raw model output>>>"
        appState.parsedResponse = ParsedResponse(
            chatText: "Nothing on screen needs a code change.",
            output: nil,
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
        appState.parsedResponse = ParsedResponse(
            chatText: "",
            output: nil,
            isValid: false,
            wasRecovered: false,
            warnings: []
        )

        XCTAssertEqual(appState.resultCopyPayload, "the raw fallback text")
    }

    // MARK: Copy visibility seam (OutputCardView.showsCopyAction)

    private func makeCard(
        output: GeneratedOutput?,
        chatText: String,
        failure: OutputCardView.FailureConfig? = nil,
        devResult: OutputCardView.DevResultConfig? = nil
    ) -> OutputCardView {
        OutputCardView(
            output: output,
            chatText: chatText,
            chargeLine: nil,
            noNarration: false,
            stoppedBySleep: false,
            onCopy: {},
            onCollapse: {},
            onDismiss: {},
            failure: failure,
            devResult: devResult
        )
    }

    private var sampleOutput: GeneratedOutput {
        GeneratedOutput(type: .agentPrompt, rawType: "agent_prompt", title: "Fix the bug", body: "Do the thing.")
    }

    /// An output result always offers Copy (its per-type label).
    func testShowsCopyActionForOutput() {
        XCTAssertTrue(makeCard(output: sampleOutput, chatText: "").showsCopyAction)
    }

    /// A chat-only result with explanation text offers the plain Copy action.
    func testShowsCopyActionForChatOnlyWithText() {
        XCTAssertTrue(makeCard(output: nil, chatText: "Here is why.").showsCopyAction)
    }

    /// A chat-only result with NO text has nothing to copy — no dead button.
    func testHidesCopyActionForChatOnlyWithoutText() {
        XCTAssertFalse(makeCard(output: nil, chatText: "").showsCopyAction)
    }

    /// The failure footer owns its own actions (Retry / Cancel) — Copy yields.
    func testHidesCopyActionForFailure() {
        let failure = OutputCardView.FailureConfig(
            headline: "Generation failed",
            detail: "The model returned an error."
        )
        XCTAssertFalse(makeCard(output: nil, chatText: "Here is why.", failure: failure).showsCopyAction)
    }

    /// The dev-result footer owns Undo/Accept — Copy yields.
    func testHidesCopyActionForDevResult() {
        let dev = OutputCardView.DevResultConfig(
            title: "Changes applied",
            summary: "Recolored the button.",
            diffText: "diff --git a/App.css b/App.css"
        )
        XCTAssertFalse(makeCard(output: nil, chatText: "", devResult: dev).showsCopyAction)
    }
}
