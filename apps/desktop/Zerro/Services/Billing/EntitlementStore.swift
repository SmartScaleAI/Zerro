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

    // MARK: - Dependencies

    /// The trial clock (Phase B). Injectable so tests can drive a fake
    /// Keychain + controllable clock; production uses the default, which
    /// reads the real Keychain slots.
    private let trialManager: TrialManager

    // MARK: - Init

    /// `nil` constructs the default real-Keychain `TrialManager` inside the
    /// (MainActor) body — a `TrialManager()` default-argument expression
    /// would be evaluated nonisolated and trip MainActor isolation. Tests
    /// and previews inject a manager over in-memory slots.
    init(trialManager: TrialManager? = nil) {
        let manager = trialManager ?? TrialManager()
        self.trialManager = manager
        // Phase B: the initial state is COMPUTED from the trial clock, not
        // hard-coded. We compute from the resolved `manager` (a local, so
        // this runs without touching `self`). Phase C will layer BYOK-license
        // detection and Phase D+ the backend's managed entitlement on top —
        // see the precedence marker in `computeState`.
        self.state = Self.computeState(using: manager)
    }

    // MARK: - State computation

    /// Derives the current `EntitlementState` from its real sources. In
    /// Phase B that's the trial clock alone; the precedence marker below is
    /// where Phases C/D slot their higher-priority sources in.
    ///
    /// `static` (takes the manager explicitly) so `init` can call it before
    /// `self` is fully initialized AND `refresh()` can reuse it.
    private static func computeState(using trialManager: TrialManager) -> EntitlementState {
        // First launch establishes the trial start (idempotent thereafter).
        trialManager.startTrialIfNeeded()

        // DEFERRED Phase C/D: BYOK/Managed entitlement takes precedence over
        // the trial clock here. When a valid `.byok` license or a backend
        // `.managed` entitlement is detected, return it BEFORE consulting the
        // clock below — a paid user is never downgraded to a trial/expired
        // state. Phase B has no such source yet, so the clock is the only one.

        switch trialManager.evaluate() {
        case .active(let daysRemaining):
            // `trialCreditsRemaining` stays nil — server-funded trial credits
            // are Phase F. The clock gates Layer 1 only.
            return .trial(daysRemaining: daysRemaining, trialCreditsRemaining: nil)
        case .expired:
            return .expired
        }
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

    /// Recomputes `state` from its real sources. Phase B re-runs the trial
    /// clock; Phases C/D add their sources via the precedence marker in
    /// `computeState`. Called at launch (via `init`) and at every
    /// record-start attempt (see `ZerroApp.handleHotkey`) so a trial that
    /// lapsed while the app sat idle is caught the moment the user tries to
    /// record, never honored stale.
    ///
    /// FAIL-OPEN CONTRACT (binding on every real implementation): on a
    /// TRANSIENT failure — a Keychain read error, a backend timeout, an
    /// offline check — `refresh()` must fail TOWARD granting access for a
    /// user who is already entitled. It must NEVER downgrade a known-good
    /// `.byok` / `.managed` / `.trial` to `.expired` just because a check
    /// couldn't complete. Locking a paying user out of their own tool over
    /// a flaky network is a far worse failure than briefly honoring an
    /// entitlement that has actually lapsed. Phase B honors this through
    /// `TrialManager`, which returns a GRANTING status on any genuine
    /// Keychain read failure and only ever returns `.expired` for a real
    /// elapsed-time expiry.
    func refresh() {
        #if DEBUG
        // A pinned dev override (devSetState) wins over the computed clock
        // until it's explicitly cleared — so forcing `.byok` from the dev
        // panel survives the record-start `refresh()`. The trial-clock dev
        // controls clear this flag first (they WANT to watch the clock be
        // recomputed); see `devClearOverride` / the dev clock methods.
        if devOverrideActive {
            Log.state.notice("entitlement refresh suppressed — dev override pinned")
            return
        }
        #endif
        state = Self.computeState(using: trialManager)
    }

    // MARK: - Dev override (DEBUG only)

    #if DEBUG
    /// When `true`, a manual `devSetState` override is pinned and `refresh()`
    /// won't recompute from the clock. Cleared by `devClearOverride` and by
    /// every trial-clock dev control (those want to SEE the clock recompute).
    private(set) var devOverrideActive = false

    /// Forces the store into an arbitrary state from the DEBUG dev panel /
    /// menu-bar debug section. The forced state is PINNED — it survives the
    /// record-start `refresh()` — until `devClearOverride` (or a trial-clock
    /// dev control) releases it. The primary way to exercise every gate
    /// branch (each `EntitlementState`). State case names are `.public` in
    /// the log line — no user content, like how `RecordingState` is logged.
    func devSetState(_ newState: EntitlementState) {
        devOverrideActive = true
        state = newState
        Log.ui.notice("entitlement dev override → \(String(describing: newState), privacy: .public)")
    }

    /// Releases a pinned override and recomputes from the trial clock, so
    /// the store returns to its real, clock-derived state on the next
    /// (non-dev) `refresh()` path.
    func devClearOverride() {
        devOverrideActive = false
        refresh()
        Log.ui.notice("entitlement dev override cleared → \(String(describing: self.state), privacy: .public)")
    }

    // MARK: - Trial-clock dev controls (DEBUG only)
    //
    // These manipulate the UNDERLYING clock (via TrialManager) and then
    // recompute — orthogonal to `devSetState`, which forces a state
    // directly. Each releases any pinned override first, because the whole
    // point is to watch `refresh()` derive the state from the clock.

    /// Rewrites the trial to a clean 7 days, then recomputes.
    func devResetTrial() {
        devOverrideActive = false
        trialManager.devResetTrial()
        refresh()
    }

    /// Forces the trial expired (start far in the past, ceiling pinned to
    /// now), then recomputes — drives `.expired` so ⌘⇧R opens the paywall.
    func devExpireTrial() {
        devOverrideActive = false
        trialManager.devExpireTrial()
        refresh()
    }

    /// Deletes the trial Keychain slots (simulates a truly-fresh install),
    /// then recomputes — `computeState` re-establishes a fresh 7-day trial.
    func devClearTrialKeychain() {
        devOverrideActive = false
        trialManager.devClearKeychain()
        refresh()
    }

    /// Steps the countdown down by one day, then recomputes.
    func devAdvanceTrialOneDay() {
        devOverrideActive = false
        trialManager.devAdvanceOneDay()
        refresh()
    }

    /// Preview convenience: a store pinned to `state` via the dev override,
    /// backed by an in-memory trial clock so previews never touch the real
    /// Keychain. (DEBUG-only; reference only from `#if DEBUG`-guarded
    /// previews so Release builds — which still compile `#Preview` bodies —
    /// don't see this symbol.)
    static func preview(_ state: EntitlementState) -> EntitlementStore {
        let store = EntitlementStore(trialManager: .inMemory())
        store.devSetState(state)
        return store
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
