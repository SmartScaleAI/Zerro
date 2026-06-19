//
//  ChatOnlyResultCardTests.swift
//  ZerroTests
//
//  Guards the chat-only (artifact == nil) result card after the "Write agent
//  prompt" convert affordance was removed. The card no longer carries any
//  conversion state — `ArtifactCardView`/`PillView` have no `conversion`/
//  `onConvert` parameters, so the compiler is the primary guarantee there is
//  no convert footer to render. These render-smoke tests pin the remaining
//  behavior: a chat-only response still lays out cleanly with its text, the
//  charge line (when managed), and the dismiss chrome — no layout break.
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
                artifact: nil
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
                artifact: nil
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
}
