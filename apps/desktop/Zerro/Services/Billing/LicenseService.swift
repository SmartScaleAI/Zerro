//
//  LicenseService.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  Phase C of the billing system — the BYOK ("bring your own key") one-time
//  license layer. Wraps the three LemonSqueezy License API endpoints
//  (activate / validate / deactivate) and owns the Keychain credentials that
//  back a `.byok` entitlement: the raw license key, the activation instance
//  ID, and the last-validated throttle stamp.
//
//  This is the ONLY networked surface Phase C adds, and it talks to exactly
//  one host: LemonSqueezy's License API over HTTPS. No Supabase, no proxy,
//  no managed-subscription code — those are Phases D–F.
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

    /// User-facing, non-punitive copy for each failure. Mirrors
    /// `RecordingFailureReason.userMessage`'s flat single-line style.
    var userFacingMessage: String {
        switch self {
        case .atActivationLimit:
            return "This license is already active on the maximum number of devices. Deactivate one from your account, then try again."
        case .keyInvalid:
            return "We couldn\u{2019}t find that license key \u{2014} double-check it and try again."
        case .keyDisabled:
            return "This license has been deactivated. If you think that\u{2019}s a mistake, reach out to support."
        case .keyExpired:
            return "This license has expired."
        case .network:
            return "Couldn\u{2019}t reach the licensing server \u{2014} check your connection and try again."
        case .malformedResponse:
            return "Something went wrong activating your license \u{2014} please try again."
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
    /// The entitlement precedence treats `.present` and `.indeterminate` the
    /// SAME (`grantsBYOK == true`): a flaky Keychain read must never drop a
    /// licensed-past-trial user to `.expired`. The downside — wrongly granting
    /// `.byok` to a brand-new user during a transient read failure — is the
    /// fail-OPEN direction the billing contract explicitly prefers, and it is
    /// transient.
    enum Presence: Equatable { case present, absent, indeterminate }

    let presence: Presence
    /// Epoch instant of the last successful validation, if any (drives the
    /// re-validation throttle). `nil` when never validated or unreadable.
    let lastValidated: Date?

    /// Whether the entitlement layer should treat the user as `.byok` WITHOUT
    /// a network call. True unless we DEFINITIVELY saw no license.
    var grantsBYOK: Bool { presence != .absent }
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
    /// E7: the license's `created_at` (epoch-seconds string), the start of the
    /// BYOK 1-year update window. Display/update-gating only — never consulted
    /// by activation, validation, or the generation gate.
    private let licenseCreatedAtSlot: KeychainSlot
    private let transport: LicenseTransport
    /// True when no transport was injected (we built the real URLSession
    /// one) — the ONLY configuration where the DEBUG local-stack bypass in
    /// `activate` may fire. Unit tests inject stub transports and must stay
    /// hermetic even though the shared Xcode scheme ships the ZERRO_* env
    /// vars enabled — without this gate the bypass hijacked the stubs and
    /// deterministically failed 3 LicenseServiceTests (Appendix E9).
    private let usesRealTransport: Bool
    /// Injectable wall clock (throttle math + stamping). Production passes
    /// `Date.init`; tests pass a controllable closure.
    private let clock: () -> Date
    /// Produces the `instance_name` label sent to LemonSqueezy. Injectable so
    /// tests assert on a fixed label; production derives it from the host.
    private let instanceNameProvider: () -> String

    // MARK: - Init

    /// `nil` dependency arguments resolve to the real Keychain slots /
    /// URLSession transport INSIDE this (MainActor) body — see the file
    /// header for why a default-argument expression couldn't.
    init(
        licenseKeySlot: KeychainSlot? = nil,
        instanceIDSlot: KeychainSlot? = nil,
        lastValidatedSlot: KeychainSlot? = nil,
        licenseCreatedAtSlot: KeychainSlot? = nil,
        transport: LicenseTransport? = nil,
        clock: @escaping () -> Date = { Date() },
        instanceNameProvider: (() -> String)? = nil
    ) {
        self.licenseKeySlot = licenseKeySlot ?? KeychainStore.byokLicenseKey
        self.instanceIDSlot = instanceIDSlot ?? KeychainStore.byokInstanceID
        self.lastValidatedSlot = lastValidatedSlot ?? KeychainStore.byokLastValidated
        self.licenseCreatedAtSlot = licenseCreatedAtSlot ?? KeychainStore.byokLicenseCreatedAt
        self.usesRealTransport = (transport == nil)
        self.transport = transport ?? URLSessionLicenseTransport()
        self.clock = clock
        self.instanceNameProvider = instanceNameProvider ?? LicenseService.defaultInstanceName
    }

    // MARK: - Activate

    /// Activates `licenseKey` against LemonSqueezy with a generated
    /// `instance_name` device label. On `activated: true`, writes the key +
    /// returned instance ID to the Keychain and stamps `byokLastValidated`,
    /// then returns the `ActivationResult`. On any non-activation outcome,
    /// throws a typed `LicenseError` WITHOUT touching the Keychain (a failed
    /// activation never clobbers an existing good license).
    func activate(licenseKey: String) async throws -> ActivationResult {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseError.keyInvalid }

        #if DEBUG
        // Local-backend testing bypass — active ONLY when the debug build is
        // pointed at a local stack via ZERRO_FUNCTIONS_BASE_URL (the same env
        // var that overrides ManagedBackend.baseURL). Local test keys are
        // seeded straight into the local DB and don't exist in LemonSqueezy,
        // so the real /activate call would always refuse them. Skip it and do
        // exactly what a successful activation does: write the key + a fake
        // instance ID, stamp validation, return a normal ActivationResult.
        // EntitlementStore's step-2 /session probe then runs unchanged against
        // the LOCAL backend and resolves Managed vs BYOK from the local mirror.
        // Compiled out of release builds; inert in debug unless the var is set.
        // Gated on `usesRealTransport` so an injected stub transport (unit
        // tests) is NEVER bypassed — the scheme ships the env var enabled,
        // and without this gate every activation test silently "succeeded".
        if usesRealTransport,
           ProcessInfo.processInfo.environment["ZERRO_FUNCTIONS_BASE_URL"] != nil {
            let instanceID = "local-dev-instance"
            licenseKeySlot.write(key)
            instanceIDSlot.write(instanceID)
            stampValidated()
            Log.billing.notice("license activated via LOCAL DEV BYPASS — LemonSqueezy not contacted")
            return ActivationResult(
                instanceID: instanceID,
                status: .active,
                storeID: nil,
                productID: nil,
                customerEmail: nil
            )
        }
        #endif

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

        let status = response.body.keyStatus ?? .active
        // Order matters: write the credentials, THEN stamp validation, so a
        // present license always has a fresh throttle stamp.
        licenseKeySlot.write(key)
        instanceIDSlot.write(instanceID)
        stampValidated()
        // E7: a fresh activation (incl. a pasted renewal key) carries the new
        // license's created_at — the update window restarts from it.
        persistCreatedAt(response.body.licenseKey?.createdAt)
        Log.billing.notice("license activated — instance=\(instanceID, privacy: .public) status=\(status.rawValue, privacy: .public)")

        return ActivationResult(
            instanceID: instanceID,
            status: status,
            storeID: response.body.meta?.storeId,
            productID: response.body.meta?.productId,
            customerEmail: response.body.meta?.customerEmail
        )
    }

    // MARK: - Validate

    /// Re-checks the stored license online. Reads the cached key + instance ID
    /// and POSTs to /validate. On a completed round-trip returns the
    /// `ValidationResult` (and refreshes the throttle stamp when `valid`). On
    /// a transport failure throws `LicenseError.network` so the caller can
    /// FAIL OPEN. Throws `.keyInvalid` if there's no stored key to validate.
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
        if valid {
            stampValidated()
            // E7: refresh the update-window start on every good validation, so
            // a pre-E7 activation backfills its window on the next throttled
            // re-validation without re-activating.
            persistCreatedAt(response.body.licenseKey?.createdAt)
        }
        Log.billing.notice("license validate \u{2192} valid=\(valid, privacy: .public) status=\(status?.rawValue ?? "unknown", privacy: .public)")
        return ValidationResult(valid: valid, status: status)
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
            // A genuine read failure on either slot → unknown, fail-open.
            presence = .indeterminate
        default:
            presence = .absent
        }
        return LicenseSnapshot(presence: presence, lastValidated: lastValidatedDate())
    }

    /// The stored activation instance ID, if any (for the deactivate flow).
    func currentInstanceID() -> String? {
        guard case .found(let id) = instanceIDSlot.readResult(), !id.isEmpty else { return nil }
        return id
    }

    /// Whether enough time has elapsed since the last successful validation to
    /// warrant another network round-trip. True when never validated (no
    /// stamp) or when the stamp is older than `revalidationInterval`.
    func shouldRevalidate() -> Bool {
        guard let last = lastValidatedDate() else { return true }
        return clock().timeIntervalSince(last) >= Self.revalidationInterval
    }

    /// Clears all four license slots. Used on a definitive revocation and on
    /// "deactivate this device". Idempotent.
    func clearLicense() {
        licenseKeySlot.delete()
        instanceIDSlot.delete()
        lastValidatedSlot.delete()
        licenseCreatedAtSlot.delete()
        Log.billing.notice("license cleared from keychain")
    }

    // MARK: - Update window (E7 / Appendix F)
    //
    // The BYOK "1 year of updates" window: starts at the license's
    // `created_at` (LemonSqueezy), ends one calendar year later. This is
    // STRICTLY about which appcast items the Sparkle updater offers
    // (`UpdateWindowPolicy`) — it never touches license validity, activation,
    // or the generation gate, and it must NEVER be conflated with the LS
    // key-expiry `expires_at` (the F.2 trap: that flips validate to
    // `status:"expired"` → `isDefinitiveRevocation` → wrongly blocks
    // generation). Out-of-window licenses activate, validate, and generate
    // exactly like in-window ones.

    /// End of this license's update window (`created_at` + 1 year), or `nil`
    /// when the window start was never persisted (pre-E7 activation that
    /// hasn't re-validated yet, Keychain read failure) — callers FAIL OPEN on
    /// `nil` per the F.0 decision.
    func updateWindowEnd() -> Date? {
        guard case .found(let raw) = licenseCreatedAtSlot.readResult(),
              let seconds = TimeInterval(raw) else { return nil }
        return Self.updateWindowEnd(createdAt: Date(timeIntervalSince1970: seconds))
    }

    /// `createdAt` + 1 calendar year (Gregorian, so leap years are exact);
    /// 365 days as a defensive fallback if calendar math ever fails.
    /// `nonisolated` so the (non-MainActor) updater policy can call it.
    nonisolated static func updateWindowEnd(createdAt: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(byAdding: .year, value: 1, to: createdAt)
            ?? createdAt.addingTimeInterval(365 * 24 * 60 * 60)
    }

    /// Parses the License API's `created_at` string. The documented shape is
    /// ISO-8601 with fractional seconds ("2026-04-26T13:36:11.000000Z"), but
    /// LS has historically also emitted plain ISO and the MySQL-style
    /// "yyyy-MM-dd HH:mm:ss" — accept all three rather than silently dropping
    /// the window start over a formatting change. `nil` on anything else
    /// (the window then stays unset → fail-open).
    nonisolated static func parseCreatedAt(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ManagedBackend.parseISODate(raw) { return date }
        return mysqlStyle.date(from: raw)
    }

    private nonisolated static let mysqlStyle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Persists a parseable `created_at` as epoch seconds (the `lastValidated`
    /// encoding). An absent/unparseable value KEEPS any previously-stored
    /// window start — never erase good data over a response shape hiccup.
    private func persistCreatedAt(_ raw: String?) {
        guard let date = Self.parseCreatedAt(raw) else { return }
        licenseCreatedAtSlot.write(String(Int(date.timeIntervalSince1970)))
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

    // MARK: - Preview / test support
    //
    // Non-`#if DEBUG` because `#Preview` blocks compile in every config.
    // Builds a service over in-memory slots + an offline transport so SwiftUI
    // previews never touch the real Keychain or network.

    /// An in-memory license service. `licensed: true` seeds a present license
    /// (key + instance) so previews can render the `.byok` Settings/paywall
    /// states; the transport is offline (any network call fails open).
    static func inMemory(licensed: Bool = false) -> LicenseService {
        LicenseService(
            licenseKeySlot: InMemoryKeychainSlot(licensed ? "PREVIEW-LICENSE-KEY" : nil),
            instanceIDSlot: InMemoryKeychainSlot(licensed ? "preview-instance-id" : nil),
            lastValidatedSlot: InMemoryKeychainSlot(licensed ? String(Int(Date().timeIntervalSince1970)) : nil),
            licenseCreatedAtSlot: InMemoryKeychainSlot(nil),
            transport: OfflineLicenseTransport(),
            instanceNameProvider: { "Preview-00000000" }
        )
    }
}

// MARK: - LicenseAPIResponse (decoding)

/// The subset of the LemonSqueezy License API response shape Phase C reads.
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
        /// E7: the license's issue instant (`created_at`) — the update-window
        /// start. Kept as the raw string here; `LicenseService.parseCreatedAt`
        /// owns the tolerant parsing. NEVER decode `expires_at` for the
        /// window — that's LS key-expiry, the F.2 revocation trap.
        let createdAt: String?
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
