//
//  LicenseService.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  The Zerro license layer. Wraps the three Lemon Squeezy License API
//  endpoints (activate / validate / deactivate) and owns the Keychain
//  credentials that back a `.byok` entitlement: the raw license key, the
//  activation instance ID, the last-validated throttle stamp, and the
//  confirmed product ID + licensed major.
//
//  This is the ONLY licensing network surface in the app, and it talks to
//  exactly one host: Lemon Squeezy's License API over HTTPS.
//
//  Lifecycle the rest of the app drives through this type
//  ------------------------------------------------------
//  • First activation — user enters a key (paywall or Settings). `activate`
//    POSTs to /activate; on `activated: true` it writes the key + instance
//    ID to the Keychain and stamps `byokLastValidated`. `EntitlementStore`
//    then transitions to `.byok`.
//  • Offline thereafter — `currentLicenseState()` reports a present license
//    from the Keychain WITHOUT a network call, so the app trusts the cached
//    license at every launch and works fully offline.
//  • Throttled re-validation — `EntitlementStore` calls `validate()` at most
//    once per `revalidationInterval` (see `shouldRevalidate()`), in the
//    background, to catch refunds/revocations. A definitive negative
//    (`valid:false` with `disabled`/`expired`) de-activates; a network
//    failure FAILS OPEN (keeps the license). See `EntitlementStore`.
//
//  Secret handling (binding)
//  -------------------------
//  The raw license key is a SECRET: never logged, not even `.private`.
//  Instance IDs, validity booleans, and key STATUS strings carry no user
//  content and are logged `.public`. See `Log.billing`.
//
//  Testability
//  -----------
//  Network goes through the injectable `LicenseTransport` protocol so unit
//  tests stub the three endpoints with canned JSON + status codes, never
//  touching the real network. The Keychain goes through the same
//  `KeychainSlot` seam, so tests use `InMemoryKeychainSlot` fakes. The clock is
//  injectable for deterministic throttle tests. `nil` dependency defaults
//  resolve to the real Keychain/transport INSIDE the (MainActor) init body — a
//  default-argument expression touching `KeychainStore` statics would evaluate
//  nonisolated and trip the project's MainActor-default isolation.
//

import AppKit
import Foundation
import os

// MARK: - LicenseError

/// The shape of every way a license operation can fail, documented
/// case-by-case in the same spirit as `RecordingFailureReason`. The UI
/// branches on these to show clear, NON-PUNITIVE copy (`userFacingMessage`)
/// and to decide whether to route to the paywall, offer a deactivate-another-
/// device flow, or simply ask the user to retry.
enum LicenseError: Error, Equatable {
    /// `/activate` refused because the key is already on the maximum number
    /// of machines. The UI offers to free a slot (deactivate another device)
    /// or points at the customer portal — the key itself is still good.
    case atActivationLimit

    /// The key isn't recognized (not found / typo). Route to the paywall and
    /// surface "double-check your key" copy.
    case keyInvalid

    /// The key has been disabled (e.g. refunded / charged-back / revoked).
    /// This is a DEFINITIVE negative — it de-activates a previously-licensed
    /// user. Route to the paywall.
    case keyDisabled

    /// The key has expired (LemonSqueezy reports `status: expired`). Also a
    /// DEFINITIVE negative. Route to the paywall.
    case keyExpired

    /// Couldn't reach LemonSqueezy (offline, DNS, timeout). For an ALREADY-
    /// activated user this is INCONCLUSIVE and the caller FAILS OPEN (keeps
    /// the cached license); for a first-time activation attempt the UI says
    /// "couldn't reach the licensing server, try again." The associated
    /// string is the transport's error description (network-class text, never
    /// the license key) and is only ever logged `.private`.
    case network(String)

    /// Defensive: the License API returned something we couldn't decode into
    /// the expected shape. Treated as inconclusive (never de-activates).
    case malformedResponse

    /// The key activated, but Lemon Squeezy reports it belongs to a product
    /// this build does not accept (`meta.product_id` missing or not in the
    /// running `LicenseEditionPolicy`). A DEFINITIVE fail-closed: nothing is
    /// persisted and access is never granted. The freshly created instance is
    /// best-effort deactivated so the mismatched attempt doesn't consume a
    /// device slot.
    case wrongProduct

