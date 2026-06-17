//
//  DevConfirmGateTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 6) — the confidence combine + confirmAnchors
//  gate logic. Pins: combined = min(client, model) WHEN a model anchor exists,
//  else the client signal alone (never min'd against a missing value); any low
//  combined → needs confirm; the confirm card's labels prefer the model label.
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

    func testAllHighNeedsNoConfirm() {
        let app = AppState()
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.9), resolved(ref: 1, clientConfidence: 0.8)]
        app.devModelAnchors = [model(ref: 0, label: "Get started", confidence: 0.9), model(ref: 1, label: "Pricing", confidence: 0.8)]
        XCTAssertFalse(app.devNeedsConfirm, "all high/medium → dispatch immediately")
    }

    func testLowClientNeedsConfirm() {
        let app = AppState()
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.1)] // transit/empty
        app.devModelAnchors = [model(ref: 0, label: "x", confidence: 0.95)]
        // min(0.1, 0.95) = 0.1 < threshold → confirm.
        XCTAssertTrue(app.devNeedsConfirm)
    }

    func testLowModelNeedsConfirmEvenWithHighClient() {
        let app = AppState()
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.9)]
        app.devModelAnchors = [model(ref: 0, label: nil, confidence: 0.2)] // model unsure
        // min(0.9, 0.2) = 0.2 < threshold → confirm (OCR/vision disagreement).
        XCTAssertTrue(app.devNeedsConfirm)
    }

    func testNoModelAnchorFallsBackToClientAloneNotMinAgainstMissing() {
        let app = AppState()
        // High client, NO model anchor parsed → must use client alone (0.9), not
        // min against a missing/zero value.
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.9)]
        app.devModelAnchors = []
        XCTAssertFalse(app.devNeedsConfirm, "absent model anchor → client confidence alone")

        // And a low client with no model still confirms.
        app.devResolvedAnchors = [resolved(ref: 0, clientConfidence: 0.2)]
        XCTAssertTrue(app.devNeedsConfirm)
    }

    func testConfirmSummariesPreferModelLabelThenOCRThenPhrase() {
        let app = AppState()
        app.devResolvedAnchors = [
            resolved(ref: 0, clientConfidence: 0.9, ocr: ["OCR label"], phrase: "this"),
            resolved(ref: 1, clientConfidence: 0.1, ocr: [], phrase: "the header"),
        ]
        app.devModelAnchors = [model(ref: 0, label: "Get started", confidence: 0.9)]
        let s = app.devConfirmAnchorSummaries
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].label, "Get started") // model label preferred
        XCTAssertFalse(s[0].isLow)
        XCTAssertEqual(s[1].label, "the header")  // no model + no OCR → phrase
        XCTAssertTrue(s[1].isLow)                  // low-confidence one flagged
    }
}
