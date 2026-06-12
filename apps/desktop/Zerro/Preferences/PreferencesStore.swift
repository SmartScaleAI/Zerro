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
    enum Keys {
        static let microphoneDeviceID = "vf.microphone.deviceID"
        static let redactSecrets = "redactSecrets"
        static let selectedModelID = "selectedModelID"

        /// Every UserDefaults key persisted via this store. "Reset to
        /// Defaults" in App Behavior wipes exactly this set — never the
        /// Keychain entry, never the prompt history file, never the
        /// onboarding-completion flag (those have their own destructive
        /// affordances above the reset button in Settings).
        static let resettable: [String] = [
            microphoneDeviceID,
            redactSecrets,
            selectedModelID,
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

    /// Phase 3 — when on (the default), each keyframe's on-device OCR pass
    /// paints opaque boxes over any detected secret AND masks it as
    /// `[REDACTED]` in the text attached to the payload. Read fresh at
    /// recording-start time (like `microphoneDeviceID`) and carried to the
    /// processing pipeline, so a Settings change applies to the next recording.
    var redactSecrets: Bool {
        didSet { defaults.set(redactSecrets, forKey: Keys.redactSecrets) }
    }

    /// Phase 6 (multi-model) — the user's last-selected generation model, by
    /// registry wire id. Written by the model picker; read by the generation
    /// path, which sends it as the `model` field of `/generate`. Defaults to
    /// `ModelRegistry.defaultModelID` (the recommended model), and re-defaults
    /// if a persisted id ever drops out of the registry (kill-switched model),
    /// so the app never sends an id the server would 400.
    var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModelID) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.microphoneDeviceID = defaults.string(forKey: Keys.microphoneDeviceID) ?? ""
        // `object(forKey:)` (not `bool(forKey:)`) so an unset key falls back to
        // the privacy-on default instead of UserDefaults' false-for-missing.
        self.redactSecrets = defaults.object(forKey: Keys.redactSecrets) as? Bool
            ?? ProcessingConfig.redactSecretsDefault
        // Validate the persisted model against the registry: an unknown or
        // since-disabled id falls back to the default rather than riding to
        // the server as a guaranteed 400.
        if let storedModel = defaults.string(forKey: Keys.selectedModelID),
           let entry = ModelRegistry.entry(id: storedModel), entry.enabled {
            self.selectedModelID = storedModel
        } else {
            self.selectedModelID = ModelRegistry.defaultModelID
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
        redactSecrets = ProcessingConfig.redactSecretsDefault
        selectedModelID = ModelRegistry.defaultModelID
    }
}