    /// The activation would have REPLACED a different license already on this
    /// device, and the user declined the "Replace your current license?"
    /// confirmation (E-01). Thrown BEFORE any network call or Keychain write, so
    /// the existing license is left fully intact. The UI treats this as a quiet
    /// no-op (return to idle), NOT a failed activation — so it never surfaces an
    /// error pill and never emits `purchase_failed` funnel analytics.
    case replaceCancelled

    /// User-facing, non-punitive copy for each failure. Mirrors
    /// `RecordingFailureReason.userMessage`'s flat single-line style.
    var userFacingMessage: String {
        switch self {
        case .atActivationLimit:
            return "This license is already active on the maximum number of devices. Deactivate one in the Lemon Squeezy portal, then try again."
        case .keyInvalid:
            return "We couldn\u{2019}t find that license key. Double-check it and try again."
        case .keyDisabled:
            return "This license has been deactivated. If you think that\u{2019}s a mistake, reach out to support."
        case .keyExpired:
            return "This license has expired."
        case .network:
            return "Couldn\u{2019}t reach the licensing server. Check your connection and try again."
        case .malformedResponse:
            return "Something went wrong activating your license. Please try again."
        case .wrongProduct:
            return "This license key is for a different Zerro product or version."
        case .replaceCancelled:
            return "Kept your current license. Activation cancelled."
        }
    }
}

// MARK: - LicenseKeyStatus

/// The license key's status as LemonSqueezy reports it. `expired`/`disabled`
/// are the DEFINITIVE negatives that de-activate a user; `active` is the
/// happy path; `inactive` means the key exists but isn't currently activated
/// (e.g. every machine slot freed) and is treated as non-definitive (we don't
/// lock a user out on it — fail-open).
enum LicenseKeyStatus: String, Equatable {
    case active
    case inactive
    case expired
    case disabled
}

// MARK: - Results

/// Outcome of a successful activation. `instanceID` is the value the app
/// persists and must present to validate/deactivate. The rest is useful
/// metadata for display / support (none of it gates anything).
struct ActivationResult: Equatable {
    let instanceID: String
    let status: LicenseKeyStatus
    let storeID: Int?
    let productID: Int?
    let customerEmail: String?
}

/// Outcome of a validation round-trip that COMPLETED (the network was
/// reachable). `valid` is LemonSqueezy's verdict; `status` is the key's
/// status when present. A transport failure throws `LicenseError.network`
/// instead of returning this.
struct ValidationResult: Equatable {
    let valid: Bool
    let status: LicenseKeyStatus?
    /// Whether the response's `meta.product_id` is approved by the running
    /// `LicenseEditionPolicy`. Checked on EVERY decoded validation response,
    /// regardless of `valid`: a wrong or missing product ID is a definitive
    /// incompatibility (fail closed), never a normal validation.
    let productApproved: Bool

    /// True when the completed round-trip definitively established that the
    /// key does not belong to this build's product — the caller must drop the
    /// `.byok` entitlement (the cached edition metadata is already cleared by
    /// `validate()`; the key + instance stay unless `isDefinitiveRevocation`
    /// also clears the whole license).
    var isDefinitiveProductMismatch: Bool { !productApproved }

    /// Whether this result is a DEFINITIVE revocation that should clear the
    /// cached license and drop the user to the trial/expired computation.
    /// True ONLY for `valid:false` with a `disabled`/`expired` status — the
    /// refund/chargeback/expiry signals. Every other `valid:false` shape
    /// (`inactive`, unknown, or no status) is treated as non-definitive and
    /// FAILS OPEN, honoring "only a definitive LemonSqueezy negative
    /// de-activates a user."
    var isDefinitiveRevocation: Bool {
        guard !valid else { return false }
        switch status {
        case .disabled, .expired:
            return true
        case .active, .inactive, .none:
            return false
        }
    }
}

/// Synchronous, network-free snapshot of the stored license, for startup
/// decisions (`EntitlementStore.computeState`). Reading the Keychain is the
/// only work it does.
struct LicenseSnapshot: Equatable {
    /// `.present` — both the key and the instance ID are readable (a real,
    /// usable cached license). `.absent` — at least one is definitively
    /// missing and NEITHER read failed (no license on file). `.indeterminate`
    /// — a genuine Keychain READ FAILURE left presence unknown.
    ///
    /// Only `.present` can grant: the offline `.byok` unlock requires the
    /// COMPLETE cached record to be readable and verified. `.indeterminate`
    /// is kept as a diagnostic state but FAILS CLOSED — an unreadable record
    /// is an unverifiable one, and nothing unverifiable unlocks an official
    /// build. (The condition is transient: the next successful read, or an
    /// online validation, restores access.)
    enum Presence: Equatable { case present, absent, indeterminate }

