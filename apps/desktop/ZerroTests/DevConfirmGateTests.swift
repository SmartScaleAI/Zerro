//
//  DevConfirmGateTests.swift
//  ZerroTests
//
//  Dev Mode anchor resolution — the confidence combine that drives the
//  resolution analytics histogram. Pins: combined = min(client, model) WHEN a
//  model anchor exists, else the client signal alone (never min'd against a
//  missing value); any combined below the threshold is a low-confidence target.
//
//  (The low-confidence anchor-CONFIRM gate AND the review card's "Targeting: …"
//  rows were removed — resolution no longer pauses the dispatch and the card no
//  longer lists targets. The combine signal lives on only in the resolution
//  analytics, which these tests cover via `combinedConfidence`.)
//

import XCTest
@testable import Zerro

@MainActor
final class DevConfirmGateTests: XCTestCase {

    private func resolved(ref: Int, clientConfidence: Double, ocr: [String] = [], phrase: String = "this") -> ResolvedDeixisAnchor {
        ResolvedDeixisAnchor(
            refIndex: ref,
            candidate: CandidateAnchor(
                phrase: phrase, phraseStart: 0, phraseEnd: 0, targetSeconds: 0,
                point: DeixisPoint(x: 0.5, y: 0.5), source: .dwell, dwellConfidence: clientConfidence
            ),
            ocrStrings: ocr,
            markedJPEGBase64: nil,
            clientConfidence: clientConfidence
        )
    }

    private func model(ref: Int, label: String?, confidence: Double) -> DevAnchor {
        DevAnchor(refIndex: ref, label: label, kind: .button, region: .hero,
                  currentState: nil, modelConfidence: confidence, altCandidates: [])
    }

    /// True when ANY resolved target is low-confidence — the same combine the
    /// resolution analytics histogram consumes.
    private func hasLow(_ app: AppState) -> Bool {
        app.devResolvedAnchors.contains { app.combinedConfidence($0) < AppState.devLowConfidenceThreshold }
    }

    func testAllHighNoLowFlag() {
        let app = AppState()
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.9), resolved(ref: 1, clientConfidence: 0.8)]
        app.devModelAnchors = [model(ref: 0, label: "Get started", confidence: 0.9), model(ref: 1, label: "Pricing", confidence: 0.8)]
        XCTAssertFalse(hasLow(app), "all high/medium → no target flagged low")
    }

    func testLowClientFlagsLow() {
        let app = AppState()
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.1)] // transit/empty
        app.devModelAnchors = [model(ref: 0, label: "x", confidence: 0.95)]
        // min(0.1, 0.95) = 0.1 < threshold → flagged low.
        XCTAssertTrue(hasLow(app))
    }

    func testLowModelFlagsLowEvenWithHighClient() {
        let app = AppState()
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.9)]
        app.devModelAnchors = [model(ref: 0, label: nil, confidence: 0.2)] // model unsure
        // min(0.9, 0.2) = 0.2 < threshold → flagged low (OCR/vision disagreement).
        XCTAssertTrue(hasLow(app))
    }

    func testNoModelAnchorFallsBackToClientAloneNotMinAgainstMissing() {
        let app = AppState()
        // High client, NO model anchor parsed → must use client alone (0.9), not
        // min against a missing/zero value.
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.9)]
        app.devModelAnchors = []
        XCTAssertFalse(hasLow(app), "absent model anchor → client confidence alone")

        // And a low client with no model still flags low.
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.2)]
        XCTAssertTrue(hasLow(app))
    }
}
