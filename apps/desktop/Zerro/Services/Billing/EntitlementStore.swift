//
//  EntitlementStore.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  The long-lived, observable holder of the current `EntitlementState` and
//  the single predicate the recording gate reads (`canGenerate`). Owned by
//  `ZerroApp` as @State for the app's lifetime and injected into the
//  menu-bar content, the Settings window, and the Paywall window via the
//  SwiftUI environment, exactly like `AppState` / `PermissionsManager`.
//
//  The state is COMPUTED from real sources in `computeState` / `refresh()`:
//  the Zerro license and the local 14-day trial clock. Precedence:
//  license > active trial > expired trial. Community builds pin the
//  always-entitled `.byok` and never consult either source. The gate's
//  contract never changes — surfaces only read `state` / `canGenerate`.
//
//  Generation is ALWAYS funded by the user's own provider keys through the
//  local pipeline; this store only decides whether the record-start gate
//  opens or routes to the purchase surface.
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
    ///
    /// Tier 1 analytics: every assignment refreshes the `entitlement_state`
    /// super-property so all events segment by monetization state. This is
    /// the single chokepoint — `refresh()`, `activate()`, and the DEBUG
    /// override all flow through here. (The value set in `init` doesn't trip
    /// `didSet`; that one is seeded explicitly after `Analytics.start()` in
    /// `ZerroApp`.)
    private(set) var state: EntitlementState {
        didSet {
            Analytics.updateEntitlementProperties(state)
        }
    }

    // MARK: - Dependencies

    /// Official-vs-community boundary (see `EntitlementEnforcementMode`).
    /// `.community` (every plain source-checkout build) pins the store to an
    /// always-entitled `.byok` state and answers `canGenerate` with an
    /// unconditional true — independent of trial and license state.
    /// `.official` enforces the license/trial ladder. Injected so tests
    /// exercise both modes regardless of the compilation conditions the test
    /// binary was built with; production uses `.productionDefault`.
    let enforcementMode: EntitlementEnforcementMode

    /// The license layer. Owns the license Keychain slots and the three
    /// LemonSqueezy calls; consulted SYNCHRONOUSLY (no network) for startup
    /// precedence and ASYNCHRONOUSLY for throttled re-validation.
    /// Injectable for tests/previews (in-memory slots + stubbed transport).
    private let licenseService: LicenseService

    /// The local trial clock (official builds). Injectable so tests drive a
    /// fake Keychain + controllable clock; production (`ZerroApp`) passes the
    /// real manager. When present, the unlicensed branch of `computeState`
    /// derives `.localTrial`/`.localTrialExpired` from it; when nil (previews
    /// and tests that pin state through the dev override), the unlicensed
    /// branch lands on the gated `.localTrialExpired` — a missing clock never
    /// grants. Community mode never touches it — the store pins `.byok`
    /// before any source is consulted.
    private let trialManager: TrialManager?

    // MARK: - Init

    /// `nil` constructs the default real-Keychain dependencies inside the
    /// (MainActor) body — a `LicenseService()` default-argument expression
    /// would be evaluated nonisolated and trip MainActor isolation. Tests and
    /// previews inject fakes over in-memory slots.
    init(
        enforcementMode: EntitlementEnforcementMode? = nil,
        licenseService: LicenseService? = nil,
        trialManager: TrialManager? = nil
    ) {
        // `nil ?? .productionDefault` resolved HERE (MainActor-isolated body),
        // not as a default-argument expression — a default argument evaluates
        // nonisolated and would trip the Swift 6 isolation diagnostics (the
        // same `T? = nil` idiom the other stores use).
        let enforcementMode = enforcementMode ?? .productionDefault
        let license = licenseService ?? LicenseService()
        self.enforcementMode = enforcementMode
        self.licenseService = license
        self.trialManager = trialManager
        // Community builds are always entitled: pin the local-funded state and
        // never consult the license/trial sources (see
        // `EntitlementEnforcementMode`).
        if enforcementMode == .community {
            self.state = .byok
            return
        }
        // The initial state is COMPUTED, not hard-coded — from the resolved
        // locals (so this runs without touching `self`). Precedence: license >
        // local trial clock.
        self.state = Self.computeState(licenseService: license, trialManager: trialManager)
    }

    // MARK: - State computation

    /// Derives the current `EntitlementState` from its real sources, in
    /// precedence order: license > local trial clock. The DEBUG override (in
    /// `refresh`) sits above all of this.
    ///
    /// `static` (takes the dependencies explicitly) so `init` can call it
    /// before `self` is fully initialized AND `refresh()` can reuse it.
    private static func computeState(
        licenseService: LicenseService,
        trialManager: TrialManager?
    ) -> EntitlementState {
        // A cached license OUTRANKS the trial clock — when it licenses THIS
        // build. This is a SYNCHRONOUS Keychain read only, never a network
        // call, and `grantsBYOK` requires the COMPLETE cached record: key +
        // instance readable, and a persisted product ID + licensed major that
        // match the running `LicenseEditionPolicy`. Anything less — a
        // Keychain read failure, missing or malformed metadata, a
        // wrong-product key, a major-1 license read by a future major's
        // build — FAILS CLOSED: the user falls through to the trial/purchase
        // ladder (the paywall names a confirmed mismatch). Only NETWORK
        // trouble fails open, and only for a user who already holds this
        // complete, compatible record (see `revalidateLicenseIfNeeded`).
        if licenseService.currentLicenseState().grantsBYOK {
            return .byok
        }

        // Unlicensed: the local trial clock is the sole trial source. First
        // launch establishes the start (idempotent thereafter); an active
        // clock grants, an elapsed one gates. The clock honors its own
        // fail-open contract — see `TrialManager`.
        if let trialManager {
            trialManager.startTrialIfNeeded()
            switch trialManager.evaluate() {
            case .active(let daysRemaining):
                return .localTrial(daysRemaining: daysRemaining)
            case .expired:
                return .localTrialExpired
            }
        }

        // No clock injected (previews/tests that pin their state via the dev
        // override). A missing clock never grants — land on the gated state.
        return .localTrialExpired
    }

    // MARK: - Licensing policy

    /// Whether THIS build enforces official licensing at all. `true` only in
    /// official mode; a community build never reads, validates, or contacts
    /// Lemon Squeezy for licensing, and must never present as licensed merely
    /// because enforcement is disabled. Every paid-license consumer branches
    /// on this (or on `hasActiveLicense`) — never on `state == .byok` alone,
    /// because community pins `.byok` as its always-entitled state.
    var enforcesLicensing: Bool {
        enforcementMode == .official
    }

    /// Whether an actual, edition-compatible Zerro license is active on this
    /// device: official mode AND the license branch of `computeState` granted.
    /// This is the ONE predicate for "the user paid" — Settings, the paywall,
    /// and the checkout-return flow all read it.
    var hasActiveLicense: Bool {
        enforcesLicensing && state == .byok
    }

    // MARK: - Gate predicate

    /// The single predicate the recording-start gate consults (see
    /// `ZerroApp.handleHotkey`). True means "let the user reach the area
    /// selector and start a capture"; false means "route to the paywall
    /// instead." Defined here, in one place, so the gate never re-derives
    /// access rules at the call site.
    ///
    ///   • `.localTrial` → true. The 14-day trial runs on the user's own keys.
    ///   • `.byok`       → true. Licensed; the user funds generation directly.
    ///   • `.localTrialExpired` → false. The only refusing state.
    var canGenerate: Bool {
        // Community builds are never blocked by entitlement state.
        if enforcementMode == .community { return true }
        switch state {
        case .localTrial, .byok:
            return true
        case .localTrialExpired:
            return false
        }
    }

    // MARK: - Refresh

    /// Recomputes `state` from its real sources via the precedence ladder in
    /// `computeState`. Called at launch (via `init`) and at every record-start
    /// attempt (see `ZerroApp.handleHotkey`) so a trial that elapsed while the
    /// app sat idle is caught the moment the user tries to record, never
    /// honored stale.
    ///
    /// FAIL-OPEN CONTRACT (network only): on a transient NETWORK failure —
    /// a backend timeout, an offline re-validation — `refresh()` must fail
    /// TOWARD granting access for a user who already holds a complete,
    /// compatible cached license record. It must never downgrade that user
    /// just because an online check couldn't complete. The LOCAL record is
    /// the opposite direction: the license branch of `computeState` grants
    /// only when the complete cached record is readable and verified, so a
    /// Keychain read failure or missing/mismatched metadata fails closed
    /// (an unverifiable record never unlocks an official build). The trial
    /// clock keeps its own fail-open shape — see `TrialManager`.
    func refresh() {
        // Community builds never recompute from license/trial sources — the
        // state stays pinned to the always-entitled `.byok`. Checked ABOVE
        // the DEBUG dev override so community behavior is unconditional and
        // predictable; exercising official-mode states in a source checkout is
        // done by injecting `.official` (tests do exactly that).
        if enforcementMode == .community {
            state = .byok
            return
        }
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
        state = Self.computeState(licenseService: licenseService, trialManager: trialManager)
    }

    // MARK: - Licensing

    /// Activates `licenseKey` online (paywall / Settings / checkout-return
    /// entry point). `LicenseService.activate` owns the whole verdict — it
    /// confirms the product identity against `LicenseEditionPolicy` and
    /// persists the credentials + edition metadata together — so a returned
    /// result IS a compatible license and the entitlement lands on `.byok`
    /// directly. Rethrows the `LicenseError` so the UI can branch
    /// (wrong-product, at-activation-limit, key invalid, network, …); nothing
    /// is persisted on any thrown error.
    @discardableResult
    func activate(licenseKey: String) async throws -> ActivationResult {
        let result = try await licenseService.activate(licenseKey: licenseKey)
        #if DEBUG
        // A successful real activation releases any pinned dev override — the
        // user's actual entitlement should now win.
        devOverrideActive = false
        #endif
        state = .byok
        Log.billing.notice("entitlement → byok via activation (instance=\(result.instanceID, privacy: .public))")
        return result
    }

    /// Deactivates THIS device's license: frees the LemonSqueezy machine slot,
    /// clears the local credentials, and recomputes the entitlement (which now
    /// falls through to the trial clock → `.localTrial`/`.localTrialExpired`).
    /// Used by the Settings "Deactivate this device" button. Rethrows on
    /// failure; on a network failure the local license is LEFT INTACT (we
    /// didn't free the slot, so we mustn't drop the user's access).
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

    // MARK: - Pre-flight (record-start gate)

    /// A DEFINITIVELY-known, pre-flightable block — a failure the record-start
    /// gate can detect from the freshest LOCAL entitlement BEFORE the user
    /// records, instead of after a wasted 3-minute capture. Each case maps 1:1
    /// to the post-recording `RecordingFailureReason` so the surfaced copy is
    /// identical; the post-recording path stays the backstop for anything that
    /// only becomes true between the gate and the API call.
    enum PreflightBlock: Equatable {
        /// Generation is funded with the user's own key, but no self-funding
        /// setup is on file (no chat key, or no usable transcription path).
        case apiKeyMissing
    }

    /// The pre-flight decision for the record-start gate, or `nil` to proceed.
    ///
    /// SYNCHRONOUS + LOCAL: consults only the current state + the
    /// caller-supplied key presence — never the network — so it adds no
    /// latency. It returns a block ONLY for a definitively-known-bad setup
    /// (key confirmed absent); anything inconclusive returns `nil` → the user
    /// records, exactly as the existing `canGenerate` gate fails open.
    ///
    /// `canGenerateLocally` is whether the user can fund a generation
    /// themselves — a chat key AND a usable transcription path (see
    /// `AppState.canGenerateLocally`). A user with no self-funding setup is
    /// routed to fix it before recording.
    func preflightBlock(canGenerateLocally: Bool) -> PreflightBlock? {
        switch state {
        case .localTrial, .byok:
            // Generation funds locally in every granting state. If the user
            // has no self-funding setup — no chat key, or no usable
            // transcription path — the recording would fail post-capture
            // (`.apiKeyMissing`); catch it now and route them to add what's
            // missing.
            return canGenerateLocally ? nil : .apiKeyMissing
        case .localTrialExpired:
            // `.localTrialExpired` is the `canGenerate` gate's job (paywall).
            return nil
        }
    }

    // MARK: - Paywall trigger (Tier 3 analytics)

    /// Why the paywall was last routed open — read once by `PaywallView.onAppear`
    /// for `paywall_shown.trigger`, then cleared. Set to a block reason by
    /// `AppState.presentPreflightBlock`; the record-start gate resets it to `nil`
    /// on the plain expired-trial open (→ `manual` in the event). It ALSO drives
    /// the paywall's dynamic headline (see `PaywallCopy`). UI/analytics only;
    /// never gates anything.
    enum PaywallTrigger: String {
        case apiKeyMissing = "api_key_missing"
        /// Trial elapsed — the gated open (the original paywall).
        case blocked = "blocked"
        /// A still-in-trial user voluntarily opening the purchase surface.
        case voluntaryUpgrade = "voluntary_upgrade"
        /// A licensed user managing devices/billing — not a sell.
        case manage = "manage"
    }
    var paywallTrigger: PaywallTrigger?

    /// One-shot flag set by the checkout-return deep link when a brand-new buyer
    /// must paste their license key: `ActivateLicenseCard` reads it on appear to
    /// open straight into the (focused) activation field. Read-once then cleared,
    /// like `paywallTrigger`. UI only.
    var focusActivationFieldOnOpen = false

    /// One-shot prefill for the activation field, set by the checkout-return deep
    /// link when a key arrives that the user must explicitly confirm: the window
    /// opens focused on the field with the key already populated. Read + cleared
    /// on appear (travels with `focusActivationFieldOnOpen`). UI only.
    var prefillLicenseKey: String?

    /// One-shot purchase confirmation to render after a successful activation
    /// (deep-link OR manual paste). When non-nil, `PaywallView` shows the
    /// "you're all set" success screen INSTEAD of the buy/manage matrix;
    /// cleared when the user taps the confirmation's button. `@Observable`
    /// drives the swap. UI only.
    var purchaseSuccess: PurchaseSuccessInfo?

    /// True when the user already holds the PURCHASED entitlement — nothing
    /// left to buy/activate. The checkout-return deep link reads this to
    /// choose silent-refresh (an idempotent re-click) vs
    /// open-the-paywall-to-paste (a brand-new buyer). Community builds are
    /// never "paid": they are unrestricted, not licensed.
    var isPaidEntitled: Bool {
        hasActiveLicense
    }

    /// True when a license key is on file (a prior activation). `.present`-only
    /// so a Keychain blip (which the license layer surfaces as
    /// `.indeterminate`) doesn't trigger needless network work. Matches the
    /// presence check in `revalidateLicenseIfNeeded`. Community builds never
    /// read the license slots — always `false` there.
    var hasLicenseOnFile: Bool {
        guard enforcesLicensing else { return false }
        return licenseService.currentLicenseState().presence == .present
    }

    /// True when a license key IS on file but its confirmed edition does not
    /// license this build — a wrong-product key, or a license for a different
    /// Zerro major. The paywall reads this to swap its purchase pitch for the
    /// specific "your license covers a different version" presentation.
    /// Metadata that is merely MISSING (never confirmed online) is not a
    /// mismatch — that's an unconfirmed cache, not a known-wrong license.
    var hasIncompatibleLicense: Bool {
        guard enforcesLicensing else { return false }
        let snapshot = licenseService.currentLicenseState()
        guard snapshot.presence == .present else { return false }
        if case .incompatible = snapshot.edition { return true }
        return false
    }

    /// The Zerro major the on-file INCOMPATIBLE license covers, when the
    /// cached record names one (e.g. 1 for a Zerro 1.x license read by a
    /// future major's build). `nil` when there's no mismatch or the cached
    /// major is unreadable. Drives the specific upgrade copy.
    var incompatibleLicensedMajor: Int? {
        guard enforcesLicensing else { return nil }
        let snapshot = licenseService.currentLicenseState()
        guard snapshot.presence == .present,
              case .incompatible(let major) = snapshot.edition else { return nil }
        return major
    }

    /// True when `key` is the license ALREADY on file AND the user is currently
    /// paid-entitled — the idempotent "already active" signal the checkout-return
    /// deep link uses to treat a repeat click (or a key that already activated
    /// this device) as success, instead of re-POSTing to LemonSqueezy. Compared
    /// trimmed, since the on-file key was stored trimmed.
    func isActiveLicenseKey(_ key: String) -> Bool {
        guard hasActiveLicense else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return licenseService.currentLicenseKey() == trimmed
    }

    // MARK: - Throttled re-validation

    /// Background, THROTTLED re-validation. Called at launch (see `ZerroApp`).
    /// Does nothing unless a license is actually present and the throttle
    /// window (`LicenseService.revalidationInterval`) has elapsed — so the app
    /// is offline-first and re-hits LemonSqueezy at most ~weekly. The verdict:
    ///   • DEFINITIVE revocation (`valid:false` disabled/expired) → clear the
    ///     license and drop to the trial computation (refund handling).
    ///   • DEFINITIVE product mismatch → drop the entitlement (metadata was
    ///     already cleared by `validate()`).
    ///   • valid / non-definitive / network failure → stay `.byok` (FAIL OPEN).
    func revalidateLicenseIfNeeded() async {
        // Community builds never validate or contact Lemon Squeezy.
        guard enforcesLicensing else { return }
        guard licenseService.currentLicenseState().presence == .present else {
            // Absent → nothing to validate. Indeterminate → a transient
            // Keychain read failure; skip and retry next launch (the local
            // record already fails closed in `computeState`, and a network
            // call can't repair an unreadable Keychain).
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
                Log.billing.notice("license revoked (status=\(result.status?.rawValue ?? "unknown", privacy: .public)) — clearing, dropping to the trial computation")
                licenseService.clearLicense()
                refresh()
            } else if result.isDefinitiveProductMismatch {
                // Definitive product mismatch — the response's product ID was
                // wrong or missing, whatever `valid` said. `validate()`
                // already deleted the edition metadata (keeping the key +
                // instance visible in Settings). Recompute so the mismatched
                // license stops granting NOW, not at the next launch.
                Log.billing.notice("license product mismatch on revalidation — dropping entitlement to the trial/purchase ladder")
                refresh()
            }
            // valid+approved / non-definitive negative (approved product) →
            // stay `.byok`. `validate()` already refreshed the throttle
            // stamp on a fully good result.
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

    /// Preview convenience: a store pinned to `state` via the dev override,
    /// backed by in-memory dependencies so previews never touch the real
    /// Keychain. (DEBUG-only; reference only from `#if DEBUG`-guarded
    /// previews so Release builds — which still compile `#Preview` bodies —
    /// don't see this symbol.)
    /// Explicitly `.official`: the factory's contract is "behave exactly like
    /// `state`", which is official-mode semantics — community mode would
    /// override the pinned state's gate (source builds default to community,
    /// so previews and tests would otherwise stop simulating).
    static func preview(_ state: EntitlementState) -> EntitlementStore {
        let store = EntitlementStore(
            enforcementMode: .official,
            licenseService: .inMemory()
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

    /// The states the dev panel can force, paired with short labels — the
    /// three states an official build can actually be in.
    /// Consumed by the menu-bar `EntitlementDebugPicker` (the single
    /// force-entitlement surface; the paywall's copy was removed).
    static var devStates: [(label: String, state: EntitlementState)] {
        [
            ("Free Trial", .localTrial(daysRemaining: TrialManager.trialLengthDays)),
            ("Trial Complete", .localTrialExpired),
            ("Licensed", .byok),
        ]
    }

    /// Whether `candidate` is the currently-active state, for selected-pill
    /// rendering in the dev panel. Compares by case identity so two
    /// `.localTrial`s with different day counts read as the "same" dev
    /// selection regardless of the throwaway numbers.
    func devMatches(_ candidate: EntitlementState) -> Bool {
        switch (state, candidate) {
        case (.localTrial, .localTrial), (.localTrialExpired, .localTrialExpired), (.byok, .byok):
            return true
        default:
            return false
        }
    }
    #endif
}

// MARK: - UserDefaults ephemeral helper

extension UserDefaults {
    /// A uniquely-named, throwaway `UserDefaults` for previews and tests, so
    /// nothing under test ever reads or writes the app's real defaults.
    /// Non-`#if DEBUG` because `#Preview` bodies compile in every config.
    static func ephemeralPreview() -> UserDefaults {
        let name = "com.zerro.ephemeral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
