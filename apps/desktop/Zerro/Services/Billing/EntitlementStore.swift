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

// MARK: - LicenseProductKind

/// Which LemonSqueezy product an on-file license belongs to. Both products
/// issue a license key activated through the SAME path (Phase C), so the key
/// alone can't tell them apart — this is resolved at activation by probing
/// `/session` and persisted in the Keychain (`KeychainStore.licenseProductKind`)
/// so startup precedence is a synchronous read. Raw values are the stored
/// strings.
enum LicenseProductKind: String, Equatable {
    /// One-time BYOK license — the user funds generation with their own OpenAI
    /// key (the direct, fully-local path).
    case byok
    /// Managed subscription — generation routes through the Zerro-hosted proxy
    /// on server-funded credits.
    case managed
}

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

    /// The Managed auth layer (Phase E). Exchanges the stored license key for a
    /// short-lived session token + entitlement snapshot. Used here to
    /// DISAMBIGUATE a Managed subscription key from a BYOK one at activation
    /// (`establishSession` returns a tier for Managed, `notEntitled` for BYOK)
    /// and to refresh the display snapshot. Injectable for tests/previews.
    private let sessionTokens: SessionTokenManager

    /// Records WHICH product the on-file license belongs to ("byok"/"managed"),
    /// read synchronously at startup so `computeState` picks the right
    /// precedence branch without a network call. See `KeychainStore.licenseProductKind`.
    private let productKindSlot: KeychainSlot

    /// Backs the display-only Managed entitlement cache (credits/tier/reset/
    /// status). Persisted (non-secret) so the menu-bar credits line is correct
    /// at launch before the async `/entitlement` refresh lands. Injectable so
    /// tests use a volatile suite.
    private let defaults: UserDefaults

    /// UserDefaults key for the cached Managed snapshot JSON.
    private static let managedSnapshotKey = "managed_entitlement_snapshot_v1"

    // MARK: - Managed display state (Phase E)

    /// The current Managed entitlement snapshot — tier, credits, reset date, and
    /// `status` (drives the past-due nudge). DISPLAY ONLY: the server is the
    /// spend authority (`generate`); the app never gates on these numbers, it
    /// only renders them. `nil` whenever the user isn't Managed.
    private(set) var managedSnapshot: ManagedEntitlementSnapshot?

    // MARK: - Init

    /// `nil` constructs the default real-Keychain dependencies inside the
    /// (MainActor) body — a `TrialManager()` / `LicenseService()` default-
    /// argument expression would be evaluated nonisolated and trip MainActor
    /// isolation. Tests and previews inject fakes over in-memory slots.
    init(
        trialManager: TrialManager? = nil,
        licenseService: LicenseService? = nil,
        sessionTokens: SessionTokenManager? = nil,
        productKindSlot: KeychainSlot? = nil,
        defaults: UserDefaults = .standard
    ) {
        let manager = trialManager ?? TrialManager()
        let license = licenseService ?? LicenseService()
        let tokens = sessionTokens ?? SessionTokenManager()
        let kindSlot = productKindSlot ?? KeychainStore.licenseProductKind
        self.trialManager = manager
        self.licenseService = license
        self.sessionTokens = tokens
        self.productKindSlot = kindSlot
        self.defaults = defaults
        // Seed the Managed display snapshot from the local cache so a Managed
        // user's credits line is correct at launch (refreshed async shortly
        // after). Decoded from the resolved local (no `self` access yet).
        let cached = Self.loadCachedSnapshot(from: defaults)
        self.managedSnapshot = cached
        // Phase B/C/E: the initial state is COMPUTED, not hard-coded — from the
        // resolved locals (so this runs without touching `self`). Precedence:
        // Managed (Phase E) > BYOK (Phase C) > trial (Phase B) > expired.
        self.state = Self.computeState(
            trialManager: manager,
            licenseService: license,
            productKind: Self.readProductKind(from: kindSlot),
            cachedSnapshot: cached
        )
    }

    // MARK: - State computation

    /// Derives the current `EntitlementState` from its real sources, in
    /// precedence order: Managed subscription > BYOK license > trial clock >
    /// expired. The DEBUG override (in `refresh`) sits above all of this.
    ///
    /// `static` (takes the dependencies explicitly) so `init` can call it
    /// before `self` is fully initialized AND `refresh()` can reuse it.
    private static func computeState(
        trialManager: TrialManager,
        licenseService: LicenseService,
        productKind: LicenseProductKind?,
        cachedSnapshot: ManagedEntitlementSnapshot?
    ) -> EntitlementState {
        // First launch establishes the trial start (idempotent thereafter).
        trialManager.startTrialIfNeeded()

        // Phase E: a present (or, fail-open, indeterminate) cached license
        // OUTRANKS the trial clock. WHICH paid state it grants depends on the
        // recorded product kind:
        //   • managed → `.managed(...)` (routes generation through the proxy);
        //     display values come from the cached snapshot, or a placeholder
        //     until the async `/entitlement` refresh fills them in.
        //   • byok / unresolved → `.byok` (the local-funded path). Defaulting
        //     an UNRESOLVED kind to `.byok` is the safe fail-open direction: it
        //     never authorizes a server-funded generation (the proxy is the
        //     spend authority regardless), and a background re-probe upgrades a
        //     real Managed key to `.managed` shortly after launch.
        //
        // This is a SYNCHRONOUS Keychain read only — never a network call.
        // FAIL-OPEN: `grantsBYOK` is true for `.present` AND `.indeterminate`
        // (a genuine Keychain read error), so a flaky read can't drop a paid
        // user to `.expired`. Only a DEFINITIVE `.absent` falls to the clock.
        if licenseService.currentLicenseState().grantsBYOK {
            if productKind == .managed {
                return managedState(from: cachedSnapshot)
            }
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

    /// Builds the `.managed` state from a snapshot (or a neutral placeholder if
    /// none is cached yet — the async refresh replaces it within ~1s). The
    /// associated values are DISPLAY ONLY; nothing gates on them.
    private static func managedState(from snapshot: ManagedEntitlementSnapshot?) -> EntitlementState {
        guard let snapshot else {
            // No snapshot yet (e.g. a same-build reinstall cleared the cache but
            // the Keychain license + kind survived). Placeholder until refresh.
            return .managed(tier: .starter, creditsRemaining: 0, resetDate: .distantFuture)
        }
        return .managed(
            tier: snapshot.tier,
            creditsRemaining: snapshot.creditsRemaining,
            resetDate: snapshot.resetDate ?? .distantFuture
        )
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
        state = Self.computeState(
            trialManager: trialManager,
            licenseService: licenseService,
            productKind: readProductKind(),
            cachedSnapshot: managedSnapshot
        )
    }

    // MARK: - Licensing (Phase C BYOK + Phase E Managed)

    /// Activates `licenseKey` online (paywall / Settings entry point) and then
    /// resolves WHICH product it is, so the entitlement lands on the right
    /// paid state:
    ///
    ///   1. `LicenseService.activate` — the SAME LemonSqueezy call for both
    ///      products (a Managed subscription issues a license key exactly like
    ///      BYOK). On success the key + instance are in the Keychain.
    ///   2. Probe `/session` with the key: a Managed subscription resolves
    ///      against the backend mirror and returns a tier + entitlement
    ///      snapshot → record kind `.managed`, cache the snapshot, set
    ///      `.managed`. A BYOK key isn't in the mirror and comes back
    ///      `notEntitled` → record kind `.byok`, set `.byok`.
    ///   3. If the probe can't complete (network), fall back to `expectedProduct`
    ///      (the caller's hint: the Subscribe buttons pass `.managed`, the
    ///      "enter license" field passes `.byok`/`nil`) and re-probe at the next
    ///      launch. We never block activation on the probe.
    ///
    /// Disambiguation is delegated to the backend (the cleanest signal — the
    /// `subscriptions` table holds only Managed keys), per the Phase E plan.
    /// Rethrows the `LicenseError` from step 1 so the UI can branch
    /// (at-activation-limit, key invalid, network, …); the probe in step 2
    /// NEVER rethrows — a probe failure only affects which paid state we pick.
    @discardableResult
    func activate(licenseKey: String, expectedProduct: LicenseProductKind? = nil) async throws -> ActivationResult {
        let result = try await licenseService.activate(licenseKey: licenseKey)
        #if DEBUG
        // A successful real activation releases any pinned dev override — the
        // user's actual entitlement should now win.
        devOverrideActive = false
        #endif

        // Step 2: disambiguate via the backend. The session manager reads the
        // just-written key from the SAME Keychain slot.
        do {
            let snapshot = try await sessionTokens.establishSession()
            // It's a live Managed subscription.
            recordProductKind(.managed)
            applyManagedSnapshot(snapshot)
            Log.billing.notice("entitlement → managed via activation (tier=\(snapshot.tier.rawValue, privacy: .public) instance=\(result.instanceID, privacy: .public))")
        } catch ManagedSessionError.notEntitled {
            // Not in the subscriptions mirror → a BYOK one-time license.
            recordProductKind(.byok)
            clearManagedSnapshot()
            state = .byok
            Log.billing.notice("entitlement → byok via activation (instance=\(result.instanceID, privacy: .public))")
        } catch {
            // Probe inconclusive (network/server). Fall back to the caller's
            // hint; a launch re-probe resolves it. Default to `.byok` (the safe,
            // server-money-free path) when there's no hint.
            let resolved = expectedProduct ?? .byok
            recordProductKind(resolved)
            if resolved == .managed {
                // Optimistically route through the proxy; the server enforces
                // credits regardless, so a wrong optimistic guess never spends.
                state = Self.managedState(from: managedSnapshot)
                Log.billing.notice("entitlement → managed (optimistic; probe inconclusive) instance=\(result.instanceID, privacy: .public)")
            } else {
                clearManagedSnapshot()
                state = .byok
                Log.billing.notice("entitlement → byok (probe inconclusive) instance=\(result.instanceID, privacy: .public)")
            }
        }
        return result
    }

    /// Deactivates THIS device's license: frees the LemonSqueezy machine slot,
    /// clears the local credentials + product kind + Managed snapshot + session
    /// token, and recomputes the entitlement (which now falls through to the
    /// trial clock → `.trial`/`.expired`). Used by the Settings "Deactivate this
    /// device" button. Rethrows on failure; on a network failure the local
    /// license is LEFT INTACT (we didn't free the slot, so we mustn't drop the
    /// user's access).
    func deactivateThisDevice() async throws {
        if let instanceID = licenseService.currentInstanceID() {
            try await licenseService.deactivate(instanceID: instanceID)
        }
        // Only reached if the network deactivation succeeded (or there was no
        // instance on file to free): clear local credentials and recompute.
        licenseService.clearLicense()
        clearProductKind()
        clearManagedSnapshot()
        sessionTokens.invalidate()
        refresh()
        Log.billing.notice("entitlement \u{2192} deactivated this device; recomputed to \(String(describing: self.state), privacy: .public)")
    }

    // MARK: - Managed entitlement (Phase E)

    /// True when generation must route through the Managed proxy
    /// (`ManagedProxyClient`) rather than the direct BYOK OpenAI path. The
    /// single branch point AppState reads. Only `.managed` routes through the
    /// proxy; `.byok` stays fully local.
    var routesThroughManagedProxy: Bool {
        if case .managed = state { return true }
        return false
    }

    /// Refreshes the DISPLAY-ONLY Managed snapshot from `/entitlement`. Cheap;
    /// callers don't block the UI on it (launch, post-activation, after each
    /// generation). Honors the fail-open / fail-closed split:
    ///   • A definitive `notEntitled` (subscription cancelled/expired, or the
    ///     key vanished from the mirror) DROPS the user out of `.managed` —
    ///     clears the license + snapshot and recomputes to trial/expired. This
    ///     mirrors the BYOK definitive-revocation path.
    ///   • Any transient failure (network/server/rate-limit) FAILS OPEN: keep
    ///     the cached `.managed` state untouched. A blip never locks out a payer.
    /// No-op unless the user is currently `.managed`.
    func refreshManagedEntitlement() async {
        guard routesThroughManagedProxy else { return }
        do {
            let snapshot = try await sessionTokens.fetchEntitlement()
            guard snapshot.status.isLive else {
                // Backend reports a terminal status — treat like a definitive
                // revocation.
                handleManagedRevocation(reason: "status=\(snapshot.status.rawValue)")
                return
            }
            applyManagedSnapshot(snapshot)
        } catch ManagedSessionError.notEntitled {
            handleManagedRevocation(reason: "not_entitled")
        } catch {
            // Transient — fail open, keep the cached managed state.
            Log.billing.info("managed entitlement refresh inconclusive — keeping cached snapshot (fail-open)")
        }
    }

    /// Updates the credits line immediately from a just-completed generation's
    /// `credits_remaining`, before the authoritative `/entitlement` refresh
    /// lands. No-op if not Managed or no snapshot is cached.
    func applyCreditsRemaining(_ remaining: Int) {
        guard routesThroughManagedProxy, let snapshot = managedSnapshot else { return }
        applyManagedSnapshot(snapshot.withCreditsRemaining(remaining))
    }

    /// Adopts a fresh snapshot: caches it (memory + UserDefaults) and recomputes
    /// the `.managed` state's display values from it. The single place state and
    /// snapshot are kept in lockstep.
    private func applyManagedSnapshot(_ snapshot: ManagedEntitlementSnapshot) {
        managedSnapshot = snapshot
        saveCachedSnapshot(snapshot)
        #if DEBUG
        // A live snapshot is the user's real entitlement — release any pinned
        // dev override so it wins (matches the activation path).
        if devOverrideActive { devOverrideActive = false }
        #endif
        state = Self.managedState(from: snapshot)
    }

    /// Definitive Managed revocation (cancelled/expired/key-gone). Clears the
    /// license + product kind + snapshot + session and recomputes — the app
    /// drops to the paywall on the next entitlement read. Mirrors BYOK's
    /// definitive-revocation handling.
    private func handleManagedRevocation(reason: String) {
        Log.billing.notice("managed subscription revoked (\(reason, privacy: .public)) — clearing, dropping to trial/expired")
        licenseService.clearLicense()
        clearProductKind()
        clearManagedSnapshot()
        sessionTokens.invalidate()
        refresh()
    }

    // MARK: - Product-kind persistence

    private func readProductKind() -> LicenseProductKind? {
        Self.readProductKind(from: productKindSlot)
    }

    private static func readProductKind(from slot: KeychainSlot) -> LicenseProductKind? {
        guard case .found(let raw) = slot.readResult() else { return nil }
        return LicenseProductKind(rawValue: raw)
    }

    private func recordProductKind(_ kind: LicenseProductKind) {
        productKindSlot.write(kind.rawValue)
    }

    private func clearProductKind() {
        productKindSlot.delete()
    }

    // MARK: - Managed snapshot cache (display only)

    private func clearManagedSnapshot() {
        managedSnapshot = nil
        defaults.removeObject(forKey: Self.managedSnapshotKey)
    }

    private func saveCachedSnapshot(_ snapshot: ManagedEntitlementSnapshot) {
        guard let data = try? Self.snapshotEncoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.managedSnapshotKey)
    }

    private static func loadCachedSnapshot(from defaults: UserDefaults) -> ManagedEntitlementSnapshot? {
        guard let data = defaults.data(forKey: managedSnapshotKey) else { return nil }
        return try? snapshotDecoder.decode(ManagedEntitlementSnapshot.self, from: data)
    }

    /// Coders for the local snapshot cache. Dates round-trip as epoch seconds so
    /// the cache is independent of the wire's ISO formatting.
    private static let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let snapshotDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

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
        // Keep the Managed display snapshot in lockstep with a forced state so
        // the credits line / past-due nudge (which read `managedSnapshot`) match
        // the dev selection. A forced `.managed` synthesizes an `active`
        // snapshot from its associated values; any other state clears it.
        if case .managed(let tier, let credits, let reset) = newState {
            managedSnapshot = ManagedEntitlementSnapshot(
                tier: tier,
                status: .active,
                creditsRemaining: credits,
                creditsLimit: max(credits, credits == 0 ? 100 : credits),
                resetDate: reset == .distantFuture ? nil : reset
            )
        } else {
            managedSnapshot = nil
        }
        Log.ui.notice("entitlement dev override → \(String(describing: newState), privacy: .public)")
    }

    /// DEBUG: force a `past_due` Managed snapshot on top of the current
    /// `.managed` state so the "update your card" nudge (§9.1) can be exercised
    /// without a real failed renewal. No-op unless currently `.managed`.
    func devForceManagedPastDue() {
        guard case .managed(let tier, let credits, let reset) = state else { return }
        devOverrideActive = true
        managedSnapshot = ManagedEntitlementSnapshot(
            tier: tier,
            status: .pastDue,
            creditsRemaining: credits,
            creditsLimit: max(credits, 100),
            resetDate: reset == .distantFuture ? nil : reset
        )
        Log.ui.notice("entitlement dev override → managed past_due")
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
        let store = EntitlementStore(
            trialManager: .inMemory(),
            licenseService: .inMemory(),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(nil),
            defaults: .ephemeralPreview()
        )
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

// MARK: - UserDefaults ephemeral helper

extension UserDefaults {
    /// A uniquely-named, throwaway `UserDefaults` for previews and tests, so the
    /// Managed snapshot cache never reads or writes the app's real defaults.
    /// Non-`#if DEBUG` because `#Preview` bodies compile in every config.
    static func ephemeralPreview() -> UserDefaults {
        let name = "com.zerro.ephemeral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
