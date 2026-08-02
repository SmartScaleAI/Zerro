//
//  ShortcutConfigurationTests.swift
//  ZerroTests
//

import KeyboardShortcuts
import XCTest
@testable import Zerro

@MainActor
final class ShortcutConfigurationTests: XCTestCase {
    func testAskKeepsLegacyStorageNameAndDefault() {
        XCTAssertEqual(KeyboardShortcuts.Name.askRecording.rawValue, "toggleRecording")
        XCTAssertEqual(
            KeyboardShortcuts.Name.askRecording.defaultShortcut,
            .init(.space, modifiers: [.option])
        )
    }

    func testDevHasIndependentStorageNameAndDefault() {
        XCTAssertEqual(KeyboardShortcuts.Name.devRecording.rawValue, "devRecording")
        XCTAssertEqual(
            KeyboardShortcuts.Name.devRecording.defaultShortcut,
            .init(.space, modifiers: [.option, .shift])
        )
    }

    func testShortcutsIsDedicatedSettingsCategory() {
        XCTAssertTrue(SettingsCategory.settingsGroup.contains(.shortcuts))
        XCTAssertEqual(SettingsCategory.shortcuts.title, "Shortcuts")
        XCTAssertEqual(SettingsCategory.shortcuts.icon, "keyboard")
    }
}
