//
//  DevFailedPillCardTests.swift
//  ZerroTests
//
//  Pins `.devFailed` to the SHARED expanded failure card (the same
//  `ArtifactCardView` + `FailureConfig` layout `.error` / `.failureExpanded`
//  use): the bridge must carry a short `headline` plus the FULL agent
//  error / reason as `detail` — never the old single-line, lineLimit(3)
//  capsule that clipped a long message (the `ActionRequiredError: Named
//  models unavailable…` failure that prompted this).
//

import AppKit
import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class DevFailedPillCardTests: XCTestCase {

    /// The long agent error that started this — it must survive the bridge
    /// verbatim so the card can show every character.
    private static let longAgentError =
        "ActionRequiredError: Named models unavailable. Free plans can only use "
        + "Auto. Re-run with the Auto model, or upgrade your Cursor plan to use a "
        + "named model. This message is intentionally long to prove the expanded "
        + "failure card wraps and scrolls the full text instead of truncating it "
        + "to a few words the way the old single-line capsule did."

    // MARK: Bridge mapping

    func testDevFailedMapsToCardWithHeadlineAndFullDetail() {
        let appState = AppState()
        let failure = DevDispatchFailure.agent(.nonZeroExit(code: 1, stderrTail: Self.longAgentError))
        appState.devFailure = failure
        appState.state = .devFailed

        guard case .devFailed(let headline, let detail, _) = appState.pillState else {
            return XCTFail("`.devFailed` must map to the `.devFailed` card, got \(String(describing: appState.pillState))")
        }
        // The headline is the SHORT category label, distinct from the full detail.
        XCTAssertEqual(headline, failure.headline)
        XCTAssertEqual(headline, "Couldn\u{2019}t apply changes")
        // The detail is the FULL agent error, byte-for-byte — no truncation.
        XCTAssertEqual(detail, Self.longAgentError)
        XCTAssertEqual(detail, failure.userMessage)
        XCTAssertNotEqual(headline, detail, "the headline must not be the whole message")
    }

    func testDevFailedFallsBackWhenFailureNil() {
        let appState = AppState()
        appState.devFailure = nil
        appState.state = .devFailed

        guard case .devFailed(let headline, let detail, _) = appState.pillState else {
            return XCTFail("`.devFailed` must map to the `.devFailed` card even with no recorded failure")
        }
        XCTAssertFalse(headline.isEmpty, "headline must never be empty — the card always has a title")
        XCTAssertFalse(detail.isEmpty, "detail must never be empty — the card always has a body")
    }

    func testDevFailedWithoutCheckpointCannotRevert() {
        let appState = AppState()
        appState.devFailure = .notAGitRepo
        appState.state = .devFailed

        guard case .devFailed(_, _, let canRevert) = appState.pillState else {
            return XCTFail("`.devFailed` must map to the `.devFailed` card")
        }
        // No checkpoint taken (failure before the snapshot) → nothing to revert.
        XCTAssertFalse(canRevert)
    }

    // MARK: Headlines

    /// Every failure's `headline` must be a short, non-empty label that is NOT
    /// just the full `userMessage` — that split is what lets the card show a bold
    /// title over wrapped prose.
    func testEveryFailureHeadlineIsShortLabel() {
        let failures: [DevDispatchFailure] = [
            .notAGitRepo, .gitUnavailable, .checkpointFailed, .agentUnavailable,
            .noChangeRequested, .revertFailed, .confirmDeclined,
            .agent(.nonZeroExit(code: 2, stderrTail: Self.longAgentError)),
            .agent(.spawnFailed("boom")), .agent(.busy), .agent(.cancelled),
        ]
        for failure in failures {
            XCTAssertFalse(failure.headline.isEmpty, "\(failure) has an empty headline")
            XCTAssertLessThanOrEqual(failure.headline.count, 40,
                                     "\(failure) headline is too long to be a label: \(failure.headline)")
        }
        // The non-zero-exit headline in particular must NOT leak the long tail.
        let exit = DevDispatchFailure.agent(.nonZeroExit(code: 1, stderrTail: Self.longAgentError))
        XCTAssertNotEqual(exit.headline, exit.userMessage)
        XCTAssertFalse(exit.headline.contains("ActionRequiredError"),
                       "the headline must be a label, not the agent's raw error")
    }

    // MARK: Render smoke (no truncation)

    /// Renders the `.devFailed` card with the long error to a PNG — proves the
    /// expanded card lays out (and, by reusing `.failureExpanded`'s scrolling
    /// prose body, shows the full message). Writes to /tmp for eyeballing.
    func testDevFailedRendersExpandedCard() throws {
        let view = PillView(state: .devFailed(
            headline: "Couldn\u{2019}t apply changes",
            detail: Self.longAgentError,
            canRevert: true
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
            try? png.write(to: dir.appendingPathComponent("08-devfailed-long.png"))
        }
    }
}
