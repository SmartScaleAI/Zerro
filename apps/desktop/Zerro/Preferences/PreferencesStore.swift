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

// MARK: - OutputMode
//
// Phase 11 introduced the persisted default for Phase 17's coming
// Instruct/Explain composer. Stored on PreferencesStore (not @AppStorage
// at the view layer) so downstream code in AppState / PromptGeneration
// can read it without dragging SwiftUI into non-view modules.

enum OutputMode: String, Codable, CaseIterable, Equatable {
    case instruct
    case explain

    var displayName: String {
        switch self {
        case .instruct: return "Instruct"
        case .explain:  return "Explain"
        }
    }
}

@MainActor
@Observable
final class PreferencesStore {

    // MARK: - Keys

    /// Stringly-typed UserDefaults keys, kept in one place so they don't
    /// leak into call sites the way `@AppStorage("…")` literals tend to.
    enum Keys {
        static let microphoneDeviceID = "vf.microphone.deviceID"
        static let defaultOutputMode = "defaultOutputMode"

        /// Every UserDefaults key persisted via this store. "Reset to
        /// Defaults" in App Behavior wipes exactly this set — never the
        /// Keychain entry, never the prompt history file, never the
        /// onboarding-completion flag (those have their own destructive
        /// affordances above the reset button in Settings).
        static let resettable: [String] = [
            microphoneDeviceID,
            defaultOutputMode,
        ]
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

    /// The default output mode the next recording will use unless Phase
    /// 17's mode-switch detector + confirmation pill route it elsewhere.
    /// Phase 11 only persists this — no downstream wiring yet.
    var defaultOutputMode: OutputMode {
        didSet { defaults.set(defaultOutputMode.rawValue, forKey: Keys.defaultOutputMode) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.microphoneDeviceID = defaults.string(forKey: Keys.microphoneDeviceID) ?? ""
        if let rawMode = defaults.string(forKey: Keys.defaultOutputMode),
           let mode = OutputMode(rawValue: rawMode) {
            self.defaultOutputMode = mode
        } else {
            self.defaultOutputMode = .instruct
        }
    }

    // MARK: - Reset

    /// Wipes every UserDefaults key this store owns. Called from the App
    /// Behavior "Reset to Defaults" button. Keychain, prompt history,
    /// and onboarding-completion flag are all intentionally excluded —
    /// each has its own destructive affordance in the same Settings
    /// surface, so this button can stay narrowly-scoped to "preferences".
    func resetToDefaults() {
        for key in Keys.resettable {
            defaults.removeObject(forKey: key)
        }
        // Reload from defaults so observers see the reset value
        // immediately, even before the next launch.
        microphoneDeviceID = ""
        defaultOutputMode = .instruct
    }
}
