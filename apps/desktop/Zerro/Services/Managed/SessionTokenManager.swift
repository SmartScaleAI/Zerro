//
//  SessionTokenManager.swift
//  Zerro
//
//  Created by Colin Breeding on 6/2/26.
//
//  Overview
//  --------
//  Phase E — the Managed auth layer. Exchanges the stored LemonSqueezy license
//  key for a short-lived signed session token (billing-plan §6.3) and hands
//  that token to the proxy. The RAW LICENSE KEY rides ONLY to `/session`
//  (here); `/generate` and `/entitlement` only ever see the derived Bearer
//  token. That blast-radius limit is the whole point of the exchange — a leaked
//  request exposes a 15–60 min token, not the long-lived purchase key.
//
//  Token cache
//  -----------
//  The token + its expiry live IN MEMORY only (not the Keychain): it's short-
//  lived and trivially re-derivable from the key, so persisting it would add
//  exposure for no benefit. `validToken()` returns the cached token while it's
//  comfortably unexpired (minus a refresh leeway), else fetches a fresh one.
//  A token that expires mid-use is refreshed transparently by the proxy's
//  retry-once path (see `ManagedProxyClient`), never surfaced as an error.
//
//  Disambiguation
//  --------------
//  `establishSession()` is also how the entitlement layer tells a Managed
//  subscription license apart from a BYOK one: a Managed key resolves against
//  the `subscriptions` mirror and returns a token + tier; a BYOK key is absent
//  there and comes back `403 not_entitled`. So `.notEntitled` thrown here means
//  "this is not a Managed key" — the caller treats it as BYOK.
//
//  Testability mirrors `LicenseService`: the network goes through the
//  injectable `ManagedTransport`, the Keychain through the `KeychainSlot` seam,
//  and the clock is injectable for deterministic expiry tests. `nil` deps
//  resolve to the real slot/transport INSIDE the (MainActor) init body (a
//  default-argument expression touching `KeychainStore` statics would evaluate
//  nonisolated and trip MainActor isolation).
//

import Foundation
import os

// MARK: - ManagedSessionError

/// Typed failures of the session/entitlement exchange. Distinct from the
/// proxy's generation errors — these are about *identity + status*, not a
/// single generation.
enum ManagedSessionError: Error, Equatable {
    /// No license key on file to exchange (the Keychain slot is empty).
    case noLicenseKey
    /// The backend has no live subscription for this key (`403`): either a
    /// BYOK key (not in the mirror) or a cancelled/expired subscription. The
    /// entitlement layer reads this as "not a live Managed subscriber."
    case notEntitled
    /// Rate-limited (`429`) — back off and retry later.
    case rateLimited
    /// Couldn't reach the backend (offline/DNS/timeout). INCONCLUSIVE — the
    /// caller fails OPEN for an already-known user.
    case network(String)
    /// Backend 5xx or any other unexpected status.
    case server(status: Int)
    /// Response wasn't the JSON shape we expected.
    case malformedResponse
}

// MARK: - SessionTokenManager

@MainActor
final class SessionTokenManager: ProxyTokenProviding {

    /// How long before a token's real expiry we treat it as needing refresh,
    /// so an in-flight `/generate` never races the boundary. Named, not inline.
    static let refreshLeeway: TimeInterval = 60

    // MARK: - Cached token

    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    private var cached: CachedToken?

    // MARK: - Dependencies

    /// The license-key slot — the SAME slot Phase C's `LicenseService` writes
    /// on activation (`KeychainStore.byokLicenseKey`), shared because Managed
    /// and BYOK use one licensing path (§6.3).
    private let licenseKeySlot: KeychainSlot
    private let transport: ManagedTransport
    private let clock: () -> Date

    // MARK: - Init

    init(
        licenseKeySlot: KeychainSlot? = nil,
        transport: ManagedTransport? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.licenseKeySlot = licenseKeySlot ?? KeychainStore.byokLicenseKey
        self.transport = transport ?? URLSessionManagedTransport()
        self.clock = clock
    }

    // MARK: - Token access

