//
//  RedactorTests.swift
//  ZerroTests
//
//  Phase 3 — end-to-end proof of the Vision redaction path on a synthesized
//  frame (no recording needed). SecretDetectorTests cover the pure detection;
//  this covers the part that needs Vision: that a secret rendered into a frame
//  is (a) read by OCR, (b) masked to [REDACTED] in the returned text, and
//  (c) boxed in the pixels — proven by re-OCR'ing the redacted image and
//  finding the secret is no longer legible.
//
//  We use a contiguous Luhn-valid card number as the secret: OCR reads digit
//  runs very reliably, so the test isn't flaky on glyph confusion the way a
//  mixed-case API key could be. The mechanism is identical for every secret
//  SecretDetector flags.
//

import CoreGraphics
import CoreText
import XCTest
@testable import Zerro

final class RedactorTests: XCTestCase {

    private let secret = "4242424242424242" // Luhn-valid test card

    /// Renders dark text on a white background into an RGB bitmap, big enough
    /// that Vision reads it reliably.
    private func renderFrame(_ text: String) -> CGImage {
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

    func testRedactionMasksTextAndBoxesPixels() {
        let frame = renderFrame("Card: \(secret)")

        // 0. Guard against a vacuous pass: with redaction OFF, OCR must actually
        //    read the secret. If this fails, OCR didn't read our synthetic frame
        //    (and the redaction asserts below would be meaningless).
        let raw = Redactor.process(frame, redact: false)
        XCTAssertTrue(raw.text.contains(secret), "OCR did not read the secret; got: \(raw.text)")

        // 1. With redaction ON: the secret is masked to [REDACTED] in the text…
        let redacted = Redactor.process(frame, redact: true)
        XCTAssertTrue(redacted.text.contains("[REDACTED]"), "text not masked; got: \(redacted.text)")
        XCTAssertFalse(redacted.text.contains(secret), "secret leaked in text: \(redacted.text)")

        // 2. …and the PIXELS are boxed: re-OCR'ing the redacted image can no
        //    longer read the secret (the opaque box destroyed those glyphs).
        let reread = Redactor.process(redacted.image, redact: false)
        XCTAssertFalse(reread.text.contains(secret), "secret still legible after redaction: \(reread.text)")
    }

    func testNoRedactionWhenDisabled() {
        let frame = renderFrame("Card: \(secret)")
        let out = Redactor.process(frame, redact: false)
        // Redaction off → raw text (secret present, no mask) and the original
        // image returned for encoding.
        XCTAssertTrue(out.text.contains(secret))
        XCTAssertFalse(out.text.contains("[REDACTED]"))
    }

    func testCleanFrameIsUntouched() {
        // No secret → text returned, no [REDACTED], image unchanged.
        let frame = renderFrame("Welcome to the dashboard")
        let out = Redactor.process(frame, redact: true)
        XCTAssertFalse(out.text.contains("[REDACTED]"))
        XCTAssertTrue(out.text.localizedCaseInsensitiveContains("dashboard"))
    }
}
