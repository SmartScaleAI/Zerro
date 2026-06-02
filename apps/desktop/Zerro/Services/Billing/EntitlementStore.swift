//
//  EntitlementStore.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  Phase A of the billing system — the long-lived, observable holder of
//  the current `EntitlementState` and the single predicate the recording
//  gate reads (`canGenerate`). Owned by `ZerroApp` as @State for the app's
//  lifetime and injected into the menu-bar content, the Settings window,
//  and the Paywall window via the SwiftUI environment, exactly like
//  `AppState` / `PermissionsManager`.
//
//  Phase A deliberately has no real source of truth: `state` is a safe
//  placeholder (a fresh 7-day trial) and `refresh()` is a stub. Phases
//  B–F replace the placeholder with a real computation (trial clock,
//  BYOK license, backend entitlement). Everything here is structured so
//  those phases only have to fill in the body of `refresh()` and the
//  initial-state computation — the gate's contract never changes.
//
//  @MainActor @Observable to match the rest of the app's state objects;
//  SwiftUI surfaces read `state` / `canGenerate` directly from the
//  environment.
//

import Foundation
import os

@MainActor
@Observable
final class EntitlementStore {

    // MARK: - State

    /// The current entitlement standing. Read-only to the outside world —
    /// nothing but this store (and, in DEBUG, the dev override) mutates it,
    /// so the gate and any UI always see a value that came through here.
    private(set) var state: EntitlementState

    // MARK: - Init

    init() {
        // DEFERRED Phase B: the real initial state is COMPUTED, not
        // hard-coded — Phase B's TrialManager reads the trial start date
        // from the Keychain and derives `.trial(daysRemaining:)` or
        // `.expired`; Phase C layers BYOK-license detection on top; Phase
        // D+ layers the backend's managed entitlement. Until any of that
        // exists, a fresh 7-day trial is the safe placeholder: it grants
        // access (so a half-built billing layer can never lock out a real
        // user during development) while still being a non-`.expired`
        // value that exercises the common path.
        self.state = .trial(daysRemaining: 7, trialCreditsRemaining: nil)
    }

    // MARK: - Gate predicate

    /// The single predicate the recording-start gate consults (see
    /// `ZerroApp.handleHotkey`). True means "let the user reach the area
    /// selector and start a capture"; false means "route to the paywall
    /// instead." Defined here, in one place, so the gate never re-derives
    /// access rules at the call site.
    ///
    /// Phase A rules (the server-side decisions noted inline arrive later):
    ///   • `.trial`   → true. Phase F will additionally require trial
    ///                  credits > 0, but that check becomes server-side then.
    ///   • `.byok`    → true. The user funds generation with their own key.
    ///   • `.managed` → true. The real per-generation credit check is
    ///                  server-side in Phase E; the client never gates on
    ///                  `creditsRemaining`.
    ///   • `.expired` → false. The only refusing state.
    var canGenerate: Bool {
        switch state {
        case .trial, .byok, .managed:
            return true
        case .expired:
            return false
        }
    }

    // MARK: - Refresh

    /// Recomputes `state` from its real sources. In Phase A this is a stub
    /// that re-applies the current value (a no-op) — there is nothing yet
    /// to recompute — but it exists now so call sites and the contract are
    /// in place from the start.
    ///
    /// DEFERRED Phase B+: compute from TrialManager (clock) / LicenseService
    /// (BYOK) / backend entitlement (Managed).
    ///
    /// FAIL-OPEN CONTRACT (binding on every future real implementation):
    /// on a TRANSIENT failure — a Keychain read error, a backend timeout,
    /// an offline check — `refresh()` must fail TOWARD granting access for
    /// a user who is already entitled. It must NEVER downgrade a known-good
    /// `.byok` / `.managed` / `.trial` to `.expired` just because a check
    /// couldn't complete. Locking a paying user out of their own tool over
    /// a flaky network is a far worse failure than briefly honoring an
    /// entitlement that has actually lapsed. Phase A has nothing that can
    /// fail, but this comment fixes the rule before the code that could.
    func refresh() {
        // No-op in Phase A: re-applying the current state is the whole
        // operation. The assignment is intentional (not deleted) so the
        // shape is obvious to the phase that fills this in.
        state = state
    }

    // MARK: - Dev override (DEBUG only)

    #if DEBUG
    /// Forces the store into an arbitrary state from the DEBUG dev panel /
    /// menu-bar debug section. This is the ONLY mutation path in Phase A
    /// besides `init`, and the primary way to exercise every gate branch
    /// (each `EntitlementState`) before Phases B–E compute the state for
    /// real. State case names are `.public` in the log line — they carry
    /// no user content, consistent with how `RecordingState` is logged.
    func devSetState(_ newState: EntitlementState) {
        state = newState
        Log.ui.notice("entitlement dev override → \(String(describing: newState), privacy: .public)")
    }

    /// The full set of states the dev panel can force, paired with short
    /// labels. Kept here so the paywall dev panel and the menu-bar debug
    /// rows iterate one source of truth rather than each hard-coding the
    /// list. The managed `resetDate` is a plausible ~30-days-out display
    /// value; nothing gates on it (display-only per `EntitlementState`).
    static var devStates: [(label: String, state: EntitlementState)] {
        let resetDate = Date().addingTimeInterval(60 * 60 * 24 * 30)
        return [
            ("Trial", .trial(daysRemaining: 7, trialCreditsRemaining: nil)),
            ("Expired", .expired),
            ("BYOK", .byok),
            ("Managed · Starter", .managed(tier: .starter, creditsRemaining: 100, resetDate: resetDate)),
            ("Managed · Pro", .managed(tier: .pro, creditsRemaining: 300, resetDate: resetDate)),
        ]
    }

    /// Whether `candidate` is the currently-active state, for selected-pill
    /// rendering in the dev panel. Compares by case identity so two
    /// `.managed` tiers (or two `.trial`s with different day counts) read
    /// as the "same" dev selection regardless of the throwaway numbers.
    func devMatches(_ candidate: EntitlementState) -> Bool {
        switch (state, candidate) {
        case (.trial, .trial), (.expired, .expired), (.byok, .byok):
            return true
        case let (.managed(lhsTier, _, _), .managed(rhsTier, _, _)):
            return lhsTier == rhsTier
        default:
            return false
        }
    }
    #endif
}