    /// The cached license's edition standing against the RUNNING policy.
    ///   • `.compatible`   — persisted product ID is approved AND the
    ///     persisted licensed major equals the required major.
    ///   • `.incompatible` — metadata is present but wrong (another product,
    ///     or another major — e.g. a major-1 key read by a 2.x build).
    ///     `licensedMajor` carries the cached major when parseable, for the
    ///     upgrade-purchase copy. Fails closed; the key itself is preserved.
    ///   • `.missingMetadata` — no persisted product/major (never confirmed
    ///     against the current product). Fails closed until an online
    ///     activate/validate succeeds.
    ///   • `.readFailure` — a genuine Keychain READ FAILURE left the edition
    ///     unknown. A diagnostic state that FAILS CLOSED, like every other
    ///     unverifiable shape: only a fully readable, confirmed-compatible
    ///     record unlocks offline.
    enum Edition: Equatable {
        case compatible
        case incompatible(licensedMajor: Int?)
        case missingMetadata
        case readFailure
    }

    let presence: Presence
    let edition: Edition
    /// Epoch instant of the last successful validation, if any (drives the
    /// re-validation throttle). `nil` when never validated or unreadable.
    let lastValidated: Date?

    /// Whether the entitlement layer should treat the user as `.byok` WITHOUT
    /// a network call. Exactly one shape grants: the key AND instance are
    /// readable (`.present`) AND the persisted edition is confirmed
    /// compatible. Everything else — read failures, missing or malformed
    /// metadata, a wrong product, a wrong major — FAILS CLOSED. (Network
    /// trouble still fails open, but only for a user who already holds this
    /// complete, compatible cached record — see `revalidateLicenseIfNeeded`.)
    var grantsBYOK: Bool {
        presence == .present && edition == .compatible
    }
}

// MARK: - LicenseTransport

/// The minimal HTTP surface `LicenseService` needs, so tests can stub the
/// three LemonSqueezy endpoints without a real network. Production uses
/// `URLSessionLicenseTransport`.
protocol LicenseTransport {
    /// POSTs `parameters` as `application/x-www-form-urlencoded` to `path`
    /// (relative to `LicenseService.baseURL`) with `Accept: application/json`,
    /// returning the raw response body and HTTP status code.
    ///
    /// Throws ONLY on a genuine transport failure (offline, DNS, timeout).
    /// Any HTTP status — including 4xx — returns normally so the caller can
    /// branch on the License API's own `activated`/`valid`/`error` fields and
    /// the key status, which carry the real semantics regardless of code.
    func post(path: String, parameters: [String: String]) async throws -> (Data, Int)
}

// MARK: - LicenseService

@MainActor
final class LicenseService {

    // MARK: - Constants

    /// LemonSqueezy API base. Pinned so a future regional move is one line.
    static let baseURL = URL(string: "https://api.lemonsqueezy.com")!

    /// Endpoint paths (relative to `baseURL`). Named, not inline, so the
    /// three call sites and the tests reference one source of truth.
    static let activatePath = "/v1/licenses/activate"
    static let validatePath = "/v1/licenses/validate"
    static let deactivatePath = "/v1/licenses/deactivate"

    /// How stale the last-validated stamp may get before a launch triggers a
    /// background re-validation. Seven days: long enough that an activated
    /// user is effectively offline-first, short enough that a refund/revoke is
    /// caught within a week. A named constant, never an inline literal.
    static let revalidationInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Number of UUID hex chars appended to the device name when labelling
    /// this machine's activation instance, e.g. "Colin\u{2019}s MacBook-1A2B3C4D".
    /// Enough to disambiguate two same-named Macs in the LS dashboard without
    /// being noise. Named, not an inline literal. `nonisolated` so the
    /// `nonisolated` default instance-name helper can read it.
    nonisolated static let instanceNameSuffixLength = 8

    // MARK: - Dependencies

