//
//  DevResultChargeLineTests.swift
//  ZerroTests
//
//  Pins the "−N credits · M left" charge readout onto the Dev Mode result
//  card. Managed Dev Mode meters its prompt-generation step exactly like
//  artifact mode, so the SAME `CreditDisplay.chargeLine` string belongs on
//  the `.devDone` card — carried through the bridge's `DevResultCard` and
//  rendered bottom-left in the footer. BYOK (no managed call →
//  `lastGenerationCharge == nil`) carries no charge line, exactly like an
//  artifact result with no `credits_charged`.
//

import AppKit
import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class DevResultChargeLineTests: XCTestCase {

    /// Stand up a finished Dev Mode run (the `.devDone` tail): an agent summary,
    /// a readable diff, and a diff stat. The caller supplies the managed charge
    /// (nil → BYOK).
    private func makeDevDoneState(charge: AppState.GenerationCharge?) -> AppState {
        let appState = AppState()
        appState.devSummary = "Recolored the primary button and tightened the header."
        appState.devDiffText = """
        diff --git a/App.css b/App.css
        @@ -1,3 +1,3 @@
        -.btn { color: blue; }
        +.btn { color: teal; }
        """
        appState.devDiffStat = GitDiffStat(filesChanged: 1, added: 1, removed: 1)
        appState.lastGenerationCharge = charge
        appState.state = .devDone
        return appState
    }

    // MARK: Bridge mapping

    /// A MANAGED dev result carries the same charge string artifact mode would —
    /// formatted via the shared `CreditDisplay.chargeLine`, so the two read
    /// identically.
    func testManagedDevResultCarriesChargeLine() {
        let charge = AppState.GenerationCharge(charged: 4, remaining: 96)
        let appState = makeDevDoneState(charge: charge)

        guard case .devDone(let card, _) = appState.pillState else {
            return XCTFail("`.devDone` must map to the `.devDone` card, got \(String(describing: appState.pillState))")
        }
        // Identical to what the artifact path produces from the same charge.
        let expected = CreditDisplay.chargeLine(charged: 4, remaining: 96)
        XCTAssertEqual(card.chargeLine, expected)
        XCTAssertEqual(card.chargeLine, "\u{2212}4 credits \u{00B7} 96 left")
    }

    /// A BYOK dev result (no managed call → nil charge) carries no charge line,
    /// exactly like an artifact result with no `credits_charged`.
    func testByokDevResultCarriesNoChargeLine() {
        let appState = makeDevDoneState(charge: nil)

        guard case .devDone(let card, _) = appState.pillState else {
            return XCTFail("`.devDone` must map to the `.devDone` card")
        }
        XCTAssertNil(card.chargeLine)
    }

    // MARK: Render smoke

    /// The expanded `.devDone` card with a charge line lays out (and, by reusing
    /// the artifact footer's left slot, shows it bottom-left alongside Undo/Accept).
    func testDevDoneWithChargeLineRendersExpandedCard() throws {
        let view = PillView(state: .devDone(
            card: DevResultCard(
                title: "Changes applied",
                summary: "Recolored the primary button and tightened the header.",
                diffText: "diff --git a/App.css b/App.css\n@@ -1 +1 @@\n-blue\n+teal",
                linesAdded: 1, linesRemoved: 1, filesChanged: 1,
                chargeLine: CreditDisplay.chargeLine(charged: 4, remaining: 96)
            ),
            expanded: true
        ))
        .padding(40)
        .background(Color.vfPanelBackground)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let nsImage = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image")
        XCTAssertGreaterThan(nsImage.size.width, 0)
        XCTAssertGreaterThan(nsImage.size.height, 0)

        if let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let dir = URL(fileURLWithPath: "/tmp/zerro-pill-cards", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: dir.appendingPathComponent("09-devdone-charge.png"))
        }
    }

    /// Without a charge line the expanded card still lays out — the footer is just
    /// the Undo/Accept pair (BYOK / pre-charge behavior unchanged).
    func testDevDoneWithoutChargeLineRenders() throws {
        let view = PillView(state: .devDone(
            card: DevResultCard(
                title: "Changes applied",
                summary: "Renamed a file.",
                diffText: "",
                linesAdded: 0, linesRemoved: 0, filesChanged: 1,
                chargeLine: nil
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
