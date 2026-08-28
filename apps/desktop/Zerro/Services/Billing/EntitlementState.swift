//
//  EntitlementState.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  The entitlement model that the single recording-start gate reads through
//  `EntitlementStore.canGenerate`. This file is data only: the discrete
//  states a user's billing standing can be in. No clock, no networking, no
//  purchase logic — those live in `TrialManager` / `LicenseService` and only
//  ever WRITE these values; the gate only READS them.
//
//  Every state funds generation the same way: the user's own provider keys,
//  through the local pipeline. The states differ only in what the purchase
//  gate does. Community builds pin `.byok` and never consult any of this.
//
//  Access level mirrors `RecordingState`: `public` even
//  though the app is a single module, so the type composes cleanly with
//  other public surfaces and matches the heavily-documented enum style
//  the codebase uses for its state machines.
//

import Foundation

// MARK: - EntitlementState

/// The user's current billing standing, as the gate sees it. Exactly one
/// case is in effect at a time. Documented case-by-case in the same style
/// as `RecordingState` / `RecordingFailureReason` because, like those,
/// this enum is the source of truth a whole subsystem branches on.
public enum EntitlementState: Equatable {
    /// The local free trial is active with `daysRemaining` whole days left
    /// (1…`TrialManager.trialLengthDays`). Purely on-device: no account, no
    /// card, no network — the clock lives in the Keychain (see
    /// `TrialManager`). Generation and transcription use the user's own
    /// provider keys, exactly like `.byok`; only the purchase gate differs.
    /// Official builds only — community builds never enter trial states.
    case localTrial(daysRemaining: Int)

    /// The local free trial has elapsed and no license has been activated.
    /// The gate refuses this state: hitting record opens the purchase
    /// surface.
    case localTrialExpired

    /// A valid Zerro license is on file (activated and edition-compatible —
    /// see `LicenseService`). The user pays once for the app and funds
    /// generation directly with their own provider keys.
    case byok
}

extension EntitlementState {
    /// True when chat generation is funded with provider keys stored on this
    /// Mac — which is every state: the trial and the license use the same
    /// provider-key/model UI; only their purchase gate differs.
    var usesOwnProviderKeys: Bool { true }
}
