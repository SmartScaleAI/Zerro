//
//  SessionTokenManagerTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/2/26.
//
//  Phase E — unit coverage for the license→session-token exchange. Network is
//  stubbed via `StubManagedTransport`; the Keychain via `InMemoryKeychainSlot`.
//  Covers:
//    • A valid token is cached — a second `validToken()` doesn't re-exchange.
//    • An expired (within-leeway) token triggers a fresh exchange.
//    • The raw license key rides ONLY to `/session`; `/entitlement` sees a
//      Bearer token and no key.
//    • `establishSession` maps a 403 to `.notEntitled` (the BYOK signal).
//

import XCTest
@testable import Zerro

@MainActor
final class SessionTokenManagerTests: XCTestCase {

    private func makeManager(
        key: String? = "LICENSE-123",
        transport: StubManagedTransport,
        clock: @escaping () -> Date = { Date() }
    ) -> SessionTokenManager {
        SessionTokenManager(
            licenseKeySlot: InMemoryKeychainSlot(key),
            transport: transport,
            clock: clock
        )
    }

    // MARK: - Caching

    func testValidTokenCachesUnexpiredToken() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200)
        let manager = makeManager(transport: transport)

        let first = try await manager.validToken()
        let second = try await manager.validToken()

        XCTAssertEqual(first, "T1")
        XCTAssertEqual(second, "T1")
        // Second call served from cache — only ONE network exchange.
        XCTAssertEqual(transport.callCount, 1)
    }

    // MARK: - Refresh on expiry

    func testValidTokenRefreshesWhenWithinExpiryLeeway() async throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let transport = StubManagedTransport()
        // First token expires 120s out; second far in the future.
        let firstExpiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(120))
        transport.enqueue(ManagedFixtures.sessionJSON(token: "T1", expiresAt: firstExpiry), status: 200)
        transport.enqueue(ManagedFixtures.sessionJSON(token: "T2"), status: 200)
        let manager = makeManager(transport: transport, clock: { now })

        let first = try await manager.validToken()
        XCTAssertEqual(first, "T1")
        XCTAssertEqual(transport.callCount, 1)

        // Advance the clock so the first token is now within the refresh leeway.
        now = now.addingTimeInterval(100) // 20s of validity left < 60s leeway
        let second = try await manager.validToken()

        XCTAssertEqual(second, "T2")
        XCTAssertEqual(transport.callCount, 2)
    }

    // MARK: - Key only to /session

    func testLicenseKeyRidesOnlyToSession() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "T1"), status: 200) // establishSession
        transport.enqueue(ManagedFixtures.entitlementJSON(), status: 200)        // fetchEntitlement
        let manager = makeManager(key: "SECRET-KEY", transport: transport)

        _ = try await manager.establishSession()
        _ = try await manager.fetchEntitlement()

        XCTAssertEqual(transport.requests.count, 2)

        // /session request carries the key in its body and no Bearer header.
        let sessionReq = transport.requests[0]
        XCTAssertEqual(sessionReq.url, ManagedBackend.sessionURL)
        let sessionBody = String(data: sessionReq.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(sessionBody.contains("SECRET-KEY"), "license key must be sent to /session")
        XCTAssertNil(sessionReq.value(forHTTPHeaderField: "Authorization"))

        // /entitlement request carries a Bearer token and NEVER the key.
        let entReq = transport.requests[1]
        XCTAssertEqual(entReq.url, ManagedBackend.entitlementURL)
        XCTAssertEqual(entReq.value(forHTTPHeaderField: "Authorization"), "Bearer T1")
        let entBody = String(data: entReq.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(entBody.contains("SECRET-KEY"), "license key must NOT reach /entitlement")
    }

    // MARK: - Disambiguation

    func testEstablishSessionMapsForbiddenToNotEntitled() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(#"{"error":"not_entitled"}"#, status: 403)
        let manager = makeManager(transport: transport)

        do {
            _ = try await manager.establishSession()
            XCTFail("expected notEntitled")
        } catch ManagedSessionError.notEntitled {
            // Expected — this is how a BYOK key is told apart from a Managed one.
        }
    }

    func testNoKeyThrows() async throws {
        let transport = StubManagedTransport()
        let manager = makeManager(key: nil, transport: transport)
        do {
            _ = try await manager.validToken()
            XCTFail("expected noLicenseKey")
        } catch ManagedSessionError.noLicenseKey {
            // Expected.
        }
        XCTAssertEqual(transport.callCount, 0)
    }
}
