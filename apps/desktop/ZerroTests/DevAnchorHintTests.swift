//
//  DevAnchorHintTests.swift
//  ZerroTests
//
//  F-10 — a low-confidence deixis anchor used to ship the same DEFINITIVE
//  "the developer pointed here" hint as a certain click, asserting a false
//  certainty the model would then anchor its edit on. `AppState.anchorHint`
//  now gates the phrasing on the anchor's CLIENT confidence against
//  `AppState.devLowConfidenceThreshold` (the same bar the review card's amber
//  flag uses): at/above → the definitive hint, byte-identical to before;
//  below → a hedged "MAY have been referring near here … best guess" hint.
//  Both keep the `DEIXIS REFERENCE N:` tag the system prompts key on.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class DevAnchorHintTests: XCTestCase {

    private func anchor(confidence: Double, refIndex: Int = 0) -> ResolvedDeixisAnchor {
        ResolvedDeixisAnchor(
            refIndex: refIndex,
            candidate: CandidateAnchor(
                phrase: "this button",
                phraseStart: 1.0,
                phraseEnd: 1.4,
                targetSeconds: 1.0,
                point: DeixisPoint(x: 0.5, y: 0.5),
                source: .dwell,
                dwellConfidence: confidence
            ),
            ocrStrings: ["Get started"],
            markedJPEGBase64: Data("jpeg-bytes".utf8).base64EncodedString(),
            clientConfidence: confidence
        )
    }

    /// At/above the threshold, the hint is the pre-F-10 definitive phrasing —
    /// byte-identical, so high-confidence behavior is provably unchanged.
    func testHighConfidenceKeepsDefinitiveHint() {
        let hint = AppState.anchorHint(
            refIndex: 3,
            phrase: "this button",
            ocrStrings: ["Get started", "Pricing"],
            clientConfidence: AppState.devLowConfidenceThreshold
        )
        XCTAssertEqual(
            hint,
            "DEIXIS REFERENCE 3: the developer pointed here while saying \"this button\". The crosshair marks the element. Nearby on-screen text: Get started, Pricing"
        )
    }

    /// Below the threshold, the definitive claims are gone and the hedge is in.
    func testLowConfidenceHintIsSoftened() {
        let hint = AppState.anchorHint(
            refIndex: 0,
            phrase: "this",
            ocrStrings: ["Get started"],
            clientConfidence: AppState.devLowConfidenceThreshold - 0.01
        )
        XCTAssertFalse(hint.contains("pointed here"))
        XCTAssertFalse(hint.contains("marks the element"))
        XCTAssertTrue(hint.contains("MAY have been referring"))
        XCTAssertTrue(hint.contains("best guess"))
        // The tag the system prompts key on survives, as does the OCR context.
        XCTAssertTrue(hint.hasPrefix("DEIXIS REFERENCE 0:"))
        XCTAssertTrue(hint.contains("Nearby on-screen text: Get started"))
    }

    /// End-to-end through `writeAnchorFrames`: a mixed batch tags each frame
    /// with the phrasing its own confidence earned.
    func testWriteAnchorFramesGatesPerAnchor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-hint-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let frames = AppState.writeAnchorFrames(
            [anchor(confidence: 0.2, refIndex: 0), anchor(confidence: 0.9, refIndex: 1)],
            baseTimestamp: CMTime(seconds: 30, preferredTimescale: 600),
            into: dir
        )
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames[0].ocrText?.contains("MAY have been referring") ?? false)
        XCTAssertTrue(frames[1].ocrText?.contains("pointed here") ?? false)
    }
}
