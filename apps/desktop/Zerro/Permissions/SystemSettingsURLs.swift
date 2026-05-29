//
//  SystemSettingsURLs.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Single source of truth for the `x-apple.systempreferences:` deep
//  links used by the onboarding denied-state buttons. macOS's
//  Privacy_* anchors are stable across versions; if they drift, this
//  is the one file to edit.
//

import Foundation

enum SystemSettingsURLs {
    static let screenRecording = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphone      = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let accessibility   = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
