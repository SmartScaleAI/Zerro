//
//  LicenseServiceTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase C — unit coverage for the BYOK license layer. The network is stubbed
//  through `LicenseTransport` (canned JSON + status codes, no real requests)
//  and the Keychain through `InMemoryKeychainSlot` (Phase B's fake), so these
//  are deterministic value-in/value-out assertions in the spirit of
//  `ModeSwitchDetectorTests`. Covers:
//    • Activation success → Keychain written, instance ID saved, state .byok.
//    • Activation at-limit → .atActivationLimit, Keychain untouched.
//    • Validate valid:false (disabled) → license cleared → falls back to trial.
//    • Validate network failure → fail-open: license retained, stays .byok.
//    • Throttle → validate not called when last-validated is within the window.
//

import XCTest
@testable import Zerro

@MainActor
final class LicenseServiceTests: XCTestCase {

    // MARK: - Stub transport

    /// Records every request and returns queued `(Data, statusCode)` responses
    /// in order, or throws `error` if set (the network-failure path).
    final class StubLicenseTransport: LicenseTransport {
        var responses: [(Data, Int)] = []
        var error: Error?
        private(set) var requests: [(path: String, parameters: [String: String])] = []

        var callCount: Int { requests.count }

        func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
            requests.append((path, parameters))
            if let error { throw error }
            guard !responses.isEmpty else { return (Data("{}".utf8), 200) }
            return responses.removeFirst()
        }
    }

    // MARK: - Fixtures

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// Builds a `LicenseService` over fresh in-memory slots + the given
    /// transport, returning both so tests can inspect the Keychain slots.
    private func makeService(
        transport: LicenseTransport,
        keySlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        instanceSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        lastValidatedSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        createdAtSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        clock: @escaping () -> Date = { Date() }
    ) -> LicenseService {
        LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            licenseCreatedAtSlot: createdAtSlot,
            transport: transport,
            clock: clock,
            instanceNameProvider: { "TestMac-DEADBEEF" }
        )
    }

    // MARK: - Activation success

    func testActivationSuccessWritesKeychainAndSavesInstanceID() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        {
          "activated": true,
          "error": null,
          "license_key": { "id": 1, "status": "active", "activation_limit": 1, "activation_usage": 1 },
          "instance": { "id": "inst_ABC123", "name": "TestMac-DEADBEEF" },
          "meta": { "store_id": 42, "product_id": 7, "variant_id": 9, "customer_email": "buyer@example.com" }
        }
        """), 200)]

        let keySlot = InMemoryKeychainSlot()
        let instanceSlot = InMemoryKeychainSlot()
        let lastValidatedSlot = InMemoryKeychainSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot
        )

        let result = try await service.activate(licenseKey: "  KEY-123  ")

        XCTAssertEqual(result.instanceID, "inst_ABC123")
        XCTAssertEqual(result.status, .active)
        XCTAssertEqual(result.storeID, 42)
        XCTAssertEqual(result.customerEmail, "buyer@example.com")

        // Keychain written (trimmed key), instance saved, throttle stamped.
        XCTAssertEqual(keySlot.readResult(), .found("KEY-123"))
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_ABC123"))
        if case .found = lastValidatedSlot.readResult() {} else {
            XCTFail("expected last-validated stamp to be written on activation")
        }

        // The request carried the key + a non-empty instance_name.
        XCTAssertEqual(transport.requests.first?.path, LicenseService.activatePath)
        XCTAssertEqual(transport.requests.first?.parameters["license_key"], "KEY-123")
        XCTAssertEqual(transport.requests.first?.parameters["instance_name"], "TestMac-DEADBEEF")
    }

    func testActivationSuccessMakesEntitlementByok() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_X" } }
        """), 200)]

        let keySlot = InMemoryKeychainSlot()
        let instanceSlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot, instanceSlot: instanceSlot)

        // Start in trial; activation should flip the store to .byok.
        let store = EntitlementStore(licenseService: service)
        if case .trial = store.state {} else {
            XCTFail("expected initial .trial, got \(store.state)")
        }

        try await store.activate(licenseKey: "KEY-XYZ")
        XCTAssertEqual(store.state, .byok)
    }

    // MARK: - Activation at-limit

    func testActivationAtLimitThrowsAndLeavesKeychainUntouched() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        {
          "activated": false,
          "error": "This license key has reached the activation limit.",
          "license_key": { "status": "active", "activation_limit": 1, "activation_usage": 1 },
          "instance": null
        }
        """), 400)]

        let keySlot = InMemoryKeychainSlot()
        let instanceSlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot, instanceSlot: instanceSlot)

        do {
            _ = try await service.activate(licenseKey: "KEY-LIMIT")
            XCTFail("expected activation to throw .atActivationLimit")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .atActivationLimit)
        }

        // A failed activation must not write the Keychain.
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
    }

    func testActivationDisabledKeyThrowsKeyDisabled() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "activated": false, "error": "license key has been disabled", "license_key": { "status": "disabled" } }
        """), 400)]
        let service = makeService(transport: transport)

        do {
            _ = try await service.activate(licenseKey: "KEY-DISABLED")
            XCTFail("expected .keyDisabled")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .keyDisabled)
        }
    }

    // MARK: - Validate: definitive negative clears + drops to trial

    func testValidateDisabledClearsLicenseAndDropsToTrial() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": false, "error": "license key has been disabled", "license_key": { "status": "disabled" } }
        """), 400)]

        // Pre-seed a present, activated license whose throttle stamp is old.
        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-REFUNDED")
        let instanceSlot = InMemoryKeychainSlot("inst_REF")
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot
        )

        // A present license → store starts .byok.
        let store = EntitlementStore(licenseService: service)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        // Refund/revoke → license cleared, dropped back to the trial clock.
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        XCTAssertEqual(transport.callCount, 1, "validate should have been called (throttle elapsed)")
        if case .trial = store.state {} else {
            XCTFail("expected drop to .trial after revocation, got \(store.state)")
        }
    }

    // MARK: - Validate: network failure fails open

    func testValidateNetworkFailureKeepsLicenseAndStaysByok() async throws {
        let transport = StubLicenseTransport()
        transport.error = URLError(.notConnectedToInternet)

        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-GOOD")
        let instanceSlot = InMemoryKeychainSlot("inst_GOOD")
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot
        )

        let store = EntitlementStore(licenseService: service)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        // Inconclusive (network) → FAIL OPEN: license retained, stays .byok.
        XCTAssertEqual(keySlot.readResult(), .found("KEY-GOOD"))
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_GOOD"))
        XCTAssertEqual(store.state, .byok)
        XCTAssertEqual(transport.callCount, 1, "validate was attempted before failing open")
    }

    // MARK: - Throttle

    func testRevalidateThrottledWhenWithinWindow() async throws {
        let transport = StubLicenseTransport()
        // No responses queued — if validate fires, it'd consume the empty
        // queue; we assert it does NOT fire at all via callCount.

        let now = Date()
        let recentStamp = String(Int(now.addingTimeInterval(-60).timeIntervalSince1970)) // 1 min ago
        let keySlot = InMemoryKeychainSlot("KEY-RECENT")
        let instanceSlot = InMemoryKeychainSlot("inst_RECENT")
        let lastValidatedSlot = InMemoryKeychainSlot(recentStamp)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            clock: { now }
        )

        let store = EntitlementStore(licenseService: service)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        // Within the throttle window → no network call, still .byok.
        XCTAssertEqual(transport.callCount, 0, "validate must not be called within the throttle window")
        XCTAssertEqual(store.state, .byok)
    }

    func testValidValidationRefreshesThrottleStamp() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": true, "license_key": { "status": "active" } }
        """), 200)]

        let now = Date()
        let oldInstant = now.addingTimeInterval(-LicenseService.revalidationInterval - 60)
        let oldStamp = String(Int(oldInstant.timeIntervalSince1970))
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let service = makeService(
            transport: transport,
            keySlot: InMemoryKeychainSlot("KEY-OK"),
            instanceSlot: InMemoryKeychainSlot("inst_OK"),
            lastValidatedSlot: lastValidatedSlot,
            clock: { now }
        )

        XCTAssertTrue(service.shouldRevalidate(), "stale stamp should permit revalidation")
        let result = try await service.validate()
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.status, .active)
        // Stamp refreshed to "now" → throttle now suppresses the next check.
        XCTAssertFalse(service.shouldRevalidate(), "valid validation should refresh the throttle stamp")
    }

    // MARK: - currentLicenseState

    func testCurrentLicenseStatePresentAbsentIndeterminate() {
        // Present: both slots found.
        let present = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I")
        )
        XCTAssertEqual(present.currentLicenseState().presence, .present)
        XCTAssertTrue(present.currentLicenseState().grantsBYOK)

        // Absent: nothing stored.
        let absent = makeService(transport: StubLicenseTransport())
        XCTAssertEqual(absent.currentLicenseState().presence, .absent)
        XCTAssertFalse(absent.currentLicenseState().grantsBYOK)

        // Indeterminate: a genuine read failure on the key slot → fail-open.
        let failingKey = InMemoryKeychainSlot("K")
        failingKey.simulateReadFailure = true
        let indeterminate = makeService(
            transport: StubLicenseTransport(),
            keySlot: failingKey,
            instanceSlot: InMemoryKeychainSlot("I")
        )
        XCTAssertEqual(indeterminate.currentLicenseState().presence, .indeterminate)
        XCTAssertTrue(indeterminate.currentLicenseState().grantsBYOK, "a read failure must fail open to .byok")
    }

    // MARK: - Update window (E7): created_at decode + persist

    /// 2026-01-15T12:00:00Z, the epoch the fixtures below encode.
    private static let createdAtEpoch = 1_768_478_400

    func testActivationPersistsCreatedAtAndComputesWindowEnd() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        {
          "activated": true,
          "license_key": { "id": 1, "status": "active", "created_at": "2026-01-15T12:00:00.000000Z" },
          "instance": { "id": "inst_E7" }
        }
        """), 200)]

        let createdAtSlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, createdAtSlot: createdAtSlot)
        _ = try await service.activate(licenseKey: "KEY-E7")

        XCTAssertEqual(createdAtSlot.readResult(), .found(String(Self.createdAtEpoch)))
        let createdAt = Date(timeIntervalSince1970: TimeInterval(Self.createdAtEpoch))
        XCTAssertEqual(service.updateWindowEnd(), LicenseService.updateWindowEnd(createdAt: createdAt))
    }

    func testValidateBackfillsCreatedAtForPreE7License() async throws {
        // A license activated before E7 has no persisted window start; the
        // next good validation must backfill it without re-activating.
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": true, "license_key": { "status": "active", "created_at": "2026-01-15T12:00:00.000000Z" } }
        """), 200)]

        let createdAtSlot = InMemoryKeychainSlot()
        let service = makeService(
            transport: transport,
            keySlot: InMemoryKeychainSlot("KEY-PRE-E7"),
            instanceSlot: InMemoryKeychainSlot("inst_PRE"),
            createdAtSlot: createdAtSlot
        )
        XCTAssertNil(service.updateWindowEnd(), "pre-E7 license starts with no window")

        let result = try await service.validate()
        XCTAssertTrue(result.valid)
        XCTAssertEqual(createdAtSlot.readResult(), .found(String(Self.createdAtEpoch)))
        XCTAssertNotNil(service.updateWindowEnd())
    }

    func testActivationWithNewKeyRestartsWindow() async throws {
        // Renewal = paste-new-key (F.0): activating a fresh key overwrites
        // the old window start with the new license's created_at.
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        {
          "activated": true,
          "license_key": { "status": "active", "created_at": "2027-03-01T00:00:00.000000Z" },
          "instance": { "id": "inst_RENEWED" }
        }
        """), 200)]

        let oldEpoch = String(Self.createdAtEpoch)
        let createdAtSlot = InMemoryKeychainSlot(oldEpoch)
        let service = makeService(transport: transport, createdAtSlot: createdAtSlot)
        _ = try await service.activate(licenseKey: "KEY-RENEWAL")

        if case .found(let raw) = createdAtSlot.readResult() {
            XCTAssertNotEqual(raw, oldEpoch, "a renewal key must restart the window")
        } else {
            XCTFail("expected a persisted window start after renewal activation")
        }
    }

    func testMissingCreatedAtKeepsExistingWindowAndFailsOpenWhenAbsent() async throws {
        // A response WITHOUT created_at (older shape) must not erase a
        // previously-persisted window start…
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": true, "license_key": { "status": "active" } }
        """), 200)]
        let seeded = InMemoryKeychainSlot(String(Self.createdAtEpoch))
        let service = makeService(
            transport: transport,
            keySlot: InMemoryKeychainSlot("KEY-OLD-SHAPE"),
            instanceSlot: InMemoryKeychainSlot("inst_OLD"),
            createdAtSlot: seeded
        )
        _ = try await service.validate()
        XCTAssertEqual(seeded.readResult(), .found(String(Self.createdAtEpoch)))

        // …and with nothing persisted at all, the window reads nil (callers
        // fail OPEN — updates offered normally).
        let bare = makeService(transport: StubLicenseTransport())
        XCTAssertNil(bare.updateWindowEnd())
    }

    func testParseCreatedAtAcceptsKnownFormatsAndRejectsGarbage() {
        let expected = Date(timeIntervalSince1970: TimeInterval(Self.createdAtEpoch))
        XCTAssertEqual(LicenseService.parseCreatedAt("2026-01-15T12:00:00.000000Z"), expected)
        XCTAssertEqual(LicenseService.parseCreatedAt("2026-01-15T12:00:00Z"), expected)
        XCTAssertEqual(LicenseService.parseCreatedAt("2026-01-15 12:00:00"), expected)
        XCTAssertNil(LicenseService.parseCreatedAt(nil))
        XCTAssertNil(LicenseService.parseCreatedAt(""))
        XCTAssertNil(LicenseService.parseCreatedAt("not-a-date"))
    }

    func testUpdateWindowEndIsOneCalendarYear() {
        let createdAt = Date(timeIntervalSince1970: TimeInterval(Self.createdAtEpoch)) // 2026-01-15
        let end = LicenseService.updateWindowEnd(createdAt: createdAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.year], from: createdAt, to: end).year, 1)
    }

    func testClearLicenseRemovesCreatedAt() async throws {
        let createdAtSlot = InMemoryKeychainSlot(String(Self.createdAtEpoch))
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            createdAtSlot: createdAtSlot
        )
        service.clearLicense()
        XCTAssertEqual(createdAtSlot.readResult(), .absent)
    }

    // MARK: - Update window (E7): the F.2 trap — validity/generation untouched

    func testOutOfWindowLicenseStillValidatesAndGenerates() async throws {
        // A license purchased >1 year ago is OUT of its update window — and
        // that must change NOTHING about validity or generation: validate
        // still completes `valid:true` (no revocation), the entitlement stays
        // .byok, and the generation gate stays open. Only the updater reads
        // the window.
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": true, "license_key": { "status": "active", "created_at": "2024-01-15T12:00:00.000000Z" } }
        """), 200)]

        let twoYearsAgo = Date(timeIntervalSince1970: 1_705_320_000) // 2024-01-15
        let createdAtSlot = InMemoryKeychainSlot(String(Int(twoYearsAgo.timeIntervalSince1970)))
        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-LAPSED-WINDOW")
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("inst_LAPSED"),
            lastValidatedSlot: InMemoryKeychainSlot(oldStamp),
            createdAtSlot: createdAtSlot
        )

        // The window has lapsed…
        let windowEnd = try XCTUnwrap(service.updateWindowEnd())
        XCTAssertLessThan(windowEnd, Date(), "fixture sanity: window must be in the past")

        // …yet validation is a plain non-revoking success…
        let store = EntitlementStore(licenseService: service)
        XCTAssertEqual(store.state, .byok)
        await store.revalidateLicenseIfNeeded()
        XCTAssertEqual(keySlot.readResult(), .found("KEY-LAPSED-WINDOW"), "out-of-window must never clear the license")
        XCTAssertEqual(store.state, .byok)

        // …and the generation gate is untouched.
        XCTAssertTrue(store.canGenerate)
    }

    // MARK: - Deactivate

    func testDeactivateThisDeviceFreesSlotAndDropsToTrial() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "deactivated": true, "error": null }
        """), 200)]

        let keySlot = InMemoryKeychainSlot("KEY-DEV")
        let instanceSlot = InMemoryKeychainSlot("inst_DEV")
        let lastValidatedSlot = InMemoryKeychainSlot(String(Int(Date().timeIntervalSince1970)))
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot
        )

        let store = EntitlementStore(licenseService: service)
        XCTAssertEqual(store.state, .byok)

        try await store.deactivateThisDevice()

        XCTAssertEqual(transport.requests.first?.path, LicenseService.deactivatePath)
        XCTAssertEqual(transport.requests.first?.parameters["instance_id"], "inst_DEV")
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        if case .trial = store.state {} else {
            XCTFail("expected drop to .trial after deactivation, got \(store.state)")
        }
    }
}