    private let licenseKeySlot: KeychainSlot
    private let instanceIDSlot: KeychainSlot
    private let lastValidatedSlot: KeychainSlot
    /// The confirmed Lemon Squeezy product ID / licensed major for the
    /// on-file key (see `KeychainStore.licensedProductID` / `.licensedMajor`).
    /// Written only after the License API confirmed the product identity;
    /// gate offline access via `LicenseSnapshot.edition`.
    private let licensedProductIDSlot: KeychainSlot
    private let licensedMajorSlot: KeychainSlot
    /// The product/major this build accepts. Injectable so tests exercise
    /// wrong-product, wrong-major, and simulated future-major policies.
    private let policy: LicenseEditionPolicy
    private let transport: LicenseTransport
    /// Injectable wall clock (throttle math + stamping). Production passes
    /// `Date.init`; tests pass a controllable closure.
    private let clock: () -> Date
    /// Produces the `instance_name` label sent to LemonSqueezy. Injectable so
    /// tests assert on a fixed label; production derives it from the host.
    private let instanceNameProvider: () -> String

    /// Asks the user to confirm REPLACING a different license already on this
    /// device (E-01). Returns `true` to proceed with the overwrite, `false` to
    /// abort (activation then throws `.replaceCancelled` before touching the
    /// network or the Keychain). Production presents a modal NSAlert; tests inject
    /// a deterministic answer so they never block on UI. Consulted ONLY when the
    /// incoming key differs from the one on file — same-key and no-current-license
    /// activations never call it (they stay frictionless).
    private let confirmReplace: () async -> Bool

    // MARK: - Init

    /// `nil` dependency arguments resolve to the real Keychain slots /
    /// URLSession transport INSIDE this (MainActor) body — see the file
    /// header for why a default-argument expression couldn't.
    init(
        licenseKeySlot: KeychainSlot? = nil,
        instanceIDSlot: KeychainSlot? = nil,
        lastValidatedSlot: KeychainSlot? = nil,
        licensedProductIDSlot: KeychainSlot? = nil,
        licensedMajorSlot: KeychainSlot? = nil,
        policy: LicenseEditionPolicy? = nil,
        transport: LicenseTransport? = nil,
        clock: @escaping () -> Date = { Date() },
        instanceNameProvider: (() -> String)? = nil,
        confirmReplace: (() async -> Bool)? = nil
    ) {
        self.licenseKeySlot = licenseKeySlot ?? KeychainStore.byokLicenseKey
        self.instanceIDSlot = instanceIDSlot ?? KeychainStore.byokInstanceID
        self.lastValidatedSlot = lastValidatedSlot ?? KeychainStore.byokLastValidated
        self.licensedProductIDSlot = licensedProductIDSlot ?? KeychainStore.licensedProductID
        self.licensedMajorSlot = licensedMajorSlot ?? KeychainStore.licensedMajor
        self.policy = policy ?? .current
        self.transport = transport ?? URLSessionLicenseTransport()
        self.clock = clock
        self.instanceNameProvider = instanceNameProvider ?? LicenseService.defaultInstanceName
        self.confirmReplace = confirmReplace ?? { await LicenseService.presentReplaceConfirmation() }
    }

    // MARK: - Activate

    /// Activates `licenseKey` against LemonSqueezy with a generated
    /// `instance_name` device label. On `activated: true` the response's
    /// `meta.product_id` must be approved by the running
    /// `LicenseEditionPolicy` — the product identity is the security
    /// boundary, checked BEFORE anything is persisted. A mismatch throws
    /// `.wrongProduct` after best-effort deactivating the instance the
    /// attempt just created (so a mistaken paste doesn't consume one of the
    /// key's device slots). On an approved activation, writes the key,
    /// instance ID, validation stamp, and the confirmed product ID + licensed
    /// major together, then returns the `ActivationResult`. On any
    /// non-activation outcome, throws a typed `LicenseError` WITHOUT touching
    /// the Keychain (a failed activation never clobbers an existing good
    /// license).
    func activate(licenseKey: String) async throws -> ActivationResult {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseError.keyInvalid }

        // E-01: never silently replace a DIFFERENT license already on this
        // device. A present key that doesn't match the incoming one means a real
        // (often paying) license would be clobbered — covering BOTH the
        // checkout-return deep link and the manual paste field, which both reach
        // here. Require an explicit user confirmation FIRST, before any network
        // call or Keychain write. Activating the SAME key, or activating with no
        // current license, skips this entirely and stays frictionless. A declined
        // confirmation throws `.replaceCancelled` with the existing license fully
        // intact (never written, never POSTed).
        if let existing = currentLicenseKey(), existing != key {
            guard await confirmReplace() else {
                Log.billing.notice("license activate cancelled — user kept the current license (E-01)")
                throw LicenseError.replaceCancelled
            }
        }

