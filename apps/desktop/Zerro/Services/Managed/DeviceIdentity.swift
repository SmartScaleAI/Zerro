//
//  DeviceIdentity.swift
//  Zerro
//
//  Created by Colin Breeding on 6/18/26.
//
//  Overview
//  --------
//  Trial-abuse hardening: a stable, one-way hash of THIS Mac, used solely to cap
//  the free trial at one grant per physical machine (closing the "different
//  emails, same computer" farming hole). Zerro is a notarized, non-sandboxed
//  macOS app, so it can read the per-machine IOPlatformUUID with NO entitlement
//  and NO TCC permission prompt — a hard, near-unforgeable device key a browser
//  can never get. (The read needs no Screen-Recording grant, so it works during
//  onboarding BEFORE that step.)
//
//  Rules
//  -----
//  • Hash CLIENT-SIDE, never send the raw UUID. The backend only ever sees
//    `device_id_hash` (SHA-256 hex); the DB never holds a raw hardware id.
//  • One-way only. Used solely for the one-grant-per-device cap — never analytics.
//  • Fallback when unreadable: `hashedDeviceID()` returns nil only when the
//    hardware UUID can't be read (extremely rare on real Macs). The caller then
//    OMITS the field and the backend degrades to the email-only cap for that
//    request. We do NOT fail the trial over a missing device id.
//

import Foundation
import IOKit
import CryptoKit
import os

enum DeviceIdentity {

    /// Compile-time pepper so a leaked DB hash can't be matched against a known
    /// UUID by anyone who doesn't have the binary. Not a secret store — it just
    /// raises the bar. MUST stay constant forever: changing it re-keys every
    /// device and would let already-trialed Macs farm a fresh grant.
    private static let salt = "9bca85f8af1226df8d801709d66c69cb2b68b9637d2fb6299f4b7ed33a8211d3"

    /// Memoized result — the hardware UUID never changes within a process, so we
    /// read IOKit once. `Optional` wrapped once-set; the inner value may be nil
    /// (unreadable UUID), which we also cache so we don't re-probe every call.
    private static let cachedHash: String? = computeHashedDeviceID()

    /// SHA-256 hex of (platformUUID + salt), or nil when the hardware UUID is
    /// unreadable. Never returns the raw UUID.
    static func hashedDeviceID() -> String? { cachedHash }

    // MARK: - Internals

    private static func computeHashedDeviceID() -> String? {
        guard let uuid = platformUUID() else {
            Log.billing.error("DeviceIdentity: platform UUID unreadable — trial degrades to email-only cap")
            return nil
        }
        let digest = SHA256.hash(data: Data((uuid + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The IOKit platform UUID (`kIOPlatformUUIDKey` of `IOPlatformExpertDevice`).
    /// Stable per machine, survives app delete + reinstall (it's hardware, not
    /// app state), readable with no entitlement or permission.
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,                       // macOS 12+; deployment target is 15+
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let cf = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let uuid = cf.takeRetainedValue() as? String
        guard let uuid, !uuid.isEmpty else { return nil }
        return uuid
    }
}
