//
//  ColorThemeTests.swift
//  ZerroTests
//
//  Contract tests for the fixed black application palette.
//

import AppKit
import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class ColorThemeTests: XCTestCase {

    func testBaseSurfacesArePureBlack() {
        assertColor(.vfPanelBackground, equals: (0, 0, 0, 1))
        assertColor(.vfPillBackground, equals: (0, 0, 0, 1))
    }

    func testRaisedSurfacesShareLighterAccentGray() {
        let accent = (red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: 1.0)
        assertColor(.vfAccentGray, equals: accent)
        assertColor(.vfCardBackground, equals: accent)
        assertColor(.vfOverlayBackground, equals: accent)
        assertColor(.vfArtifactBackground, equals: accent)
        assertColor(.vfControlBackground, equals: accent)
        assertColor(.vfDropdownBackground, equals: accent)
    }

    func testFloatingChromeUsesVisibleDarkGrayBorder() {
        let border = 48.0 / 255.0
        assertColor(.vfOverlayBorder, equals: (border, border, border, 1))
    }

    func testCustomDropdownInteractionStatesStepUpFromPanel() {
        assertColor(
            .vfDropdownRowHover,
            equals: (36.0 / 255.0, 36.0 / 255.0, 38.0 / 255.0, 1)
        )
        assertColor(
            .vfDropdownRowSelected,
            equals: (44.0 / 255.0, 44.0 / 255.0, 46.0 / 255.0, 1)
        )
        assertColor(
            .vfDropdownRowSelectedHover,
            equals: (52.0 / 255.0, 52.0 / 255.0, 55.0 / 255.0, 1)
        )
    }

    func testMenuBarSelectionAccentRemainsUnchanged() {
        assertColor(
            .vfMenuRowHover,
            equals: (24.0 / 255.0, 104.0 / 255.0, 191.0 / 255.0, 1)
        )
    }

    func testPrimaryTextHasStrongContrastOnRaisedCards() throws {
        let ratio = try contrastRatio(foreground: .vfTextPrimary, on: .vfCardBackground)
        XCTAssertGreaterThanOrEqual(ratio, 7.0, "Primary text should meet enhanced contrast on raised cards")
    }

    func testSecondaryTextRemainsLegibleOnRaisedCards() throws {
        let ratio = try contrastRatio(foreground: .vfTextSecondary, on: .vfCardBackground)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "Secondary text should meet standard contrast on raised cards")
    }

    private func contrastRatio(foreground: Color, on background: Color) throws -> Double {
        let background = try XCTUnwrap(NSColor(background).usingColorSpace(.sRGB))
        let foreground = try XCTUnwrap(NSColor(foreground).usingColorSpace(.sRGB))
        let alpha = foreground.alphaComponent
        let composited = (
            red: Double(foreground.redComponent * alpha + background.redComponent * (1 - alpha)),
            green: Double(foreground.greenComponent * alpha + background.greenComponent * (1 - alpha)),
            blue: Double(foreground.blueComponent * alpha + background.blueComponent * (1 - alpha))
        )
        let ratio = contrastRatio(
            foreground: composited,
            background: (
                Double(background.redComponent),
                Double(background.greenComponent),
                Double(background.blueComponent)
            )
        )
        return ratio
    }

    func testSemanticAccentsRemainPinned() {
        assertColor(.vfRecordingRed, equals: (1.0, 0.271, 0.227, 1))
        assertColor(.vfWarningAmber, equals: (1.0, 0.624, 0.039, 1))
        assertColor(.vfSuccessGreen, equals: (0.188, 0.820, 0.345, 1))
        assertColor(.vfDevAccent, equals: (0.204, 0.886, 0.478, 1))
        assertColor(.vfAccentBlue, equals: (10.0 / 255.0, 132.0 / 255.0, 1.0, 1))
    }

    private func assertColor(
        _ color: Color,
        equals expected: (red: Double, green: Double, blue: Double, alpha: Double),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else {
            XCTFail("Color did not resolve into sRGB", file: file, line: line)
            return
        }

        let accuracy = 0.000_5
        XCTAssertEqual(resolved.redComponent, expected.red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, expected.green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, expected.blue, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, expected.alpha, accuracy: accuracy, file: file, line: line)
    }

    private func contrastRatio(
        foreground: (red: Double, green: Double, blue: Double),
        background: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
        let darker = min(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(
        _ color: (red: Double, green: Double, blue: Double)
    ) -> Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }
}