        let response = try await perform(
            path: Self.activatePath,
            parameters: ["license_key": key, "instance_name": instanceNameProvider()]
        )

        guard response.body.activated == true,
              let instanceID = response.body.instance?.id, !instanceID.isEmpty else {
            let error = Self.activationError(from: response)
            Log.billing.error("license activate refused — \(String(describing: error), privacy: .public)")
            throw error
        }

        // Product identity gate: the key activated, but it only licenses
        // THIS build if it belongs to an approved product. Checked before any
        // Keychain write, so a wrong-product key leaves an existing good
        // license untouched. The instance LemonSqueezy just created is freed
        // best-effort — the user shouldn't lose a device slot on their real
        // product to a mistaken paste here.
        let rawProductID = response.body.meta?.productId
        guard let productID = rawProductID, policy.isApproved(productID: productID) else {
            Log.billing.error("license activate refused — product \(rawProductID.map(String.init) ?? "missing", privacy: .public) not approved")
            await deactivateBestEffort(licenseKey: key, instanceID: instanceID)
            throw LicenseError.wrongProduct
        }

        let status = response.body.keyStatus ?? .active
        // Order matters: write the credentials, THEN the confirmed edition
        // metadata, THEN stamp validation, so a present license always has a
        // fresh throttle stamp and never sits keyed without its edition.
        licenseKeySlot.write(key)
        instanceIDSlot.write(instanceID)
        persistEdition(productID: productID)
        stampValidated()
        Log.billing.notice("license activated — instance=\(instanceID, privacy: .public) status=\(status.rawValue, privacy: .public) product=\(productID, privacy: .public)")

