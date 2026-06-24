//
//  LicenseServiceTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase C — unit coverage for the BYOK license layer. The network is stubbed
//  through `LicenseTransport` (canned JSON + status codes, no real requests)
//  and the Keychain through `InMemoryKeychainSlot` (Phase B's fake), so these
//  are deterministic value-in/value-out assertions. Covers:
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
        clock: @escaping () -> Date = { Date() },
        confirmReplace: @escaping () async -> Bool = { true }
    ) -> LicenseService {
        LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            licenseCreatedAtSlot: createdAtSlot,
            transport: transport,
            clock: clock,
            instanceNameProvider: { "TestMac-DEADBEEF" },
            confirmReplace: confirmReplace
        )
    }

    /// Records whether the "replace your current license?" confirmation was
    /// asked, and answers with a fixed verdict — so the E-01 replace-gate tests
    /// assert both the answer's effect AND that the gate is consulted only when
    /// it should be (a different key on file), never on the frictionless paths.
    private final class ConfirmReplaceSpy {
        private(set) var asked = 0
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
        func confirm() -> Bool { asked += 1; return answer }
    }

    /// Hermetic `EntitlementStore` dependencies. The store's defaults reach
    /// for the REAL machine otherwise, which lets developer state leak into
    /// these tests (observed: a live local-backend dev subscription flipped
    /// both EntitlementStore tests here):
    ///   • `defaults: .standard` carries the app's cached Managed snapshot;
    ///   • the real product-kind Keychain slot carries `kind=managed`;
    ///   • a real-transport `SessionTokenManager` activates the DEBUG
    ///     `ZERRO_DEV_LICENSE_KEY` scheme fallback and probes the local
    ///     backend during `activate()` (the E9 gate only protects stubbed
    ///     transports).
    private func makeHermeticStore(
        licenseService: LicenseService,
        keySlot: InMemoryKeychainSlot,
        sessionTransport: StubManagedTransport = StubManagedTransport()
    ) -> EntitlementStore {
        EntitlementStore(
            licenseService: licenseService,
            sessionTokens: SessionTokenManager(licenseKeySlot: keySlot, transport: sessionTransport),
            productKindSlot: InMemoryKeychainSlot(),
            defaults: UserDefaults(suiteName: "LicenseServiceTests-\(UUID().uuidString)")!
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

        // The activation probe asks /session whether the key is a Managed
        // subscription; 403 (not in the mirror) is the BYOK classification.
        let sessionTransport = StubManagedTransport()
        sessionTransport.enqueue(#"{"error":"not_entitled"}"#, status: 403)

        // Start in trial; activation should flip the store to .byok.
        let store = makeHermeticStore(
            licenseService: service,
            keySlot: keySlot,
            sessionTransport: sessionTransport
        )
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

    // MARK: - E-01: replace-a-present-license confirmation gate

    /// Covers BOTH activation entry points (the checkout-return deep link and the
    /// manual-paste field route through here): a DIFFERENT key on file requires
    /// an explicit confirmation before overwriting, and DECLINING keeps the old
    /// license fully intact — no network call, no Keychain write.
    func testReplaceDifferentKeyDeclinedKeepsOldLicenseUntouched() async {
        let transport = StubLicenseTransport()
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NEW" } }"#), 200)]
        let keySlot = InMemoryKeychainSlot("OLD-KEY")
        let instanceSlot = InMemoryKeychainSlot("old-instance")
        let confirm = ConfirmReplaceSpy(answer: false)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            confirmReplace: { confirm.confirm() }
        )

        do {
            _ = try await service.activate(licenseKey: "NEW-KEY")
            XCTFail("expected .replaceCancelled when the user declines the replace prompt")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .replaceCancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(confirm.asked, 1, "the replace confirmation must be asked for a different key")
        XCTAssertEqual(transport.callCount, 0, "a declined replace must NOT contact LemonSqueezy")
        // The old license is fully intact.
        XCTAssertEqual(keySlot.readResult(), .found("OLD-KEY"))
        XCTAssertEqual(instanceSlot.readResult(), .found("old-instance"))
    }

    /// Confirming the replace proceeds normally: the new key + instance are
    /// written, overwriting the old binding.
    func testReplaceDifferentKeyConfirmedOverwrites() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NEW" } }"#), 200)]
        let keySlot = InMemoryKeychainSlot("OLD-KEY")
        let instanceSlot = InMemoryKeychainSlot("old-instance")
        let confirm = ConfirmReplaceSpy(answer: true)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            confirmReplace: { confirm.confirm() }
        )

        let result = try await service.activate(licenseKey: "NEW-KEY")

        XCTAssertEqual(confirm.asked, 1)
        XCTAssertEqual(result.instanceID, "inst_NEW")
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(keySlot.readResult(), .found("NEW-KEY"))
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_NEW"))
    }

    /// Re-activating the SAME key (an idempotent re-activation, e.g. a repeat
    /// checkout-return click) stays frictionless — the replace prompt is NEVER
    /// shown, even though a key is already on file. Trimmed comparison, since the
    /// on-file key was stored trimmed.
    func testReactivatingSameKeyNeverPromptsToReplace() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_SAME" } }"#), 200)]
        let keySlot = InMemoryKeychainSlot("SAME-KEY")
        let instanceSlot = InMemoryKeychainSlot("old-instance")
        // answer:false would THROW if the gate were (wrongly) consulted.
        let confirm = ConfirmReplaceSpy(answer: false)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            confirmReplace: { confirm.confirm() }
        )

        _ = try await service.activate(licenseKey: "  SAME-KEY  ")

        XCTAssertEqual(confirm.asked, 0, "the same key must never trigger the replace prompt")
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(keySlot.readResult(), .found("SAME-KEY"))
    }

    /// A first activation (no license on file) is always frictionless — the
    /// replace prompt is never shown.
    func testFirstActivationWithNoCurrentLicenseNeverPrompts() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_FRESH" } }"#), 200)]
        let keySlot = InMemoryKeychainSlot()
        let confirm = ConfirmReplaceSpy(answer: false)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            confirmReplace: { confirm.confirm() }
        )

        _ = try await service.activate(licenseKey: "FRESH-KEY")

        XCTAssertEqual(confirm.asked, 0)
        XCTAssertEqual(keySlot.readResult(), .found("FRESH-KEY"))
    }

    /// The manual-paste / Settings path goes through `EntitlementStore.activate`,
    /// which must propagate `.replaceCancelled` and leave the entitlement
    /// unchanged when the user declines (proves the gate covers that path too).
    func testStoreActivateDifferentKeyDeclinedLeavesEntitlementIntact() async {
        let transport = StubLicenseTransport()
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NEW" } }"#), 200)]
        let keySlot = InMemoryKeychainSlot("OLD-KEY")
        let confirm = ConfirmReplaceSpy(answer: false)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("old-instance"),
            confirmReplace: { confirm.confirm() }
        )
        // The present OLD-KEY license + (no product kind) computes to .byok.
        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok, "precondition: already paid on the old key")

        do {
            try await store.activate(licenseKey: "NEW-KEY")
            XCTFail("expected .replaceCancelled to propagate")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .replaceCancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(confirm.asked, 1)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(keySlot.readResult(), .found("OLD-KEY"))
        XCTAssertEqual(store.state, .byok, "the entitlement must be unchanged on a declined replace")
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
        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
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

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
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

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
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
        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
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

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
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
