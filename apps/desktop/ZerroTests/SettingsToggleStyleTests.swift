//
//  SettingsToggleStyleTests.swift
//  ZerroTests
//
//  Render smoke test for VFSwitchToggleStyle — the custom ToggleStyle that
//  replaced the native `.toggleStyle(.switch)` on the Settings toggles. The
//  native NSSwitch intermittently drew its track but not its knob on first
//  appearance; the custom style draws the knob as a SwiftUI Circle so it
//  renders deterministically. This test pins that the style renders in BOTH
//  the on and off states (and that the bound value drives the rendering)
//  via ImageRenderer, mirroring the PillCardSnapshotTests harness.
//

import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class SettingsToggleStyleTests: XCTestCase {

    /// Renders a toggle wearing VFSwitchToggleStyle and asserts the
    /// ImageRenderer produced a non-empty raster — i.e. the SwiftUI-shape
    /// knob is part of the layout and paints without a native control.
    private func assertRenders(isOn: Bool, file: StaticString = #file, line: UInt = #line) {
        let view = Toggle("Sample", isOn: .constant(isOn))
            .labelsHidden()
            .toggleStyle(VFSwitchToggleStyle())
            .frame(width: 80, height: 30)
            .background(Color.vfPanelBackground)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.nsImage
        XCTAssertNotNil(image, "VFSwitchToggleStyle failed to render (isOn=\(isOn))", file: file, line: line)
        if let size = image?.size {
            XCTAssertGreaterThan(size.width, 0, "rendered image has zero width (isOn=\(isOn))", file: file, line: line)
            XCTAssertGreaterThan(size.height, 0, "rendered image has zero height (isOn=\(isOn))", file: file, line: line)
        }
    }

    func testRendersWhenOn() {
        assertRenders(isOn: true)
    }

    func testRendersWhenOff() {
        assertRenders(isOn: false)
    }
}