        return ActivationResult(
            instanceID: instanceID,
            status: status,
            storeID: response.body.meta?.storeId,
            productID: response.body.meta?.productId,
            customerEmail: response.body.meta?.customerEmail
        )
    }

    // MARK: - Validate

    /// Re-checks the stored license online, including its PRODUCT IDENTITY.
    /// Reads the cached key + instance ID and POSTs to /validate. On a
    /// completed round-trip returns the `ValidationResult`; the throttle
    /// stamp and edition metadata refresh only when the key is both valid
    /// AND for an approved product. The product check applies to EVERY
    /// decoded response, regardless of `valid`: a wrong or MISSING
    /// `meta.product_id` is definitive — the cached edition metadata is
    /// deleted (so the snapshot fails closed offline) and the stamp is never
    /// refreshed, while the key + instance stay on file for the user to see
    /// and deactivate. On a transport failure throws `LicenseError.network`
    /// so the caller can FAIL OPEN — for a user whose complete cached record
    /// is already compatible. Throws `.keyInvalid` if there's no stored key
    /// to validate.
    func validate() async throws -> ValidationResult {
        guard case .found(let key) = licenseKeySlot.readResult(), !key.isEmpty else {
            throw LicenseError.keyInvalid
        }
        var parameters = ["license_key": key]
        // `instance_id` is recommended (ties the check to THIS machine's slot)
        // but optional — omit it cleanly if we somehow lack one.
        if case .found(let instanceID) = instanceIDSlot.readResult(), !instanceID.isEmpty {
            parameters["instance_id"] = instanceID
        }

        let response = try await perform(path: Self.validatePath, parameters: parameters)
        let valid = response.body.valid ?? false
        let status = response.body.keyStatus
        let productID = response.body.meta?.productId
        let approved = policy.isApproved(productID: productID)
        if !approved {
            // Definitive product mismatch — Lemon Squeezy answered and the
            // response does not vouch for THIS build's product (wrong id, or
            // no id at all), whatever `valid` says. Drop the edition metadata
            // so the offline snapshot fails closed; keep the key + instance
            // so Settings can still show and deactivate it (a definitive
            // revocation verdict, handled by the caller, clears the rest).
            // Never stamp — this is not a successful validation.
            licensedProductIDSlot.delete()
            licensedMajorSlot.delete()
            Log.billing.error("license validate — product \(productID.map(String.init) ?? "missing", privacy: .public) not approved; edition metadata cleared")
        } else if valid {
            // A good validation re-confirms the edition, so a pre-edition
            // cache (or one damaged by a partial write) heals here.
            if let productID { persistEdition(productID: productID) }
            stampValidated()
        }
        Log.billing.notice("license validate \u{2192} valid=\(valid, privacy: .public) status=\(status?.rawValue ?? "unknown", privacy: .public) productApproved=\(approved, privacy: .public)")
        return ValidationResult(valid: valid, status: status, productApproved: approved)
    }

    // MARK: - Deactivate

    /// Frees the machine slot for `instanceID` on LemonSqueezy (the "deactivate
    /// a device" flow). PURE w.r.t. local state: it does NOT clear the
    /// Keychain — the caller decides that, because `instanceID` may belong to
    /// ANOTHER device (the at-limit "free up a slot" case) rather than this
    /// one. The Settings "Deactivate this device" flow calls this with the
    /// local instance ID and then `clearLicense()`. Throws `LicenseError` on
    /// failure (transport → `.network`; refusal → mapped from the body).
    func deactivate(instanceID: String) async throws {
        guard case .found(let key) = licenseKeySlot.readResult(), !key.isEmpty else {
            throw LicenseError.keyInvalid
        }
        let response = try await perform(
            path: Self.deactivatePath,
            parameters: ["license_key": key, "instance_id": instanceID]
        )
        guard response.body.deactivated == true else {
            let error = Self.activationError(from: response)
            Log.billing.error("license deactivate refused — \(String(describing: error), privacy: .public)")
            throw error
        }
        Log.billing.notice("license deactivated — instance=\(instanceID, privacy: .public)")
    }

    /// Best-effort deactivation with an EXPLICIT key — for the wrong-product
    /// activation path, where the mismatched key was never persisted so
    /// `deactivate(instanceID:)`'s Keychain read would find nothing (or the
    /// user's real, different license). Failures are logged and swallowed:
    /// freeing the slot is a courtesy, never a gate.
    private func deactivateBestEffort(licenseKey: String, instanceID: String) async {
        do {
            let response = try await perform(
                path: Self.deactivatePath,
                parameters: ["license_key": licenseKey, "instance_id": instanceID]
            )
            if response.body.deactivated != true {
                Log.billing.error("wrong-product cleanup deactivate refused — instance=\(instanceID, privacy: .public)")
            }
        } catch {
            Log.billing.error("wrong-product cleanup deactivate failed — instance=\(instanceID, privacy: .public)")
        }
    }

    // MARK: - Synchronous local state

    /// Network-free snapshot of the stored license, for startup precedence
    /// decisions. See `LicenseSnapshot`.
    func currentLicenseState() -> LicenseSnapshot {
        let keyResult = licenseKeySlot.readResult()
        let instanceResult = instanceIDSlot.readResult()
        let presence: LicenseSnapshot.Presence
        switch (keyResult, instanceResult) {
        case (.found, .found):
            presence = .present
        case (.failure, _), (_, .failure):
            // A genuine read failure on either slot → unknown. Diagnostic
            // only — an unverifiable record fails closed (see `grantsBYOK`).
            presence = .indeterminate
        default:
            presence = .absent
        }

        let productResult = licensedProductIDSlot.readResult()
        let majorResult = licensedMajorSlot.readResult()
        let edition: LicenseSnapshot.Edition
        switch (productResult, majorResult) {
        case (.failure, _), (_, .failure):
            // Genuine read failure → unknown edition. Diagnostic only — an
            // unverifiable edition fails closed (see `grantsBYOK`).
            edition = .readFailure
        case (.found(let rawProduct), .found(let rawMajor)):
            // Unparseable stored values decode to nil and land in
            // `.incompatible` — persisted-but-wrong fails closed.
            let major = Int(rawMajor)
            if policy.isApproved(productID: Int(rawProduct)), major == policy.requiredMajor {
                edition = .compatible
            } else {
                edition = .incompatible(licensedMajor: major)
            }
        default:
            // Definitively unconfirmed (a cache from before the edition
            // metadata existed, or a cleared wrong-product record) → fail
            // closed until an online activate/validate re-confirms.
            edition = .missingMetadata
        }

        return LicenseSnapshot(presence: presence, edition: edition, lastValidated: lastValidatedDate())
    }

    /// The stored activation instance ID, if any (for the deactivate flow).
    func currentInstanceID() -> String? {
        guard case .found(let id) = instanceIDSlot.readResult(), !id.isEmpty else { return nil }
        return id
    }

    /// The license key currently on file (trimmed), or `nil` when none is
    /// readable. Used by the checkout-return deep link to detect an already-
    /// active key (idempotent re-activation) without re-POSTing to LemonSqueezy.
    func currentLicenseKey() -> String? {
        guard case .found(let key) = licenseKeySlot.readResult() else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether enough time has elapsed since the last successful validation to
    /// warrant another network round-trip. True when never validated (no
    /// stamp) or when the stamp is older than `revalidationInterval`.
    func shouldRevalidate() -> Bool {
        guard let last = lastValidatedDate() else { return true }
        return clock().timeIntervalSince(last) >= Self.revalidationInterval
    }

    /// Clears all five license slots (key, instance, validation stamp, and
    /// both edition metadata slots). Used on a definitive revocation and on
    /// "deactivate this device". Idempotent.
    func clearLicense() {
        licenseKeySlot.delete()
        instanceIDSlot.delete()
        lastValidatedSlot.delete()
        licensedProductIDSlot.delete()
        licensedMajorSlot.delete()
        Log.billing.notice("license cleared from keychain")
    }

    // MARK: - Edition metadata

    /// Persists the CONFIRMED product ID and the policy's required major
    /// together — always as a pair, only after the License API vouched for
    /// the product. The stored major records which Zerro major this license
    /// was confirmed for, so a future major's build can fail closed (and name
    /// the licensed major) without a network call.
    private func persistEdition(productID: Int) {
        licensedProductIDSlot.write(String(productID))
        licensedMajorSlot.write(String(policy.requiredMajor))
    }

    // MARK: - Throttle stamp

    /// Writes "now" (epoch seconds) to the last-validated slot.
    private func stampValidated() {
        lastValidatedSlot.write(String(Int(clock().timeIntervalSince1970)))
    }

    /// Reads the last-validated stamp as a `Date`, or `nil` if absent /
    /// unreadable / unparseable.
    private func lastValidatedDate() -> Date? {
        guard case .found(let raw) = lastValidatedSlot.readResult(),
              let seconds = Int(raw) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: - Networking core

    /// One decoded response: the HTTP status plus the parsed body.
    private struct DecodedResponse {
        let statusCode: Int
        let body: LicenseAPIResponse
    }

    /// Performs the POST and decodes the body, mapping transport failures to
    /// `.network` and decode failures to `.malformedResponse`.
    private func perform(path: String, parameters: [String: String]) async throws -> DecodedResponse {
        let data: Data
        let statusCode: Int
        do {
            (data, statusCode) = try await transport.post(path: path, parameters: parameters)
        } catch {
            // Network-class text only — never the key. Logged `.private` per
            // the secret-handling contract.
            Log.billing.error("license request transport failure: \(error.localizedDescription, privacy: .private)")
            throw LicenseError.network(error.localizedDescription)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let body = try decoder.decode(LicenseAPIResponse.self, from: data)
            return DecodedResponse(statusCode: statusCode, body: body)
        } catch {
            Log.billing.error("license response decode failed (status \(statusCode, privacy: .public))")
            throw LicenseError.malformedResponse
        }
    }

    /// Maps a non-success activation/deactivation body to a typed error.
    /// Branches on the DEFINITIVE key status first (disabled/expired), then
    /// the error text (activation-limit / not-found), then defaults to
    /// `.keyInvalid` (route to paywall) or `.malformedResponse` if the body
    /// carried nothing recognizable.
    private static func activationError(from response: DecodedResponse) -> LicenseError {
        switch response.body.keyStatus {
        case .disabled: return .keyDisabled
        case .expired:  return .keyExpired
        case .active, .inactive, .none: break
        }
        let message = response.body.error?.lowercased() ?? ""
        if message.contains("activation limit") || message.contains("reached the") {
            return .atActivationLimit
        }
        if message.contains("not found") || response.statusCode == 404 {
            return .keyInvalid
        }
        return message.isEmpty ? .malformedResponse : .keyInvalid
    }

    // MARK: - Instance name

    /// Default device label for an activation instance: the localized host
    /// name plus a short UUID suffix so two same-named Macs stay distinct in
    /// the LemonSqueezy dashboard. `nonisolated static` so the init default
    /// can reference it without MainActor friction.
    nonisolated static func defaultInstanceName() -> String {
        let host = Host.current().localizedName ?? "Mac"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(instanceNameSuffixLength)
        return "\(host)-\(suffix)"
    }

    // MARK: - Replace confirmation (E-01)

    /// The production "Replace your current license?" confirmation — a modal
    /// NSAlert presented on the main thread (NSAlert is main-thread only; this
    /// type is already `@MainActor`). Returns `true` only if the user explicitly
    /// chooses Replace. The license key is NEVER shown (secret-handling contract);
    /// the copy is generic. Tests inject a stub `confirmReplace`, so this never
    /// runs headless.
    @MainActor
    static func presentReplaceConfirmation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace your current license?"
        alert.informativeText = "This Mac is already activated with a different license. Activating this key will replace it on this device. Your existing license stays valid, and you can re-activate it later."
        alert.addButton(withTitle: "Replace License")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Preview / test support
    //
    // Non-`#if DEBUG` because `#Preview` blocks compile in every config.
    // Builds a service over in-memory slots + an offline transport so SwiftUI
    // previews never touch the real Keychain or network.

    /// An in-memory license service. `licensed: true` seeds a present,
    /// edition-compatible license (key + instance + confirmed product/major)
    /// so previews can render the `.byok` Settings/paywall states; the
    /// transport is offline (any network call fails open).
    static func inMemory(licensed: Bool = false) -> LicenseService {
        let policy = LicenseEditionPolicy.current
        let productID = policy.approvedProductIDs.first
        return LicenseService(
            licenseKeySlot: InMemoryKeychainSlot(licensed ? "PREVIEW-LICENSE-KEY" : nil),
            instanceIDSlot: InMemoryKeychainSlot(licensed ? "preview-instance-id" : nil),
            lastValidatedSlot: InMemoryKeychainSlot(licensed ? String(Int(Date().timeIntervalSince1970)) : nil),
            licensedProductIDSlot: InMemoryKeychainSlot(licensed ? productID.map(String.init) : nil),
            licensedMajorSlot: InMemoryKeychainSlot(licensed ? String(policy.requiredMajor) : nil),
            policy: policy,
            transport: OfflineLicenseTransport(),
            instanceNameProvider: { "Preview-00000000" }
        )
    }
}

// MARK: - LicenseAPIResponse (decoding)

/// The subset of the Lemon Squeezy License API response shape the app reads.
/// One struct covers activate / validate / deactivate — each populates the
/// fields relevant to it (`activated` / `valid` / `deactivated`), the rest
/// decode to `nil`. Decoded with `.convertFromSnakeCase`, so e.g.
/// `activation_limit` \u{2192} `activationLimit`.
struct LicenseAPIResponse: Decodable {
    let activated: Bool?
    let valid: Bool?
    let deactivated: Bool?
    let error: String?
    let licenseKey: LicenseKeyObject?
    let instance: InstanceObject?
    let meta: MetaObject?

    /// The key's status as a typed `LicenseKeyStatus`, or `nil` if absent /
    /// unrecognized.
    var keyStatus: LicenseKeyStatus? {
        licenseKey?.status.flatMap(LicenseKeyStatus.init(rawValue:))
    }

    struct LicenseKeyObject: Decodable {
        let id: Int?
        let status: String?
        let activationLimit: Int?
        let activationUsage: Int?
    }

    struct InstanceObject: Decodable {
        let id: String?
        let name: String?
    }

    struct MetaObject: Decodable {
        let storeId: Int?
        let productId: Int?
        let variantId: Int?
        let customerEmail: String?
        let customerName: String?
    }
}

// MARK: - URLSessionLicenseTransport

/// Production `LicenseTransport` over a dedicated `URLSession`. Mirrors
/// `OpenAIClient`'s session config (no cache, `Accept: application/json`),
/// but POSTs `application/x-www-form-urlencoded` bodies as the License API
/// requires.
struct URLSessionLicenseTransport: LicenseTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSessionLicenseTransport.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }

    func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: LicenseService.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeForm(parameters)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }

    /// Percent-encodes `parameters` into a form body. License keys and
    /// instance IDs are UUID-/hex-shaped (no `+`), so the `+`-vs-`%20`
    /// ambiguity of `application/x-www-form-urlencoded` doesn't bite here;
    /// `URLComponents` percent-encodes everything else correctly.
    static func encodeForm(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

// MARK: - OfflineLicenseTransport

/// A `LicenseTransport` that always reports the network unreachable. Backs
/// `LicenseService.inMemory()` so previews never make a real request; any
/// validation against it throws `.network` and the caller fails open.
struct OfflineLicenseTransport: LicenseTransport {
    func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
        throw URLError(.notConnectedToInternet)
    }
}