    /// A valid session token: the cached one if it's still comfortably
    /// unexpired, otherwise a freshly minted one. Throws `ManagedSessionError`
    /// if a fresh token can't be obtained.
    func validToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(clock()) > Self.refreshLeeway {
            return cached.token
        }
        return try await refreshToken()
    }

    /// Forces a fresh `/session` exchange and returns the new token, discarding
    /// any cached one. Used by the proxy when a `/generate` call comes back
    /// `401` (token expired/rotated mid-use) so it can retry once.
    @discardableResult
    func refreshToken() async throws -> String {
        let session = try await exchange()
        return session.token
    }

    /// Performs the `/session` exchange, caches the token, and returns the full
    /// snapshot — the entitlement layer uses this both to confirm a Managed
    /// subscription (vs BYOK) and to seed the display snapshot at activation.
    @discardableResult
    func establishSession() async throws -> ManagedEntitlementSnapshot {
        let result = try await exchange()
        return result.snapshot
    }

    /// Reads the current entitlement (`/entitlement`) with a valid token, for
    /// display refresh. Refreshes the token once on a `401` before giving up.
    func fetchEntitlement() async throws -> ManagedEntitlementSnapshot {
        let token = try await validToken()
        do {
            return try await requestEntitlement(token: token)
        } catch ManagedSessionError.server(status: 401) {
            // Token rotated/expired between mint and use — refresh once, retry.
            let fresh = try await refreshToken()
            return try await requestEntitlement(token: fresh)
        }
    }

    /// Drops the cached token (on deactivation / definitive revocation). The
    /// next `validToken()` re-exchanges if a key is still on file.
    func invalidate() {
        cached = nil
    }

    // MARK: - Networking

    private struct ExchangeResult {
        let token: String
        let snapshot: ManagedEntitlementSnapshot
    }

    /// POST /session { license_key } → cache the token + return the snapshot.
    private func exchange() async throws -> ExchangeResult {
        guard case .found(let key) = licenseKeySlot.readResult(), !key.isEmpty else {
            throw ManagedSessionError.noLicenseKey
        }

        var request = URLRequest(url: ManagedBackend.sessionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The raw key goes ONLY here. Body is the single field the backend reads.
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["license_key": key])

        let (data, status): (Data, Int)
        do {
            (data, status) = try await transport.send(request)
        } catch {
            Log.billing.error("session exchange transport failure: \(error.localizedDescription, privacy: .private)")
            throw ManagedSessionError.network(error.localizedDescription)
        }

        switch status {
        case 200...299:
            break
        case 403:
            // Not in the subscriptions mirror or terminal status → not a live
            // Managed key. Caller (entitlement layer) reads this as BYOK.
            Log.billing.notice("session exchange → not_entitled (not a managed key, or terminal)")
            throw ManagedSessionError.notEntitled
        case 429:
            throw ManagedSessionError.rateLimited
        case 400:
            throw ManagedSessionError.malformedResponse
        default:
            Log.billing.error("session exchange unexpected status \(status, privacy: .public)")
            throw ManagedSessionError.server(status: status)
        }

        let decoded: SessionResponseDTO
        do {
            decoded = try JSONDecoder().decode(SessionResponseDTO.self, from: data)
        } catch {
            throw ManagedSessionError.malformedResponse
        }

        let expiresAt = ManagedBackend.parseISODate(decoded.expiresAt)
            ?? clock().addingTimeInterval(Self.refreshLeeway)
        cached = CachedToken(token: decoded.token, expiresAt: expiresAt)
        let snapshot = ManagedEntitlementSnapshot(dto: decoded.entitlement)
        Log.billing.notice("session token minted — tier=\(snapshot.tier.rawValue, privacy: .public) status=\(snapshot.status.rawValue, privacy: .public) credits=\(snapshot.creditsRemaining, privacy: .public)")
        return ExchangeResult(token: decoded.token, snapshot: snapshot)
    }

    /// GET /entitlement (Bearer) → snapshot. Surfaces `401` as
    /// `.server(status: 401)` so `fetchEntitlement` can do the refresh-once
    /// dance; other 4xx/5xx map to typed errors.
    private func requestEntitlement(token: String) async throws -> ManagedEntitlementSnapshot {
        var request = URLRequest(url: ManagedBackend.entitlementURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status): (Data, Int)
        do {
            (data, status) = try await transport.send(request)
        } catch {
            throw ManagedSessionError.network(error.localizedDescription)
        }

        switch status {
        case 200...299:
            do {
                let dto = try JSONDecoder().decode(EntitlementSnapshotDTO.self, from: data)
                return ManagedEntitlementSnapshot(dto: dto)
            } catch {
                throw ManagedSessionError.malformedResponse
            }
        case 401:
            throw ManagedSessionError.server(status: 401)
        case 403, 404:
            throw ManagedSessionError.notEntitled
        case 429:
            throw ManagedSessionError.rateLimited
        default:
            throw ManagedSessionError.server(status: status)
        }
    }

    // MARK: - Preview / test support

    /// An in-memory session manager whose transport is offline (any exchange
    /// fails open) and whose key slot is empty — so SwiftUI previews never make
    /// a real request. Non-`#if DEBUG` so `#Preview` blocks compile everywhere.
    static func inMemory() -> SessionTokenManager {
        SessionTokenManager(
            licenseKeySlot: InMemoryKeychainSlot(nil),
            transport: OfflineManagedTransport()
        )
    }
}

// MARK: - OfflineManagedTransport

/// A `ManagedTransport` that always reports the network unreachable. Backs the
/// in-memory previews so they never hit the real backend.
struct OfflineManagedTransport: ManagedTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        throw URLError(.notConnectedToInternet)
    }
}
