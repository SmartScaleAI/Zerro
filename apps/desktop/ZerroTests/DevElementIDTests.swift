//
//  DevElementIDTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 5) — element-ID building blocks: Vision OCR of a
//  rendered label, crosshair marker compositing, the DEFENSIVE structured-anchor
//  parser (unknown shapes degrade, never crash), and the client-confidence
//  signal (dwell + OCR cleanliness).
//

import XCTest
import CoreGraphics
import CoreText
@testable import Zerro

final class DevElementIDTests: XCTestCase {

    // MARK: - Vision OCR

    func testOCRReadsRenderedLabel() {
        let image = renderText("Get started", width: 600, height: 200)
        let strings = VisionOCR.recognize(image)
        let joined = strings.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.localizedCaseInsensitiveContains("Get started"),
                      "OCR should read the rendered label, got: \(joined)")
    }

    func testOCREmptyImageDegradesToNoStrings() {
        let blank = solid(width: 100, height: 100)
        XCTAssertTrue(VisionOCR.recognize(blank).isEmpty, "a blank frame yields no strings, never crashes")
    }

    // MARK: - Marker

    func testMarkerCompositesSameSizeImage() {
        let image = solid(width: 400, height: 300)
        let marked = AnchorMarker.composite(on: image, atTopLeft: (x: 0.5, y: 0.5))
        XCTAssertNotNil(marked)
        XCTAssertEqual(marked?.width, 400)
        XCTAssertEqual(marked?.height, 300)
        // Marking actually changed pixels (the crosshair is drawn).
        XCTAssertNotEqual(NativeFrameExtractor.jpegData(marked!), NativeFrameExtractor.jpegData(image))
    }

    // MARK: - Defensive anchor parsing

    func testParsesFencedAnchorBlock() {
        let raw = """
        Here's what I'll change.

        ```zerro_anchors
        [
          {"ref":0,"label":"Get started","type":"button","region":"hero","current_state":"blue bg","confidence":0.9,"alt_candidates":["Get Started"]},
          {"ref":1,"label":"Pricing","type":"link","region":"nav","confidence":0.7}
        ]
        ```

        ```agent_prompt
        Goal: ...
        ```
        """
        let anchors = DevAnchorParser.parse(raw)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors[0].label, "Get started")
        XCTAssertEqual(anchors[0].kind, .button)
        XCTAssertEqual(anchors[0].region, .hero)
        XCTAssertEqual(anchors[0].modelConfidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(anchors[0].altCandidates, ["Get Started"])
        XCTAssertEqual(anchors[1].kind, .link)
        XCTAssertNil(anchors[1].currentState) // absent → nil, not a crash
    }

    func testParserDegradesOnGarbageNeverCrashes() {
        XCTAssertEqual(DevAnchorParser.parse("no anchors here at all").count, 0)
        XCTAssertEqual(DevAnchorParser.parse("```zerro_anchors\nnot json{{{\n```").count, 0)
        // Unknown enum values + missing fields degrade to .unknown / defaults.
        let weird = DevAnchorParser.parseJSON([
            ["label": "X", "type": "blink-tag", "region": "outer-space", "confidence": 5],
            "a bare string, not an object",
            ["confidence": "0.3"],
        ])
        XCTAssertEqual(weird.count, 2, "the non-object entry is skipped, the others kept")
        XCTAssertEqual(weird[0].kind, .unknown)
        XCTAssertEqual(weird[0].region, .unknown)
        XCTAssertEqual(weird[0].modelConfidence, 1.0, "out-of-range confidence is clamped to [0,1]")
        XCTAssertNil(weird[1].label)
        XCTAssertEqual(weird[1].modelConfidence, 0.3, accuracy: 0.0001, "string confidence is coerced")
    }

    // MARK: - Client confidence

    func testClientConfidenceBuckets() {
        let ocrLabel = [OCRString(text: "Get started", box: .zero)]
        func anchor(_ source: CandidateAnchor.Source, _ dwell: Double) -> CandidateAnchor {
            CandidateAnchor(phrase: "this", phraseStart: 0, phraseEnd: 0, targetSeconds: 0,
                            point: DeixisPoint(x: 0.5, y: 0.5), source: source, dwellConfidence: dwell)
        }
        // Click → certain.
        XCTAssertEqual(DevAnchorPipeline.clientConfidence(candidate: anchor(.click, 0.3), ocr: []), 1.0)
        // Tight dwell + a clean label → high (driven by the dwell).
        XCTAssertEqual(DevAnchorPipeline.clientConfidence(candidate: anchor(.dwell, 0.85), ocr: ocrLabel), 0.85, accuracy: 0.0001)
        // Strong dwell but NOTHING to label → capped to medium-low.
        XCTAssertEqual(DevAnchorPipeline.clientConfidence(candidate: anchor(.dwell, 0.85), ocr: []), 0.45, accuracy: 0.0001)
        // Last-known / empty space → low.
        XCTAssertLessThanOrEqual(DevAnchorPipeline.clientConfidence(candidate: anchor(.lastKnown, 0.5), ocr: []), 0.2)
        XCTAssertEqual(DevAnchorPipeline.clientConfidence(candidate: anchor(.none, 0.0), ocr: []), 0.0)
    }

    // MARK: - Helpers

    private func solid(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func renderText(_ text: String, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 24, y: height / 2 - 24)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }
}
