//
//  KeychainStore.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Minimal Keychain wrapper for secrets (API keys, license credentials). Backed by
//  `SecItem*` Security framework calls — no third-party dependency.
//  Instances are configured with a service identifier + account name;
//  the provider-key statics (`.openAIAPIKey` etc.), the local trial-clock
//  slots (`.trialStartDate` / `.trialMaxDateSeen`), and the license slots
//  all share the same shape.
//
//  MARK: - Persistence & access-group scoping
//  ------------------------------------------
//  Several values here must SURVIVE app deletion + reinstall: the local
//  trial-clock start date is the trial's abuse-resistance, and the BYOK
//  license is a convenience the user shouldn't have to re-enter.
//  Keychain generic-password items give us that for free — the OS retains
//  them past app deletion — but the durability depends on item SCOPE:
//
//   (a) Items are intentionally scoped to the app's DEFAULT access group,
//       derived from the code-signing identity. We deliberately set NO
//       explicit `kSecAttrAccessGroup`: for a single, NON-sandboxed
//       Developer-ID app that shares no Keychain with extensions, the
//       default group is exactly what we want, and an explicit group would
//       require a Keychain-Sharing entitlement + an `$(AppIdentifierPrefix)`
//       -prefixed group for no benefit. (App Sandbox is OFF by design — see
//       Zerro.entitlements, audio-input only — which is what lets these
//       items persist in the login keychain across reinstalls of the same
//       signed app.)
//
//   (b) CONSEQUENCE — scope is per signing identity. An item written by a
//       differently-signed build lives in a DIFFERENT scope and is invisible
//       across them: a local Xcode DEBUG run (development cert) and the
//       notarized DEVELOPER ID release do NOT share these items. This is
//       expected, not a bug. It means a debug-build "reinstall" test only
//       proves the logic within the debug scope — see the reinstall-test
//       note below for the authoritative procedure.
//
//   (c) Writes set the slot's `accessible` protection class (see `write()`),
//       `kSecAttrAccessibleAfterFirstUnlock` by default, so entitlement
//       evaluation can read these from launch / background lifecycle points
//       after the first post-reboot unlock. This does not weaken persistence;
//       it's the right class for app-lifecycle secrets not tied to active
//       user interaction. No `kSecAttrSynchronizable` — these are
//       device-local, not iCloud-Keychain-synced. TRIAL slots use the
//       `…ThisDeviceOnly` variant so trial state is additionally excluded
//       from encrypted backups and Migration Assistant (a migrated Mac gets
//       its own trial rather than inheriting another machine's clock): the
//       local trial-clock slots (`trialStartDate` / `trialMaxDateSeen`,
//       read by `TrialManager`). The
//       license and provider-key slots deliberately stay
//       AfterFirstUnlock so they survive a backup restore / migration.
//
//  MARK: - How to actually test reinstall persistence
//  --------------------------------------------------
//  • Stop + re-run in Xcode does NOT test reinstall (nothing is removed —
//    the item is simply read again).
//  • Deleting the DerivedData product `.app` and re-running tests only the
//    persistence LOGIC within the debug signing scope (per (b) above).
//  • AUTHORITATIVE test (validate against a DEVELOPER ID build, not debug):
//    install the signed build to /Applications, start the trial and advance
//    it (DEBUG trial controls if testing a debug-signed build in isolation),
//    move the app to Trash + empty it, reinstall the SAME signed build, and
//    relaunch — the trial must RESUME at the same day count, never reset to
//    a fresh clock.
//

import Foundation
import os
import Security

// MARK: - KeychainReadResult

/// Outcome of a Keychain read that DISTINGUISHES "nothing stored yet" from
/// "the read genuinely failed". The plain `read() -> String?` API collapses
/// both into `nil`, which is fine for the API-key flow (no value → prompt
/// for one) but NOT for the trial clock: the two cases must diverge.
///
///   • `.found`   — a value is present and decoded.
///   • `.absent`  — the item does not exist (`errSecItemNotFound`). For the
///                  trial this means first launch — establish the clock.
///   • `.failure` — an actual `SecItem*` error (locked keychain, decode
///                  failure, unexpected OSStatus). The trial MUST fail OPEN
///                  on this: a flaky read can never become a lockout.
enum KeychainReadResult: Equatable {
    case found(String)
    case absent
    case failure(OSStatus)
}

// MARK: - KeychainSlot

