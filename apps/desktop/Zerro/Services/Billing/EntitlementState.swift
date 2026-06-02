//
//  EntitlementState.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  Phase A of the billing system — the entitlement model that the single
//  recording-start gate reads through `EntitlementStore.canGenerate`.
//  This file is data only: the discrete states a user's billing standing
//  can be in, plus the managed-subscription tier enum. No clock, no
//  networking, no purchase logic — those land in Phases B–F and only ever
//  WRITE these values; the gate only READS them.
//
//  Access level mirrors `RecordingState` / `OutputMode`: `public` even
//  though the app is a single module, so the type composes cleanly with
//  other public surfaces and matches the heavily-documented enum style
//  the codebase uses for its state machines.
//

import Foundation

// MARK: - ManagedTier

/// The two paid tiers of the managed (Zerro-hosted credits) subscription.
/// Display/marketing copy and the real per-tier credit allotment are
/// decided server-side in Phases D–E; this enum is just the stable
/// identifier the client persists and renders against.
public enum ManagedTier: String, Codable, Equatable, CaseIterable {
    /// Entry managed plan — the smaller monthly credit allotment.
    case starter
    /// Higher managed plan — the larger monthly credit allotment.
    case pro
}

// MARK: - EntitlementState

/// The user's current billing standing, as the gate sees it. Exactly one
/// case is in effect at a time. Documented case-by-case in the same style
/// as `RecordingState` / `RecordingFailureReason` because, like those,
/// this enum is the source of truth a whole subsystem branches on.
public enum EntitlementState: Equatable {
    /// Local 7-day trial active. `daysRemaining` is the clock countdown
    /// (computed by Phase B's TrialManager). `trialCreditsRemaining` is
    /// server-funded trial credits introduced in Phase F — `nil` until
    /// that backend exists, so Phase A always passes `nil`. The gate
    /// grants access on `.trial` in Phase A; Phase F additionally
    /// requires credits > 0, but that decision becomes server-side then.
    case trial(daysRemaining: Int, trialCreditsRemaining: Int?)

    /// Trial is over — either the clock ran out or (Phase F) the trial
    /// credits hit zero — and no purchase has been made. This is the one
    /// state the gate refuses: hitting record routes to the paywall.
    case expired

    /// Valid one-time BYOK ("bring your own key") license AND the user's
    /// own OpenAI key on file. The user pays once for the app and funds
    /// generation directly against their own OpenAI account. Phase C
    /// activates and validates the license; Phase A only models the state.
    case byok

    /// Active managed subscription on the given `tier`. `creditsRemaining`
    /// and `resetDate` are DISPLAY ONLY — they drive UI copy (the menu-bar
    /// credits line, a Settings readout) but are NOT the spend authority.
    /// The real "can this generation proceed" decision is made server-side
    /// against the proxy in Phases D–E; the client never gates on these
    /// numbers, it only shows them.
    case managed(tier: ManagedTier, creditsRemaining: Int, resetDate: Date)
}
