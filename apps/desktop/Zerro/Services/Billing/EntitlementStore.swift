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

    /// The BYOK license layer (Phase C). Owns the license Keychain slots and
    /// the three LemonSqueezy calls; consulted SYNCHRONOUSLY (no network) for
    /// startup precedence and ASYNCHRONOUSLY for throttled re-validation.
    /// Injectable for tests/previews (in-memory slots + stubbed transport).
    private let licenseService: LicenseService

    // MARK: - Init

    /// `nil` constructs the default real-Keychain dependencies inside the
    /// (MainActor) body — a `TrialManager()` / `LicenseService()` default-
    /// argument expression would be evaluated nonisolated and trip MainActor
    /// isolation. Tests and previews inject fakes over in-memory slots.
    init(trialManager: TrialManager? = nil, licenseService: LicenseService? = nil) {
        let manager = trialManager ?? TrialManager()
        let license = licenseService ?? LicenseService()
        self.trialManager = manager
        self.licenseService = license
        // Phase B/C: the initial state is COMPUTED, not hard-coded — from the
        // resolved locals (so this runs without touching `self`). Phase C
        // layers BYOK-license precedence on top of the trial clock; Phase D+
        // adds the backend's managed entitlement — see `computeState`.
        self.state = Self.computeState(trialManager: manager, licenseService: license)
    }

    // MARK: - State computation

    /// Derives the current `EntitlementState` from its real sources, in
    /// precedence order. The DEBUG override (in `refresh`) sits above all of
    /// this; Managed (Phase D) will sit above BYOK; BYOK (Phase C) sits above
    /// the trial clock (Phase B).
    ///
    /// `static` (takes the dependencies explicitly) so `init` can call it
    /// before `self` is fully initialized AND `refresh()` can reuse it.
    private static func computeState(
        trialManager: TrialManager,
        licenseService: LicenseService
    ) -> EntitlementState {
        // First launch establishes the trial start (idempotent thereafter).
        trialManager.startTrialIfNeeded()

        // DEFERRED Phase D: Managed entitlement takes precedence here too —
        // when a backend `.managed` entitlement is present, return it BEFORE
        // the BYOK/trial checks below. No such source exists yet.

        // Phase C: a present (or, fail-open, indeterminate) cached BYOK license
        // OUTRANKS the trial clock — a licensed user is `.byok` regardless of
        // trial days. This is a SYNCHRONOUS Keychain read only; we never block
        // startup on a network call. A later background `validate()` may
        // downgrade a refunded/revoked license (see `revalidateLicenseIfNeeded`),
        // but synchronously a present license means `.byok`.
        //
        // FAIL-OPEN: `grantsBYOK` is true for `.present` AND `.indeterminate`
        // (a genuine Keychain read error), so a flaky read can never drop a
        // licensed-past-trial user to `.expired`. Only a DEFINITIVE `.absent`
        // falls through to the clock.
        if licenseService.currentLicenseState().grantsBYOK {
            return .byok
        }

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
        state = Self.computeState(trialManager: trialManager, licenseService: licenseService)
    }

    // MARK: - BYOK license (Phase C)

    /// Activates `licenseKey` online (paywall / Settings entry point). On
    /// success the `LicenseService` has written the credentials to the
    /// Keychain, so we transition straight to `.byok` (a present license is
    /// `.byok` per `computeState` anyway) WITHOUT touching the trial clock —
    /// a valid license simply outranks it. Rethrows the `LicenseError` so the
    /// UI can branch (at-activation-limit, key invalid, network, …).
    @discardableResult
    func activate(licenseKey: String) async throws -> ActivationResult {
        let result = try await licenseService.activate(licenseKey: licenseKey)
        #if DEBUG
        // A successful real activation releases any pinned dev override — the
        // user's actual entitlement should now win.
        devOverrideActive = false
        #endif
        state = .byok
        Log.billing.notice("entitlement \u{2192} byok via activation (instance=\(result.instanceID, privacy: .public))")
        return result
    }

    /// Deactivates THIS device's license: frees the LemonSqueezy machine slot,
    /// clears the local credentials, and recomputes the entitlement (which
    /// now falls through to the trial clock → `.trial`/`.expired`). Used by the
    /// Settings "Deactivate this device" button. Rethrows on failure; on a
    /// network failure the local license is LEFT INTACT (we didn't free the
    /// slot, so we mustn't drop the user's access).
    func deactivateThisDevice() async throws {
        if let instanceID = licenseService.currentInstanceID() {
            try await licenseService.deactivate(instanceID: instanceID)
        }
        // Only reached if the network deactivation succeeded (or there was no
        // instance on file to free): clear local credentials and recompute.
        licenseService.clearLicense()
        refresh()
        Log.billing.notice("entitlement \u{2192} deactivated this device; recomputed to \(String(describing: self.state), privacy: .public)")
    }

    /// Background, THROTTLED re-validation. Called at launch (see `ZerroApp`).
    /// Does nothing unless a license is actually present and the throttle
    /// window (`LicenseService.revalidationInterval`) has elapsed — so the app
    /// is offline-first and re-hits LemonSqueezy at most ~weekly. The verdict:
    ///   • DEFINITIVE revocation (`valid:false` disabled/expired) → clear the
    ///     license and drop to the trial/expired computation (refund handling).
    ///   • valid / non-definitive / network failure → stay `.byok` (FAIL OPEN).
    func revalidateLicenseIfNeeded() async {
        guard licenseService.currentLicenseState().presence == .present else {
            // Absent → nothing to validate. Indeterminate → a transient
            // Keychain read failure; skip and retry next launch (we already
            // fail-open to `.byok` in `computeState`, so access isn't blocked).
            return
        }
        guard licenseService.shouldRevalidate() else {
            Log.billing.info("license revalidation skipped — within \(Int(LicenseService.revalidationInterval), privacy: .public)s throttle window")
            return
        }
        await performRevalidation()
    }

    /// The validate-and-apply core, with NO throttle guard. Shared by the
    /// throttled launch path and (DEBUG) the force-revalidate dev control.
    private func performRevalidation() async {
        do {
            let result = try await licenseService.validate()
            if result.isDefinitiveRevocation {
                Log.billing.notice("license revoked (status=\(result.status?.rawValue ?? "unknown", privacy: .public)) — clearing, dropping to trial/expired")
                licenseService.clearLicense()
                refresh()
            }
            // valid / non-definitive negative → stay `.byok`. `validate()`
            // already refreshed the throttle stamp on a `valid` result.
        } catch {
            // Network/inconclusive → FAIL OPEN. Keep the license, retry next
            // launch. A paying user is never locked out by a flaky network —
            // only a definitive LemonSqueezy negative de-activates them.
            Log.billing.error("license revalidation inconclusive — failing open, keeping .byok")
        }
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
        let store = EntitlementStore(trialManager: .inMemory(), licenseService: .inMemory())
        store.devSetState(state)
        return store
    }

    /// DEBUG: force a license re-validation NOW, ignoring the throttle, so the
    /// refund/revoke and fail-open paths can be exercised from the Billing
    /// section without waiting out `revalidationInterval`. Requires a real
    /// (test-mode) license to already be activated.
    func devRevalidateLicenseNow() async {
        Log.billing.notice("DEV: forcing license revalidation (ignoring throttle)")
        devOverrideActive = false
        await performRevalidation()
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
