//
//  STTEngine.swift
//  Zerro
//
//  Which speech-to-text engine the BYOK/local path should use. Persisted (as the
//  raw string) via `PreferencesStore.sttEngine`; consumed by the STT router that
//  a later phase adds (mirroring `BYOKRouting`). Introduced now so the preference
//  exists ahead of the routing rewire.
//

import Foundation

/// - `auto`  — local when the on-device model is ready, else cloud (OpenAI) when
///   a key is present. The default; keeps the rollout non-breaking.
/// - `local` — always on-device whisper.cpp (requires the model installed).
/// - `cloud` — always OpenAI Whisper (requires an OpenAI key).
nonisolated enum STTEngine: String, CaseIterable, Sendable {
    case auto
    case local
    case cloud

    /// User-facing label for the Settings engine picker.
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .local: return "On-device"
        case .cloud: return "OpenAI cloud"
        }
    }
}
