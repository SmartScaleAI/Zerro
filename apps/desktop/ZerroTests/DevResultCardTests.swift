//
//  DevResultCardTests.swift
//  ZerroTests
//
//  The `.devDone` result card for a LOCAL Dev Mode run — the only kind
//  there is: Dev Mode always runs on the local/BYOK pipeline, so a dev
//  result carries no billing state at all. Pins the bridge mapping
//  (summary / readable diff / diff-stat counts) and a render smoke test of
//  the expanded card (title + summary + Undo/Accept footer, no charge
//  readout anywhere in the model).
//

import AppKit
import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class DevResultCardTests: XCTestCase {

    /// Stand up a finished Dev Mode run (the `.devDone` tail): an agent summary,
    /// a readable diff, and a diff stat.
    private func makeDevDoneState() -> AppState {
        let appState = AppState()
        appState.devSummary = "Recolored the primary button and tightened the header."
        appState.devDiffText = """
        diff --git a/App.css b/App.css
        @@ -1,3 +1,3 @@
        -  color: red;
        +  color: blue;
        """
        appState.devDiffStat = GitDiffStat(filesChanged: 1, added: 3, removed: 2)
        appState.state = .devDone
        return appState
    }

    // MARK: Bridge mapping

    /// The `.devDone` card maps the agent summary, diff text, and stat counts
    /// straight through the bridge.
    func testDevDoneMapsSummaryDiffAndStats() {
        let appState = makeDevDoneState()

        guard case .devDone(let card, _) = appState.pillState else {
            return XCTFail("`.devDone` must map to the `.devDone` card, got \(String(describing: appState.pillState))")
        }
        XCTAssertEqual(card.title, "Changes applied")
        XCTAssertEqual(card.summary, "Recolored the primary button and tightened the header.")
        XCTAssertTrue(card.diffText.contains("color: blue"))
        XCTAssertEqual(card.linesAdded, 3)
        XCTAssertEqual(card.linesRemoved, 2)
        XCTAssertEqual(card.filesChanged, 1)
    }

    // MARK: Render smoke

    /// The expanded local dev result lays out: the footer is the Undo/Accept
    /// pair with no billing readout (there is none to show — the card model
    /// carries no charge state).
    func testExpandedDevResultRenders() throws {
        let view = PillView(state: .devDone(
            card: DevResultCard(
                title: "Changes applied",
                summary: "Renamed a file.",
                diffText: "",
                linesAdded: 0, linesRemoved: 0, filesChanged: 1
            ),
            expanded: true
        ))
        .padding(40)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let nsImage = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image")
        XCTAssertGreaterThan(nsImage.size.width, 0)
        XCTAssertGreaterThan(nsImage.size.height, 0)
    }
}
