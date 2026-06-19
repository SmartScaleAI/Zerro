//
//  AppShortcuts.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Centralized declaration of every `KeyboardShortcuts.Name` the app
//  observes. The library persists user overrides to UserDefaults under
//  a key derived from the name string, so we do not implement any
//  persistence ourselves.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global shortcut that toggles a recording session. Defaults to ⌥Space;
    /// users may rebind via the Settings recorder, which writes through to
    /// UserDefaults automatically.
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.space, modifiers: [.option])
    )
}
