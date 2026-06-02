//
//  KeychainStore.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Minimal Keychain wrapper for secrets (API keys, tokens). Backed by
//  `SecItem*` Security framework calls — no third-party dependency.
//  Instances are configured with a service identifier + account name;
//  the static `.openAIAPIKey` convenience covers the API key, and the
//  Phase B trial slots (and incoming Phase C license slot) share the
//  same shape.
//
//  MARK: - Persistence & access-group scoping (read before Phase C)
//  ---------------------------------------------------------------
//  Several values here must SURVIVE app deletion + reinstall: the trial
//  start date (Phase B) is the trial's abuse-resistance, and the BYOK
//  license (Phase C) is a convenience the user shouldn't have to re-enter.
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
//   (c) Writes set `kSecAttrAccessibleAfterFirstUnlock` (see `write()`) so
//       entitlement evaluation can read these from launch / background
//       lifecycle points after the first post-reboot unlock. This does not
//       weaken persistence; it's the right class for app-lifecycle secrets
//       not tied to active user interaction. No `kSecAttrSynchronizable` —
//       these are device-local, not iCloud-Keychain-synced.
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
//    relaunch — the trial must RESUME at the same day count, not reset to 7.
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

/// The narrow read/write/delete surface the trial clock depends on, so
/// `TrialManager` can be driven by an in-memory fake in tests and previews
/// without ever touching the real Keychain. `KeychainStore` is the
/// production conformer; `InMemoryKeychainSlot` is the fake.
protocol KeychainSlot {
    /// Read distinguishing absent from a genuine failure (see
    /// `KeychainReadResult`).
    func readResult() -> KeychainReadResult
    func write(_ value: String)
    func delete()
}

struct KeychainStore: KeychainSlot {
    let service: String
    let account: String

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
        // item written before this attribute existed gets upgraded on its
        // next write. `kSecAttrAccessible` is a write-time attribute only —
        // reads (see `readResult()`) match on class+service+account and are
        // unaffected. See the file header for why AfterFirstUnlock.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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

    /// The single API-key slot we store today. When multi-provider support
    /// lands, swap callers to a parameterized factory.
    static let openAIAPIKey = KeychainStore(service: defaultService, account: "openai_api_key")

    // MARK: - Trial clock slots (Phase B)
    //
    // The 7-day trial's two persisted values live in the Keychain — NOT
    // UserDefaults / @AppStorage — specifically so they survive an app
    // uninstall/reinstall: the OS retains generic-password items past app
    // deletion, which is the entire reason the trial start can't be reset by
    // reinstalling. Both store an epoch-seconds string (see `TrialManager`).

    /// First-launch trial start instant. Written ONCE, never overwritten —
    /// reinstalling must not reset the trial.
    static let trialStartDate = KeychainStore(service: defaultService, account: "trial_start_date")

    /// The latest wall-clock instant the app has ever observed. The trial's
    /// elapsed time is measured against `max(now, maxDateSeen)`, so winding
    /// the system clock backward can't rewind the trial. See `TrialManager`.
    static let trialMaxDateSeen = KeychainStore(service: defaultService, account: "trial_max_date_seen")

    #if DEBUG
    /// DEBUG launch diagnostic: logs only the DISPOSITION (`found` / `absent`
    /// / `failure`) of the trial slot reads — never the values — so the
    /// reinstall-persistence test is observable without attaching a debugger.
    /// On a true same-build reinstall the start slot should read `found`; on
    /// a first-ever launch (or a different signing scope, per the header)
    /// it reads `absent`. Dispositions are `.public` — they carry no secret.
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
/// Used by `TrialManager` unit tests and by SwiftUI previews so neither
/// touches the developer's real login Keychain. Kept out of `#if DEBUG`
/// because `#Preview` blocks compile in every configuration; the type is a
/// tiny, unused-in-production reference holder.
///
/// A reference type (not a struct) so the same instance can be shared
/// between a `TrialManager` and the code seeding it, and so successive
/// reads/writes observe each other.
final class InMemoryKeychainSlot: KeychainSlot {
    private var value: String?
    /// When `true`, every `readResult()` reports `.failure` regardless of
    /// stored value — lets tests exercise the fail-open path deterministically.
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
