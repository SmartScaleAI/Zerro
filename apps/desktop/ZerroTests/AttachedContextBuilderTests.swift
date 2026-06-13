//
//  AttachedContextBuilderTests.swift
//  ZerroTests
//
//  Phase 2 of the modes → typed-artifact refactor: the §2 Attached Context
//  rules — dedupe repeated OCR lines across frames, ~4,000-char cap,
//  omit empty sections, nil when both inputs are empty.
//

import CoreMedia
import XCTest
@testable import Zerro

final class AttachedContextBuilderTests: XCTestCase {

    private func frame(_ index: Int, ocr: String?) -> ExtractedFrame {
        ExtractedFrame(
            url: URL(fileURLWithPath: "/tmp/frame_\(index).jpg"),
            timestamp: CMTime(seconds: Double(index), preferredTimescale: 600),
            index: index,
            ocrText: ocr
        )
    }

    // MARK: Both empty → nil

    func testBothEmptyReturnsNil() {
        XCTAssertNil(AttachedContextBuilder.build(frames: [], clicks: []))
        XCTAssertNil(AttachedContextBuilder.build(
            frames: [frame(0, ocr: nil), frame(1, ocr: "   \n  ")],
            clicks: []
        ))
    }

    // MARK: Section omission

    func testOCROnlyOmitsClicksSection() throws {
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [frame(0, ocr: "Sign in\nEmail")],
            clicks: []
        ))
        XCTAssertTrue(block.hasPrefix("## Attached Context\n"))
        XCTAssertTrue(block.contains("**Screen text (OCR excerpts):** Sign in\nEmail"))
        XCTAssertFalse(block.contains("**Clicks:**"))
    }

    func testClicksOnlyOmitsOCRSection() throws {
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [frame(0, ocr: nil)],
            clicks: [
                ResolvedClick(seconds: 1.0, label: "Sign in"),
                ResolvedClick(seconds: 2.5, label: "Apply"),
            ]
        ))
        XCTAssertEqual(block, "## Attached Context\n**Clicks:** clicked \"Sign in\", clicked \"Apply\"")
    }

    func testBothSectionsRenderInOrder() throws {
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [frame(0, ocr: "Checkout")],
            clicks: [ResolvedClick(seconds: 1.0, label: "Apply")]
        ))
        let ocrRange = try XCTUnwrap(block.range(of: "**Screen text"))
        let clicksRange = try XCTUnwrap(block.range(of: "**Clicks:**"))
        XCTAssertLessThan(ocrRange.lowerBound, clicksRange.lowerBound, "OCR section precedes clicks per the §2 template")
    }

    // MARK: Dedupe

    func testRepeatedOCRLinesAcrossFramesDedupe() throws {
        // Consecutive frames of the same screen repeat most of their text;
        // each line survives once, at its first position.
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [
                frame(0, ocr: "Checkout\nSubtotal $49.00\nApply"),
                frame(1, ocr: "Checkout\nSubtotal $49.00\nApply\nError: invalid code"),
                frame(2, ocr: "Checkout\nApply"),
            ],
            clicks: []
        ))
        let expected = "**Screen text (OCR excerpts):** Checkout\nSubtotal $49.00\nApply\nError: invalid code"
        XCTAssertTrue(block.contains(expected), "got: \(block)")
        XCTAssertEqual(block.components(separatedBy: "Checkout").count - 1, 1, "duplicate line appears once")
    }

    func testBlankAndWhitespaceOCRLinesDrop() throws {
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [frame(0, ocr: "  Sign in  \n\n   \nEmail")],
            clicks: []
        ))
        XCTAssertTrue(block.contains("**Screen text (OCR excerpts):** Sign in\nEmail"))
    }

    func testEmptyClickLabelsDrop() {
        // The resolver drops unlabeled clicks upstream, but the builder is
        // defensive: a blank label can't produce `clicked ""`.
        let block = AttachedContextBuilder.build(
            frames: [],
            clicks: [ResolvedClick(seconds: 1.0, label: "   ")]
        )
        XCTAssertNil(block, "a whitespace-only label leaves both sections empty → nil")
    }

    // MARK: Cap

    func testLongOCRCapsNearLimitAtLineBoundary() throws {
        // 200 unique ~60-char lines ≈ 12,000 chars of OCR.
        let lines = (0..<200).map { "Row \($0) — some moderately long on-screen table cell text" }
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [frame(0, ocr: lines.joined(separator: "\n"))],
            clicks: [ResolvedClick(seconds: 1.0, label: "Export")]
        ))
        XCTAssertLessThanOrEqual(block.count, AttachedContextBuilder.maxLength)
        XCTAssertTrue(block.contains("\u{2026}"), "truncation is visible")
        XCTAssertTrue(block.hasSuffix("**Clicks:** clicked \"Export\""), "clicks section survives the OCR cap intact")

        // Line-boundary truncation: every kept OCR line is one of the
        // inputs, not a mid-line cut.
        let ocrSection = try XCTUnwrap(
            block.components(separatedBy: "**Screen text (OCR excerpts):** ").last?
                .components(separatedBy: "\n**Clicks:**").first
        )
        let keptLines = ocrSection.replacingOccurrences(of: "\u{2026}", with: "").split(separator: "\n").map(String.init)
        for kept in keptLines {
            XCTAssertTrue(lines.contains(kept), "kept line is a complete input line: \(kept)")
        }
        XCTAssertGreaterThan(keptLines.count, 50, "the budget fits a meaningful excerpt")
    }

    func testShortContentIsNotTruncated() throws {
        let block = try XCTUnwrap(AttachedContextBuilder.build(
            frames: [frame(0, ocr: "Sign in")],
            clicks: [ResolvedClick(seconds: 1.0, label: "Sign in")]
        ))
        XCTAssertFalse(block.contains("\u{2026}"))
        XCTAssertLessThanOrEqual(block.count, AttachedContextBuilder.maxLength)
    }

    func testWhitespaceOnlyInputsReturnNil() {
        // Blank OCR lines and whitespace-only click labels count for
        // nothing — both sections empty → nil, so the convert request
        // never carries an empty context block.
        XCTAssertNil(AttachedContextBuilder.build(
            frames: [frame(0, ocr: "   \n  ")],
            clicks: [ResolvedClick(seconds: 1.0, label: "  ")]
        ))
    }
}
