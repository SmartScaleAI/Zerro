//
//  DevAnchorRedactionTests.swift
//  ZerroTests
//
//  F-01 — proof that the Dev-Mode anchor path honors `recordingRedactSecrets`
//  with the SAME contract as keyframes: a secret rendered into an anchor crop is
//  (a) masked to [REDACTED] in the OCR hint strings AND (b) boxed out of the crop
//  pixels, in lock step, BEFORE the crop is encoded / attached. The mechanism is
//  the shared `Redactor`/`SecretDetector` pass; this test drives it through
//  `DevAnchorPipeline.redactCrop` — the exact seam `build` applies to every crop
//  before compositing the marker — so no source video is needed.
//
//  Mirrors RedactorTests: a contiguous Luhn-valid card number is the secret (OCR
//  reads digit runs reliably, so the test isn't flaky on glyph confusion), and we
//  prove the pixel box by re-OCR'ing the redacted crop and finding the secret is
//  no longer legible. The mechanism is identical for every secret SecretDetector
//  flags.
//

import CoreGraphics
import CoreText
import XCTest
@testable import Zerro

final class DevAnchorRedactionTests: XCTestCase {

    private let secret = "4242424242424242" // Luhn-valid test card

    /// Renders dark text on a white background into an RGB bitmap, big enough
    /// that Vision reads it reliably. Same recipe as RedactorTests.
    private func renderCrop(_ text: String) -> CGImage {
        let width = 900
        let height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo" as CFString, 44, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 30, y: 90)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    private func ocrJoined(_ image: CGImage) -> String {
        VisionOCR.recognize(image).map(\.text).joined(separator: " ")
    }

    func testAnchorRedactionMasksHintAndBoxesCrop() {
        let crop = renderCrop("Card: \(secret)")

        // 0. Vacuous-pass guard: with redaction OFF, OCR must actually read the
        //    secret off the synthetic crop — else the asserts below are meaningless.
        let rawOCR = VisionOCR.recognize(crop)
        let rawText = rawOCR.map(\.text).joined(separator: " ")
        XCTAssertTrue(rawText.contains(secret), "OCR did not read the secret; got: \(rawText)")

        // 0b. Redaction OFF is a pass-through: hint strings and crop pixels are
        //     returned unchanged (secret present, no mask, still legible).
        let off = DevAnchorPipeline.redactCrop(crop, ocr: rawOCR, redact: false)
        XCTAssertEqual(off.ocr.map(\.text).joined(separator: " "), rawText,
                       "OFF must pass the OCR hint strings through unchanged")
        XCTAssertTrue(ocrJoined(off.image).contains(secret),
                      "OFF must leave the crop pixels unchanged (secret still legible)")

        // 1. Redaction ON: the secret is masked to [REDACTED] in the hint text…
        let on = DevAnchorPipeline.redactCrop(crop, ocr: rawOCR, redact: true)
        let onText = on.ocr.map(\.text).joined(separator: " ")
        XCTAssertTrue(onText.contains("[REDACTED]"), "OCR hint not masked; got: \(onText)")
        XCTAssertFalse(onText.contains(secret), "secret leaked in OCR hint: \(onText)")

        // 2. …and the crop PIXELS are boxed in lock step: re-OCR'ing the redacted
        //    crop can no longer read the secret (the opaque box destroyed it).
        let reread = ocrJoined(on.image)
        XCTAssertFalse(reread.contains(secret), "secret still legible in crop after redaction: \(reread)")
    }

    func testCleanCropUntouched() {
        // No secret → strings returned, no [REDACTED], legible label preserved.
        let crop = renderCrop("Get started")
        let rawOCR = VisionOCR.recognize(crop)
        let on = DevAnchorPipeline.redactCrop(crop, ocr: rawOCR, redact: true)
        XCTAssertFalse(on.ocr.map(\.text).joined().contains("[REDACTED]"))
        XCTAssertTrue(on.ocr.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("started"))
    }
}
