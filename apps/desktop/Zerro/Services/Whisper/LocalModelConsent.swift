//
//  LocalModelConsent.swift
//  Zerro
//
//  Phase 5 (Local Whisper) — the PURE decision for whether the one-time first-key
//  model-download consent prompt should be shown. Separated from the presentation
//  (the NSAlert in `APIAuthSection`) so the gating is unit-testable in isolation.
//

import Foundation

enum LocalModelConsent {
    /// Show the consent prompt only when ALL of these hold:
    ///   • `isFirstKey`  — this save added the user's FIRST API key across all
    ///     providers (captured BEFORE the Keychain write makes it non-empty).
    ///   • `!alreadyShown` — the one-time prompt hasn't fired before
    ///     (`PreferencesStore.localModelPromptShown`).
    ///   • `!modelReady` — the on-device model isn't already installed.
    static func shouldPrompt(isFirstKey: Bool, alreadyShown: Bool, modelReady: Bool) -> Bool {
        isFirstKey && !alreadyShown && !modelReady
    }
}
