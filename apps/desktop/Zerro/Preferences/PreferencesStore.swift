//
//  PreferencesStore.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Single source of truth for app preferences.
//
//  Storage layout
//  --------------
//  • UserDefaults  — non-sensitive prefs (e.g. selected microphone unique ID).
//                    Read/written via this store; views never reach into
//                    `UserDefaults.standard` directly.
//  • Keychain      — secrets (currently just the OpenAI API key). Handled
//                    by `KeychainStore` and intentionally kept *out* of
//                    UserDefaults, because @AppStorage / UserDefaults
//                    serialize to a plaintext plist on disk.
//
//  The store is `@Observable` + `@MainActor` and exposes plain stored
//  properties; SwiftUI views read them via `@Bindable`. No SwiftUI types
//  are imported here so the store stays testable in isolation.
//

import Foundation

@MainActor
@Observable
final class PreferencesStore {

    // MARK: - Keys

    /// Stringly-typed UserDefaults keys, kept in one place so they don't
    /// leak into call sites the way `@AppStorage("…")` literals tend to.
    private enum Keys {
        static let microphoneDeviceID = "vf.microphone.deviceID"
    }

    // MARK: - Backing storage

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Preferences

    /// Persisted `AVCaptureDevice.uniqueID` of the selected input device.
    /// Empty string is the sentinel for "System Default" — we never persist
    /// localized device names because they aren't stable across reconnects.
    var microphoneDeviceID: String {
        didSet { defaults.set(microphoneDeviceID, forKey: Keys.microphoneDeviceID) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.microphoneDeviceID = defaults.string(forKey: Keys.microphoneDeviceID) ?? ""
    }
}