/// The narrow read/write/delete surface the billing layers depend on, so
/// `LicenseService` / `TrialManager` / `EntitlementStore` can be driven
/// by in-memory fakes in tests and previews without ever touching the real
/// Keychain. `KeychainStore` is the production conformer; `InMemoryKeychainSlot`
/// is the fake.
protocol KeychainSlot {
    /// Read distinguishing absent from a genuine failure (see
    /// `KeychainReadResult`).
    func readResult() -> KeychainReadResult
    func write(_ value: String)
    func delete()
}

extension KeychainSlot {
    /// Convenience: the stored string, or `nil` for either "absent" or a
    /// read failure — sufficient for the API-key flows, which treat both
    /// the same way. (KeychainStore's own `read()` predates this and stays.)
    func read() -> String? {
        if case .found(let value) = readResult() { return value }
        return nil
    }
}

struct KeychainStore: KeychainSlot {
    let service: String
    let account: String
    /// Protection class applied on write. AfterFirstUnlock by default (items
    /// survive backup restore / Migration Assistant — right for license/BYOK);
    /// the trial slots opt into `…ThisDeviceOnly` (E-03, see the file header).
    let accessible: CFString

    init(
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) {
        self.service = service
        self.account = account
        self.accessible = accessible
    }

    /// Convenience: the stored string, or `nil` for either "absent" or a
    /// read failure. Sufficient for the API-key flow, which treats both the
    /// same way. Anything that must tell those apart (the trial clock) reads
    /// `readResult()` instead.
    func read() -> String? {
        if case .found(let value) = readResult() { return value }
        return nil
    }

