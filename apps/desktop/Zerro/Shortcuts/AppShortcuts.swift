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

/// The recording flow a shortcut opens. This is an invocation choice, not a
/// persisted preference: Ask and Dev each have their own global shortcut.
enum RecordingLaunchMode: Equatable, Sendable {
    case ask
    case dev
}

extension KeyboardShortcuts.Name {
    /// Ask Mode keeps the original storage name so existing custom bindings
    /// migrate without any UserDefaults copy and ⌥Space remains the default.
    static let askRecording = Self(
        "toggleRecording",
        default: .init(.space, modifiers: [.option])
    )

    /// Dev Mode has its own independent global shortcut.
    static let devRecording = Self(
        "devRecording",
        default: .init(.space, modifiers: [.option, .shift])
    )
}
