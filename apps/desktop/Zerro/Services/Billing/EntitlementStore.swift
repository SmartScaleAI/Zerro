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
//  The state is COMPUTED from real sources in `computeState` /  `refresh()`:
//  the BYOK license, the backend Managed entitlement, and the server-funded
//  trial credit balance. Precedence: Managed > BYOK > trial(credits) > expired.
//  The gate's contract never changes — surfaces only read `state` /
//  `canGenerate`.
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
    ///
    /// Tier 1 analytics: every assignment refreshes the `entitlement_state` /
    /// `credits_remaining_bucket` super-properties so all events segment by
    /// monetization state. This is the single chokepoint — `refresh()`,
    /// `activate()`, the apply-credits paths, and the DEBUG override all flow
    /// through here. (The value set in `init` doesn't trip `didSet`; that one
    /// is seeded explicitly after `Analytics.start()` in `ZerroApp`.)
    private(set) var state: EntitlementState {
        didSet {
            Analytics.updateEntitlementProperties(state)
            Self.captureTrialTransition(from: oldValue, to: state)
        }
    }

    /// Tier 3 analytics: the two purely-LOCAL trial transitions. Subscription
    /// activation/lapse are captured SERVER-SIDE from the LemonSqueezy webhook
    /// (reliable even with the app closed), so they are deliberately NOT emitted
    /// here — the webhook is the single source and firing here too would
    /// double-count.
    private static func captureTrialTransition(from old: EntitlementState, to new: EntitlementState) {
        // First grant: pre-trial (no balance) → a real credit balance.
        if case .trial(let oldBalance) = old, oldBalance == nil,
           case .trial(let newBalance) = new, let granted = newBalance {
            Analytics.capture("trial_started", ["credits_granted": granted])
        }
        // Trial spent out: any trial balance → expired.
        if case .trial = old, case .expired = new {
            Analytics.capture("trial_exhausted")
        }
    }

    // MARK: - Dependencies

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

    /// The Phase F trial-credits layer. Supplies `trialCreditsRemaining` for the
    /// `.trial` display and the in-memory trial-token presence that decides
    /// whether a trial generation can route through the proxy. Optional so tests/
    /// previews that don't exercise trial credits omit it. See [[TrialCreditsManager]].
    private let trialCredits: TrialCreditsManager?

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

    /// The trial grant TOTAL (E4) — the usage meter's bar denominator,
    /// forwarded from `TrialCreditsManager`'s cache of the last verify/resume
    /// response. `nil` before verification, in trial-less constructions, or
    /// against an older server (the meter then stays bar-less). DISPLAY ONLY.
    var trialCreditsLimit: Int? {
        trialCredits?.creditsLimit
    }

    // MARK: - Init

    /// `nil` constructs the default real-Keychain dependencies inside the
    /// (MainActor) body — a `LicenseService()` default-argument expression
    /// would be evaluated nonisolated and trip MainActor isolation. Tests and
    /// previews inject fakes over in-memory slots.
    init(
        licenseService: LicenseService? = nil,
        sessionTokens: SessionTokenManager? = nil,
        productKindSlot: KeychainSlot? = nil,
        trialCredits: TrialCreditsManager? = nil,
        defaults: UserDefaults = .standard
    ) {
        let license = licenseService ?? LicenseService()
        let tokens = sessionTokens ?? SessionTokenManager()
        let kindSlot = productKindSlot ?? KeychainStore.licenseProductKind
        self.licenseService = license
        self.sessionTokens = tokens
        self.productKindSlot = kindSlot
        self.trialCredits = trialCredits
        self.defaults = defaults
        // Seed the Managed display snapshot from the local cache so a Managed
        // user's credits line is correct at launch (refreshed async shortly
        // after). Decoded from the resolved local (no `self` access yet).
        let cached = Self.loadCachedSnapshot(from: defaults)
        self.managedSnapshot = cached
        // Phase C/E/F: the initial state is COMPUTED, not hard-coded — from the
        // resolved locals (so this runs without touching `self`). Precedence:
        // Managed (Phase E) > BYOK (Phase C) > trial credits (Phase F) > expired.
        self.state = Self.computeState(
            licenseService: license,
            productKind: Self.readProductKind(from: kindSlot),
            cachedSnapshot: cached,
            trialCreditsRemaining: trialCredits?.creditsRemaining
        )
    }

    // MARK: - State computation

    /// Derives the current `EntitlementState` from its real sources, in
    /// precedence order: Managed subscription > BYOK license > trial credits >
    /// expired. The DEBUG override (in `refresh`) sits above all of this.
    ///
    /// `static` (takes the dependencies explicitly) so `init` can call it
    /// before `self` is fully initialized AND `refresh()` can reuse it.
    private static func computeState(
        licenseService: LicenseService,
        productKind: LicenseProductKind?,
        cachedSnapshot: ManagedEntitlementSnapshot?,
        trialCreditsRemaining: Int?
    ) -> EntitlementState {
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

        // Phase F: the trial is now PURELY a pool of server-funded credits, with
        // no time limit. It is `.trial` while credits remain (or before the user
        // has been granted any — a nil balance is a never-verified "pre-trial"
        // user whom onboarding's email step still gates), and `.expired` the
        // instant a CONFIRMED balance hits zero. This is the only trial-expiry
        // condition.
        //
        // FAIL-OPEN: only a definitive zero (server truth, cached from the last
        // /generate response) expires the trial. A nil balance — never granted,
        // or a transient inability to read the cache — keeps the user in `.trial`,
        // never dropping an entitled user to `.expired` over a missing read.
        if let credits = trialCreditsRemaining, credits <= 0 {
            return .expired
        }
        return .trial(creditsRemaining: trialCreditsRemaining)
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
    ///   • `.trial`   → true. A trial only reaches `.trial` while it still has
    ///                  server-funded credits (a confirmed-zero balance is
    ///                  `.expired`); the server is the spend authority.
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

    /// Recomputes `state` from its real sources via the precedence ladder in
    /// `computeState`. Called at launch (via `init`) and at every record-start
    /// attempt (see `ZerroApp.handleHotkey`) so a trial whose credits ran out
    /// while the app sat idle is caught the moment the user tries to record,
    /// never honored stale.
    ///
    /// FAIL-OPEN CONTRACT (binding on every real implementation): on a
    /// TRANSIENT failure — a Keychain read error, a backend timeout, an
    /// offline check — `refresh()` must fail TOWARD granting access for a
    /// user who is already entitled. It must NEVER downgrade a known-good
    /// `.byok` / `.managed` / `.trial` to `.expired` just because a check
    /// couldn't complete. Locking a paying user out of their own tool over
    /// a flaky network is a far worse failure than briefly honoring an
    /// entitlement that has actually lapsed. The trial honors this through
    /// `computeState`: only a CONFIRMED zero credit balance (server truth)
    /// expires it; a never-granted or unreadable balance stays `.trial`.
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
            licenseService: licenseService,
            productKind: readProductKind(),
            cachedSnapshot: managedSnapshot,
            trialCreditsRemaining: trialCredits?.creditsRemaining
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

    /// True when generation must route through the proxy (`ManagedProxyClient`)
    /// rather than the direct BYOK OpenAI path. `.managed` always does; a
    /// `.trial` user does ONCE they've verified an email and hold a trial token
    /// (Phase F) — before that there's nothing to authorize, so a trial without a
    /// token routes to the email-capture flow instead (see `generationRoute`).
    /// `.byok` stays fully local.
    var routesThroughManagedProxy: Bool {
        switch state {
        case .managed:
            return true
        case .trial:
            return trialCredits?.hasActiveTrialToken == true
        case .byok, .expired:
            return false
        }
    }

    /// How the generation pipeline should run for the current entitlement. The
    /// single decision AppState reads at generation time. Splitting it out keeps
    /// the policy (which path) here and the mechanism (run it) in AppState.
    ///
    /// `hasOwnAPIKey` is whether the user has their own OpenAI key on file: a
    /// trial user WITH a key funds generation locally (their dime, the existing
    /// path); only a trial user WITHOUT a key needs server-funded credits.
    enum GenerationRoute: Equatable {
        /// Direct OpenAI with the user's own key (BYOK, or trial-on-own-key).
        case local
        /// Managed subscription → proxy with the subscription session token.
        case managedProxy
        /// Trial with credits + a live trial token → proxy with the trial token.
        case trialProxy
        /// Trial, no own key, no trial token yet → present the email-capture sheet.
        case trialNeedsEmail
    }

    func generationRoute(hasOwnAPIKey: Bool) -> GenerationRoute {
        switch state {
        case .managed:
            return .managedProxy
        case .byok:
            return .local
        case .expired:
            // The record-start gate already blocks `.expired`; defensive default.
            return .local
        case .trial:
            if hasOwnAPIKey { return .local }
            if trialCredits?.hasActiveTrialToken == true { return .trialProxy }
            // H1 decouple: a token that merely expired is NOT a re-verify. If the
            // email was EVER verified (a remembered email on file), the proxy path
            // silently resumes a token (validToken → refreshToken) and proceeds.
            // Only a genuine first-time user (no verified email) is sent to the
            // email-capture flow.
            if trialCredits?.rememberedEmail != nil { return .trialProxy }
            return .trialNeedsEmail
        }
    }

    // MARK: - Pre-flight (record-start gate)

    /// A DEFINITIVELY-known, pre-flightable block — a failure the record-start
    /// gate can detect from the freshest LOCAL entitlement BEFORE the user
    /// records, instead of after a wasted 3-minute capture. Each case maps 1:1
    /// to the post-recording `RecordingFailureReason` so the surfaced copy is
    /// identical; the post-recording path stays the backstop for anything that
    /// only becomes true between the gate and the API call.
    enum PreflightBlock: Equatable {
        /// Managed: this period's credits are spent (snapshot shows 0 remaining).
        case outOfCredits
        /// Managed: the subscription is no longer active (snapshot status not live).
        case subscriptionInactive
        /// BYOK: funds generation with the user's own key, but none is on file.
        case apiKeyMissing
    }

    /// The pre-flight decision for the record-start gate, or `nil` to proceed.
    ///
    /// SYNCHRONOUS + LOCAL: consults only the current state + the freshest cached
    /// Managed snapshot + the caller-supplied key presence — never the network —
    /// so it adds no latency and can't violate fail-open. It returns a block ONLY
    /// for a definitively-known-bad state (credits confirmed zero, subscription
    /// snapshot confirmed not-live, key confirmed absent). Anything inconclusive
    /// (no snapshot yet, an in-flight refresh, a Keychain blip surfacing as
    /// "has a key") returns `nil` → the user records, exactly as the existing
    /// `canGenerate` gate fails open. The server proxy remains the spend
    /// authority regardless.
    ///
    /// `hasOwnAPIKey` is whether the user has their own OpenAI key on file (the
    /// gate reads the Keychain); only `.byok` consults it.
    func preflightBlock(hasOwnAPIKey: Bool) -> PreflightBlock? {
        switch state {
        case .managed:
            // The credit/status decision is the SERVER's; the gate only surfaces
            // what the freshest snapshot already tells us. No snapshot yet → the
            // launch/post-generation refresh hasn't landed → proceed (fail open).
            guard let snapshot = managedSnapshot else { return nil }
            if !snapshot.status.isLive { return .subscriptionInactive }
            if snapshot.creditsRemaining <= 0 { return .outOfCredits }
            return nil
        case .byok:
            // BYOK funds generation locally. A confirmed-absent key would fail
            // post-recording with `.apiKeyMissing`; catch it now and route them
            // to add it. A Keychain read blip reports `hasOwnAPIKey == true`
            // (the key slot fails toward "present"), so a flaky read never blocks.
            return hasOwnAPIKey ? nil : .apiKeyMissing
        case .trial, .expired:
            // Trial-exhausted is already mapped to `.expired` by the dual-expiry
            // in `computeState` (so the `canGenerate` gate → paywall catches it);
            // a live trial needs no pre-flight block here, and `.expired` is the
            // `canGenerate` gate's job.
            return nil
        }
    }

    /// True when the user is on the trial but has NEVER verified an email — so the
    /// persistent "verify your email to start your free trial" affordance
    /// (Settings/Billing row + menu-bar banner) should show. Keyed on whether an
    /// email was EVER verified (a remembered email), NOT on the live token (H1):
    /// a token that merely expired resumes silently in the background
    /// (`TrialCreditsManager.refreshToken`), so it must NOT surface the verify
    /// affordance. This correctly fires for the only case that still needs a
    /// genuine first-time verification:
    ///   • never verified (existing users from before the required email step, or
    ///     anyone who took the onboarding infra-failure fallback).
    /// An expired-but-previously-verified token is handled by the silent resume,
    /// not here.
    var needsTrialEmailVerification: Bool {
        guard case .trial = state, let trialCredits else { return false }
        return trialCredits.rememberedEmail == nil
    }

    // MARK: - Paywall trigger (Tier 3 analytics)

    /// Why the paywall was last routed open — read once by `PaywallView.onAppear`
    /// for `paywall_shown.trigger`, then cleared. Set to a block reason by
    /// `AppState.presentPreflightBlock`; the record-start gate resets it to `nil`
    /// on the plain `.expired` open (→ `manual` in the event). It ALSO drives the
    /// paywall's dynamic headline (see `PaywallCopy`). UI/analytics only; never
    /// gates anything.
    ///
    /// The first three cases are pre-flight block reasons; the last four are the
    /// menu-bar "Upgrade" entry-point contexts (one always-present row whose
    /// label + trigger vary by state — see `MenuBarBillingAction`).
    enum PaywallTrigger: String {
        case outOfCredits = "out_of_credits"
        case subscriptionInactive = "subscription_inactive"
        case apiKeyMissing = "api_key_missing"
        /// Trial exhausted — the gated `.expired` open (the original paywall).
        case blocked = "blocked"
        /// A still-in-trial user voluntarily opening the upgrade surface.
        case voluntaryUpgrade = "voluntary_upgrade"
        /// A Managed user adding credits (low balance / out of credits).
        case topup = "topup"
        /// An entitled user (Managed/BYOK) managing — not a sell.
        case manage = "manage"
    }
    var paywallTrigger: PaywallTrigger?

    /// One-shot flag set by the checkout-return deep link when a brand-new buyer
    /// must paste their license key: `ActivateLicenseCard` reads it on appear to
    /// open straight into the (focused) activation field. Read-once then cleared,
    /// like `paywallTrigger`. UI only.
    var focusActivationFieldOnOpen = false

    /// True when the user already holds a PURCHASED entitlement (Managed or
    /// BYOK) — nothing left to buy/activate. The checkout-return deep link reads
    /// this to choose silent-refresh (an already-activated Managed user's top-up)
    /// vs open-the-paywall-to-paste (a brand-new buyer). Mirrors the paid arm of
    /// `canGenerate` without the trial/expired rows.
    var isPaidEntitled: Bool {
        switch state {
        case .managed, .byok: return true
        case .trial, .expired: return false
        }
    }

    /// True when a license key is on file (a prior activation). Used by the
    /// app-activation refresh (Step 5) to decide whether to re-hit
    /// `/entitlement` — fail-open `.present`-only so a Keychain blip (which the
    /// license layer surfaces as `.indeterminate`) doesn't trigger needless
    /// network work. Matches the presence check in `revalidateLicenseIfNeeded`.
    var hasLicenseOnFile: Bool {
        licenseService.currentLicenseState().presence == .present
    }

    /// Reflect a just-completed trial generation's `credits_remaining` and
    /// recompute (so the menu-bar line updates and, when credits hit zero, the
    /// state flips to `.expired` for the NEXT record attempt — the current
    /// result the user is viewing is unaffected; only `EntitlementStore.state`
    /// changes, not the recording UI). No-op without a trial layer.
    func applyTrialCreditsRemaining(_ remaining: Int) {
        guard let trialCredits else { return }
        trialCredits.applyCreditsRemaining(remaining)
        refresh()
    }

    /// Drop the trial token + cached credits (definitive trial revocation / a
    /// rejected trial token) and recompute. The next generation re-triggers the
    /// email capture. No-op without a trial layer.
    func resetTrialToken() {
        trialCredits?.clear()
        refresh()
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
        // NB: do NOT clear a DEBUG dev override here. A dev-forced `.managed`
        // drives the very generation/refresh that produces this snapshot, so
        // clearing the pin would un-force managed after the FIRST generation —
        // the next record-start `refresh()` would then recompute to the real
        // (often trial/expired) entitlement and bounce the user to the paywall.
        // The genuine "real entitlement supersedes the override" case is a real
        // activation, which clears the pin explicitly in `activate()`.
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
            let limit = max(credits, credits == 0 ? 100 : credits)
            managedSnapshot = ManagedEntitlementSnapshot(
                tier: tier,
                status: .active,
                creditsRemaining: credits,
                creditsLimit: limit,
                resetDate: reset == .distantFuture ? nil : reset,
                // Synthesize a plan breakdown (no top-ups) so the 6F usage
                // meter renders its bar under a dev-forced state too.
                planCreditsUsed: max(0, limit - credits),
                planCreditsLimit: limit,
                topupCreditsRemaining: 0
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

    // MARK: - Trial dev controls (DEBUG only)
    //
    // The trial is now a pure credit pool (no clock), so forcing trial states
    // is done directly via `devSetState` (the Entitlement picker — `.trial` /
    // `.expired`). What remains here is the email-verification reset, which
    // clears the local Phase F cache so the onboarding email step re-runs.

    /// Clears ALL locally-cached trial email-verification state (in-memory token,
    /// cached credits, remembered email) so the onboarding email step returns to
    /// its unverified first-run state — used by "Reset Onboarding" and the
    /// dedicated "Reset Trial Email / Verification" dev control. The server grant
    /// is the source of truth; re-verifying the same email resumes it (no refarm).
    func devResetTrialVerification() {
        devOverrideActive = false
        trialCredits?.forgetVerification()
        refresh()
    }

    /// Preview convenience: a store pinned to `state` via the dev override,
    /// backed by in-memory dependencies so previews never touch the real
    /// Keychain. (DEBUG-only; reference only from `#if DEBUG`-guarded
    /// previews so Release builds — which still compile `#Preview` bodies —
    /// don't see this symbol.)
    static func preview(_ state: EntitlementState) -> EntitlementStore {
        let store = EntitlementStore(
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

    /// The states the dev panel can force, paired with short labels — only
    /// the plans we actually SELL (one Managed plan + BYOK), so the debug
    /// menu never suggests a tier structure that isn't on the paywall.
    /// `ManagedTier.starter` deliberately does NOT appear here: the case is
    /// retained in the model as future-proofing for a possible cheaper tier
    /// (finding F1), but it's unsold and forcing it would only mislead.
    /// Consumed by the menu-bar `EntitlementDebugPicker` (the single
    /// force-entitlement surface; the paywall's copy was removed).
    /// The managed `resetDate` is a plausible ~30-days-out display value;
    /// nothing gates on it (display-only per `EntitlementState`).
    static var devStates: [(label: String, state: EntitlementState)] {
        let resetDate = Date().addingTimeInterval(60 * 60 * 24 * 30)
        return [
            ("Trial", .trial(creditsRemaining: 15)),
            ("Expired", .expired),
            ("BYOK", .byok),
            ("Managed", .managed(tier: .pro, creditsRemaining: 300, resetDate: resetDate)),
        ]
    }

    /// Whether `candidate` is the currently-active state, for selected-pill
    /// rendering in the dev panel. Compares by case identity so two
    /// `.managed` tiers (or two `.trial`s with different credit counts) read
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
