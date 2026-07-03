//
//  STTRouting.swift
//  Zerro
//
//  Phase 3 (Local Whisper) — the speech-to-text routing seam, mirroring
//  `BYOKRouting`: a PURE, parameterized decision (availability is passed in; no
//  Keychain/disk reads happen here) that maps the user's `sttEngine` preference
//  plus the current availability signals onto a concrete `TranscriptionService`,
//  or a precise "what's missing" result the caller turns into a typed error.
//
//  The single caller is `AppState`'s transcription step. Kept synchronous and
//  fully unit-testable: the service factories are injectable, so the truth table
//  runs against fakes without a real model file or an OpenAI key.
//

import Foundation

// MARK: - STTResolution

/// The outcome of STT routing: a ready service (tagged with whether it's the
/// ON-DEVICE local engine vs cloud, reported from what `resolve` ACTUALLY built),
/// or the one prerequisite the caller must surface (mapped to `.modelUnavailable`
/// / `.missingAPIKey`).
enum STTResolution {
    /// A ready service. `isLocal` is what `resolve` built — local whisper.cpp
    /// (`true`) vs cloud OpenAI Whisper (`false`) — so the caller reads locality
    /// straight off the resolution instead of recomputing it. This closes the
    /// P7-1 race where `.auto` falls back to cloud (because `buildLocal` returned
    /// nil for a vanished file) while a recomputed `isLocal` still said `true`.
    case service(any TranscriptionService, isLocal: Bool)
    case needsLocalModel
    case needsOpenAIKey
}

// MARK: - STTRouting

enum STTRouting {

    /// The SINGLE SOURCE OF TRUTH for "can STT resolve to a usable service?",
    /// given the two availability signals. Pure boolean predicate shared by the
    /// entitlement-routing decision (Phase 4 `canGenerateLocally`), the
    /// record-start pre-flight, and `resolve` itself, so the three can never
    /// disagree about whether a recording could be transcribed. Mirrors
    /// `resolve`'s rules EXACTLY:
    ///   • `.auto`  → a local model OR an OpenAI key (either path works).
    ///   • `.local` → the local model is installed (the key is irrelevant).
    ///   • `.cloud` → an OpenAI key is present (the model is irrelevant).
    ///
    /// `modelInstalled` is the CHEAP, hash-free signal (`LocalModelManager`
    /// `installedModelURL != nil`, punchlist P2-1) — never `isModelReady`, which
    /// re-hashes ~547 MB.
    static func canResolve(engine: STTEngine, modelInstalled: Bool, openAIKeyPresent: Bool) -> Bool {
        switch engine {
        case .auto:  return modelInstalled || openAIKeyPresent
        case .local: return modelInstalled
        case .cloud: return openAIKeyPresent
        }
    }

    /// Resolve the transcription service for a recording. PURE: `modelInstalled`,
    /// `openAIKeyPresent`, and `localModelURL` are passed in — the caller reads
    /// them cheaply (`LocalModelManager.installedModelURL` for the model — a
    /// hash-free check — and `ProviderKeys` for the key). Rules:
    ///   • `.auto`  → local if the model is installed; else cloud if an OpenAI key
    ///                is present; else `.needsOpenAIKey`.
    ///   • `.local` → local if the model is installed; else `.needsLocalModel`.
    ///   • `.cloud` → cloud if an OpenAI key is present; else `.needsOpenAIKey`.
    ///
    /// `makeLocalService` / `makeCloudService` are injectable for tests; `nil`
    /// builds the real services (on-device whisper.cpp at `.largeV3Turbo`; cloud
    /// OpenAI Whisper). `makeLocalService` may return `nil` if the local engine
    /// can't be constructed (e.g. the file vanished between the cheap check and
    /// here) — treated as "model not available".
    static func resolve(
        engine: STTEngine,
        modelInstalled: Bool,
        openAIKeyPresent: Bool,
        localModelURL: URL?,
        makeLocalService: ((URL) -> (any TranscriptionService)?)? = nil,
        makeCloudService: (() -> any TranscriptionService)? = nil
    ) -> STTResolution {
        let buildLocal = makeLocalService ?? { url in
            try? WhisperCppTranscriptionService(modelURL: url, model: .largeV3Turbo)
        }
        let buildCloud = makeCloudService ?? { OpenAITranscriptionService() }

        func localService() -> (any TranscriptionService)? {
            guard modelInstalled, let url = localModelURL else { return nil }
            return buildLocal(url)
        }
        func cloudOrNeedsKey() -> STTResolution {
            openAIKeyPresent ? .service(buildCloud(), isLocal: false) : .needsOpenAIKey
        }

        switch engine {
        case .auto:
            // Local when the model built; otherwise cloud. Reporting locality here
            // (not recomputed by the caller) means a vanished-file fallback to
            // cloud is tagged `isLocal: false`, never a phantom local (P7-1).
            if let local = localService() { return .service(local, isLocal: true) }
            return cloudOrNeedsKey()
        case .local:
            if let local = localService() { return .service(local, isLocal: true) }
            return .needsLocalModel
        case .cloud:
            return cloudOrNeedsKey()
        }
    }
}