    func readResult() -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // Item exists but its data won't decode → treat as a failure,
            // not absence: we don't know it's truly gone, so callers should
            // fail open rather than re-initialize over it.
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failure(errSecDecode)
            }
            return .found(value)
        case errSecItemNotFound:
            return .absent
        default:
            return .failure(status)
        }
    }

    func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Accessibility is set on BOTH paths so the value is readable from
        // launch / background lifecycle points after first unlock, and so an
        // item written before this attribute existed — or under a previous
        // class — gets UPGRADED on its next write (that's how an older trial
        // clock item migrates to ThisDeviceOnly without a forced re-write:
        // `trialMaxDateSeen` rewrites on every evaluation).
        // `kSecAttrAccessible` is a write-time attribute only — reads (see
        // `readResult()`) match on class+service+account and are unaffected.
        // See the file header for the per-slot class choice.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = accessible
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension KeychainStore {
    private static let defaultService = Bundle.main.bundleIdentifier ?? "com.zerro.app"

    // MARK: - Provider API-key slots (multi-model 6C: one per provider)
    //
    // BYOK is multi-provider: the user may store any subset of the three
    // keys. `ProviderKeys` is the canonical resolver (slot lookup, trimmed
    // read, availability set for the key-gated picker). The OpenAI key ALSO
    // powers CLOUD transcription — optional now that on-device whisper.cpp
    // transcribes with no key, so no single key is mandatory.

    static let openAIAPIKey = KeychainStore(service: defaultService, account: "openai_api_key")
    static let geminiAPIKey = KeychainStore(service: defaultService, account: "gemini_api_key")
    static let anthropicAPIKey = KeychainStore(service: defaultService, account: "anthropic_api_key")

    // MARK: - BYOK license slots (Phase C)
    //
    // The one-time LemonSqueezy license the user buys/enters. Stored in the
    // Keychain — NOT UserDefaults / @AppStorage — for two reasons: the raw
    // key is a SECRET, and (like the trial slots) it should SURVIVE an app
    // uninstall/reinstall so a paying user never has to re-activate after a
    // reinstall of the same signed build. Same per-signing-identity scoping
    // caveat as the trial slots applies (see the file header).

    /// The raw license key the user bought/entered. SECRET — never logged,
    /// even `.private`. Read at activation/validation time; its presence (with
    /// `byokInstanceID`) is what makes the entitlement `.byok` synchronously
    /// at startup, before any network re-validation.
    static let byokLicenseKey = KeychainStore(service: defaultService, account: "byok_license_key")

    /// The `instance.id` LemonSqueezy returns from a successful activation.
    /// REQUIRED to validate (re-check) and to deactivate (free a machine
    /// slot), so it's persisted beside the key. Not a secret in the same way
    /// the key is, but kept in the Keychain for the same reinstall-survival
    /// reason and so the two values can never drift apart across stores.
    static let byokInstanceID = KeychainStore(service: defaultService, account: "byok_instance_id")

    /// Epoch-seconds string (same encoding as the trial slots) of the last
    /// SUCCESSFUL online validation. Drives the throttle on periodic
    /// re-validation (see `LicenseService.revalidationInterval`): once
    /// activated, the app trusts the cached license offline and only re-hits
    /// LemonSqueezy when this stamp is older than the threshold. Not a secret
    /// — it could live in UserDefaults — but kept beside the key so all three
    /// license values share one store and one lifecycle (written together on
    /// activate/validate, deleted together on deactivate/revocation).
    static let byokLastValidated = KeychainStore(service: defaultService, account: "byok_last_validated")

    // MARK: - License edition metadata
    //
    // The two values that bind the on-file key to the product and major it
    // licenses, written ONLY after Lemon Squeezy confirmed the product
    // identity (activation or a validated round-trip against the running
    // `LicenseEditionPolicy`). Kept in the Keychain beside the key — and
    // cleared with it — so they survive a reinstall and never drift apart
    // from the key they describe. NOT secrets, but they gate offline access:
    // a cached key whose metadata is absent or mismatched fails closed in an
    // official build until it re-activates/validates against the current
    // product.

    /// The Lemon Squeezy `meta.product_id` the on-file key was confirmed
    /// against, as a decimal string.
    static let licensedProductID = KeychainStore(service: defaultService, account: "licensed_product_id")

    /// The license major the on-file key covers (e.g. "1" for every Zerro
    /// 1.x.x build), as a decimal string. A Zerro 2.x build reading a cached
    /// major-1 record fails closed into the new-version purchase flow.
    static let licensedMajor = KeychainStore(service: defaultService, account: "licensed_major")

    // MARK: - Local trial clock
    //
    // The two dates behind the local free trial (see `TrialManager`): purely
    // on-device, no account and no network. Both are ThisDeviceOnly — the
    // trial clock must not ride encrypted backups or Migration Assistant to
    // another Mac — and both survive a reinstall of the SAME signed app (per
    // the scoping rules in the file header, a debug-signed and a Developer ID
    // build keep separate clocks).

    /// The instant the local trial began. Written once, on first launch,
    /// never overwritten.
    static let trialStartDate = KeychainStore(
        service: defaultService,
        account: "trial_start_date",
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )

    /// The latest wall-clock instant the app has ever observed. The trial's
    /// elapsed time is measured against `max(now, maxDateSeen)`, so winding
    /// the system clock backward can't rewind the trial. See `TrialManager`.
    static let trialMaxDateSeen = KeychainStore(
        service: defaultService,
        account: "trial_max_date_seen",
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )

    #if DEBUG
    /// DEBUG launch diagnostic: logs only the DISPOSITION (`found` / `absent`
    /// / `failure`) of the trial slot reads — never the values — so reinstall
    /// persistence is observable without attaching a debugger. Covers the
    /// local trial-clock slots (start/maxSeen; on a true same-build reinstall
    /// the start slot should read `found`, on a first-ever launch or a
    /// different signing scope it reads `absent`).
    /// Dispositions are `.public` — they carry no secret.
    static func debugLogTrialSlotDisposition() {
        func disposition(_ result: KeychainReadResult) -> String {
            switch result {
            case .found:   return "found"
            case .absent:  return "absent"
            case .failure: return "failure"
            }
        }
        Log.state.notice("trial keychain @launch — start=\(disposition(trialStartDate.readResult()), privacy: .public) maxSeen=\(disposition(trialMaxDateSeen.readResult()), privacy: .public)")
    }
    #endif
}

// MARK: - InMemoryKeychainSlot

/// A non-persistent `KeychainSlot` backed by a single in-memory string.
/// Used by the billing unit tests and by SwiftUI previews so neither touches
/// the developer's real login Keychain. Kept out of `#if DEBUG` because
/// `#Preview` blocks compile in every configuration; the type is a tiny,
/// unused-in-production reference holder.
///
/// A reference type (not a struct) so the same instance can be shared between
/// a billing layer and the code seeding it, and so successive reads/writes
/// observe each other.
final class InMemoryKeychainSlot: KeychainSlot {
    private var value: String?
    /// When `true`, every `readResult()` reports `.failure` regardless of
    /// stored value — lets tests exercise the read-failure paths
    /// deterministically.
    var simulateReadFailure = false

    init(_ initialValue: String? = nil) {
        self.value = initialValue
    }

    func readResult() -> KeychainReadResult {
        if simulateReadFailure { return .failure(errSecAuthFailed) }
        if let value { return .found(value) }
        return .absent
    }

    func write(_ value: String) { self.value = value }

    func delete() { value = nil }
}
