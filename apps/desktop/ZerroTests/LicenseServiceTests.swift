//
//  LicenseServiceTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/1/26.
//
//  Unit coverage for the license layer. The network is stubbed through
//  `LicenseTransport` (canned JSON + status codes, no real requests), the
//  Keychain through `InMemoryKeychainSlot`, and the edition policy is
//  injected — so these are deterministic value-in/value-out assertions.
//  Covers:
//    • Activation success → Keychain + edition metadata written, state .byok.
//    • Product-identity gate → wrong/missing `meta.product_id` fails closed
//      with `.wrongProduct`, persists nothing, and best-effort frees the slot.
//    • Activation at-limit → .atActivationLimit, Keychain untouched.
//    • Validate valid:false (disabled) → license cleared → falls back to trial.
//    • Validate wrong/missing product (whatever `valid` says) → edition
//      metadata cleared, key kept, stamp untouched, entitlement dropped.
//    • Validate network failure → fail-open: license retained, stays .byok —
//      only for a complete, readable, compatible cached record.
//    • Throttle → validate not called when last-validated is within the window.
//    • `currentLicenseState` verdicts: exactly present+compatible grants;
//      read failures, missing/malformed metadata, wrong product, and wrong
//      major all FAIL CLOSED.
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

    /// The edition policy the tests pin: major 1, product 7 approved. Product
    /// 7 is deliberately NOT a real Lemon Squeezy ID — the policy is injected,
    /// so nothing here depends on the shipping product IDs.
    static let testPolicy = LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7])

    /// Builds a `LicenseService` over fresh in-memory slots + the given
    /// transport, returning both so tests can inspect the Keychain slots.
    private func makeService(
        transport: LicenseTransport,
        keySlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        instanceSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        lastValidatedSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        productSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        majorSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        policy: LicenseEditionPolicy = LicenseServiceTests.testPolicy,
        clock: @escaping () -> Date = { Date() },
        confirmReplace: @escaping () async -> Bool = { true }
    ) -> LicenseService {
        LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            licensedProductIDSlot: productSlot,
            licensedMajorSlot: majorSlot,
            policy: policy,
            transport: transport,
            clock: clock,
            instanceNameProvider: { "TestMac-DEADBEEF" },
            confirmReplace: confirmReplace
        )
    }

    /// In-memory slots seeded as a CONFIRMED compatible edition for the test
    /// policy (product 7, major 1).
    private func compatibleProductSlot() -> InMemoryKeychainSlot { InMemoryKeychainSlot("7") }
    private func compatibleMajorSlot() -> InMemoryKeychainSlot { InMemoryKeychainSlot("1") }

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

    /// Hermetic `EntitlementStore`: official mode over the injected license
    /// service and no trial clock, so the unlicensed branch lands on the
    /// gated `.localTrialExpired` (never real Keychain / defaults reads).
    private func makeHermeticStore(
        licenseService: LicenseService,
        keySlot: InMemoryKeychainSlot
    ) -> EntitlementStore {
        EntitlementStore(enforcementMode: .official, licenseService: licenseService)
    }

    // MARK: - Activation success

    func testActivationSuccessWritesKeychainAndEditionMetadata() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        {
          "activated": true,
          "error": null,
          "license_key": { "id": 1, "status": "active", "activation_limit": 2, "activation_usage": 1 },
          "instance": { "id": "inst_ABC123", "name": "TestMac-DEADBEEF" },
          "meta": { "store_id": 42, "product_id": 7, "variant_id": 9, "customer_email": "buyer@example.com" }
        }
        """), 200)]

        let keySlot = InMemoryKeychainSlot()
        let instanceSlot = InMemoryKeychainSlot()
        let lastValidatedSlot = InMemoryKeychainSlot()
        let productSlot = InMemoryKeychainSlot()
        let majorSlot = InMemoryKeychainSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        let result = try await service.activate(licenseKey: "  KEY-123  ")

        XCTAssertEqual(result.instanceID, "inst_ABC123")
        XCTAssertEqual(result.status, .active)
        XCTAssertEqual(result.storeID, 42)
        XCTAssertEqual(result.productID, 7)
        XCTAssertEqual(result.customerEmail, "buyer@example.com")

        // Keychain written (trimmed key), instance saved, edition confirmed,
        // throttle stamped — all together.
        XCTAssertEqual(keySlot.readResult(), .found("KEY-123"))
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_ABC123"))
        XCTAssertEqual(productSlot.readResult(), .found("7"))
        XCTAssertEqual(majorSlot.readResult(), .found("1"))
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
        { "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_X" }, "meta": { "product_id": 7 } }
        """), 200)]

        let keySlot = InMemoryKeychainSlot()
        let instanceSlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot, instanceSlot: instanceSlot)

        // Start in trial; activation should flip the store to .byok.
        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .localTrialExpired, "precondition: unlicensed, no clock → gated")

        try await store.activate(licenseKey: "KEY-XYZ")
        XCTAssertEqual(store.state, .byok)
    }

    // MARK: - Product-identity gate (activation)

    func testActivationWrongProductThrowsPersistsNothingAndFreesSlot() async {
        let transport = StubLicenseTransport()
        transport.responses = [
            // The key ACTIVATES fine — but for another product (id 999).
            (data("""
            { "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_WRONG" }, "meta": { "product_id": 999 } }
            """), 200),
            // The best-effort cleanup deactivation succeeds.
            (data(#"{ "deactivated": true }"#), 200),
        ]

        let keySlot = InMemoryKeychainSlot()
        let instanceSlot = InMemoryKeychainSlot()
        let productSlot = InMemoryKeychainSlot()
        let majorSlot = InMemoryKeychainSlot()
        let lastValidatedSlot = InMemoryKeychainSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        do {
            _ = try await service.activate(licenseKey: "KEY-OTHER-PRODUCT")
            XCTFail("expected .wrongProduct")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .wrongProduct)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // Nothing persisted — the wrong-product key never becomes a license.
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        XCTAssertEqual(productSlot.readResult(), .absent)
        XCTAssertEqual(majorSlot.readResult(), .absent)
        XCTAssertEqual(lastValidatedSlot.readResult(), .absent)

        // The just-created instance was best-effort freed WITH the incoming
        // key (nothing is in the Keychain to read at that point).
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].path, LicenseService.deactivatePath)
        XCTAssertEqual(transport.requests[1].parameters["license_key"], "KEY-OTHER-PRODUCT")
        XCTAssertEqual(transport.requests[1].parameters["instance_id"], "inst_WRONG")
    }

    func testActivationMissingProductIDFailsClosed() async {
        // No `meta` at all → the product can't be verified → fail closed.
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NOMETA" } }
        """), 200)]

        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)

        do {
            _ = try await service.activate(licenseKey: "KEY-NO-META")
            XCTFail("expected .wrongProduct for a missing product id")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .wrongProduct)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(keySlot.readResult(), .absent)
    }

    func testWrongProductCleanupFailureStillThrowsWrongProduct() async {
        // The cleanup deactivation failing (network) must not mask the
        // wrong-product verdict — it's best-effort only.
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_W2" }, "meta": { "product_id": 999 } }
        """), 200)]
        // Second request (deactivate) hits the empty queue → `{}` → refused.

        let service = makeService(transport: transport)
        do {
            _ = try await service.activate(licenseKey: "KEY-W2")
            XCTFail("expected .wrongProduct")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .wrongProduct)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWrongProductActivationLeavesExistingLicenseUntouched() async {
        // A good license is on file; activating a wrong-product key (user
        // confirms the replace prompt) must fail closed WITHOUT clobbering it.
        let transport = StubLicenseTransport()
        transport.responses = [
            (data("""
            { "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_W3" }, "meta": { "product_id": 999 } }
            """), 200),
            (data(#"{ "deactivated": true }"#), 200),
        ]
        let keySlot = InMemoryKeychainSlot("GOOD-KEY")
        let instanceSlot = InMemoryKeychainSlot("inst_GOOD")
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            productSlot: productSlot,
            majorSlot: majorSlot,
            confirmReplace: { true }
        )

        do {
            _ = try await service.activate(licenseKey: "KEY-W3")
            XCTFail("expected .wrongProduct")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .wrongProduct)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(keySlot.readResult(), .found("GOOD-KEY"))
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_GOOD"))
        XCTAssertEqual(productSlot.readResult(), .found("7"))
        XCTAssertEqual(majorSlot.readResult(), .found("1"))
    }

    // MARK: - Activation at-limit

    func testActivationAtLimitThrowsAndLeavesKeychainUntouched() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        {
          "activated": false,
          "error": "This license key has reached the activation limit.",
          "license_key": { "status": "active", "activation_limit": 2, "activation_usage": 2 },
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
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NEW" }, "meta": { "product_id": 7 } }"#), 200)]
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
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NEW" }, "meta": { "product_id": 7 } }"#), 200)]
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
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_SAME" }, "meta": { "product_id": 7 } }"#), 200)]
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
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_FRESH" }, "meta": { "product_id": 7 } }"#), 200)]
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
        transport.responses = [(data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_NEW" }, "meta": { "product_id": 7 } }"#), 200)]
        let keySlot = InMemoryKeychainSlot("OLD-KEY")
        let confirm = ConfirmReplaceSpy(answer: false)
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("old-instance"),
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot(),
            confirmReplace: { confirm.confirm() }
        )
        // The present, edition-confirmed OLD-KEY license computes to .byok.
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

        // Pre-seed a present, edition-confirmed license whose throttle stamp
        // is old.
        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-REFUNDED")
        let instanceSlot = InMemoryKeychainSlot("inst_REF")
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        // A present license → store starts .byok.
        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        // Refund/revoke → license + edition metadata cleared, dropped back to
        // the trial computation.
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        XCTAssertEqual(productSlot.readResult(), .absent)
        XCTAssertEqual(majorSlot.readResult(), .absent)
        XCTAssertEqual(transport.callCount, 1, "validate should have been called (throttle elapsed)")
        XCTAssertEqual(store.state, .localTrialExpired, "revocation drops to the trial computation")
    }

    // MARK: - Validate: wrong product is definitive (metadata cleared, key kept)

    func testValidateWrongProductClearsMetadataKeepsKeyAndDropsEntitlement() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": true, "license_key": { "status": "active" }, "meta": { "product_id": 999 } }
        """), 200)]

        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-MIGRATED")
        let instanceSlot = InMemoryKeychainSlot("inst_MIG")
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        // The key + instance stay on file (Settings can still show/deactivate
        // them) but the edition metadata is gone → fails closed offline.
        XCTAssertEqual(keySlot.readResult(), .found("KEY-MIGRATED"))
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_MIG"))
        XCTAssertEqual(productSlot.readResult(), .absent)
        XCTAssertEqual(majorSlot.readResult(), .absent)
        // The throttle stamp was NOT refreshed — a wrong-product check is not
        // a successful validation.
        XCTAssertEqual(lastValidatedSlot.readResult(), .found(oldStamp))
        // And the entitlement dropped out of .byok immediately.
        XCTAssertNotEqual(store.state, .byok)
        XCTAssertFalse(service.currentLicenseState().grantsBYOK)
    }

    /// The product check is NOT gated on `valid`: a `valid:false` response
    /// whose product ID is missing entirely must still be treated as a
    /// definitive incompatibility — metadata cleared, stamp untouched, the
    /// `.byok` entitlement dropped, key + instance preserved (the non-
    /// definitive `valid:false` itself never clears the whole license).
    func testValidateInvalidWithMissingProductDropsByok() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": false, "license_key": { "status": "inactive" } }
        """), 400)]

        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-NOMETA")
        let instanceSlot = InMemoryKeychainSlot("inst_NOMETA")
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        XCTAssertEqual(keySlot.readResult(), .found("KEY-NOMETA"), "non-definitive valid:false keeps the key")
        XCTAssertEqual(instanceSlot.readResult(), .found("inst_NOMETA"))
        XCTAssertEqual(productSlot.readResult(), .absent, "an unvouched product must clear the metadata")
        XCTAssertEqual(majorSlot.readResult(), .absent)
        XCTAssertEqual(lastValidatedSlot.readResult(), .found(oldStamp), "no stamp refresh on a product mismatch")
        XCTAssertNotEqual(store.state, .byok)
    }

    /// Same, with `valid:false` and an explicitly WRONG product ID.
    func testValidateInvalidWithWrongProductDropsByok() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": false, "license_key": { "status": "inactive" }, "meta": { "product_id": 999 } }
        """), 400)]

        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-WRONG")
        let instanceSlot = InMemoryKeychainSlot("inst_WRONG")
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        XCTAssertEqual(keySlot.readResult(), .found("KEY-WRONG"))
        XCTAssertEqual(productSlot.readResult(), .absent)
        XCTAssertEqual(majorSlot.readResult(), .absent)
        XCTAssertEqual(lastValidatedSlot.readResult(), .found(oldStamp), "no stamp refresh on a product mismatch")
        XCTAssertNotEqual(store.state, .byok)
    }

    /// A DEFINITIVE revocation (disabled) that also lacks a product ID clears
    /// the ENTIRE license — the revocation verdict wins over the
    /// keep-key-on-mismatch rule.
    func testDefinitiveRevocationWithMissingProductClearsEverything() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": false, "error": "license key has been disabled", "license_key": { "status": "disabled" } }
        """), 400)]

        let oldStamp = String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        let keySlot = InMemoryKeychainSlot("KEY-DIS")
        let instanceSlot = InMemoryKeychainSlot("inst_DIS")
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(oldStamp),
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot()
        )
        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        XCTAssertEqual(keySlot.readResult(), .absent, "a definitive revocation clears the whole license")
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        XCTAssertNotEqual(store.state, .byok)
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
            lastValidatedSlot: lastValidatedSlot,
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot()
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
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot(),
            clock: { now }
        )

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        await store.revalidateLicenseIfNeeded()

        // Within the throttle window → no network call, still .byok.
        XCTAssertEqual(transport.callCount, 0, "validate must not be called within the throttle window")
        XCTAssertEqual(store.state, .byok)
    }

    func testValidValidationRefreshesThrottleStampAndMetadata() async throws {
        let transport = StubLicenseTransport()
        transport.responses = [(data("""
        { "valid": true, "license_key": { "status": "active" }, "meta": { "product_id": 7 } }
        """), 200)]

        let now = Date()
        let oldInstant = now.addingTimeInterval(-LicenseService.revalidationInterval - 60)
        let oldStamp = String(Int(oldInstant.timeIntervalSince1970))
        let lastValidatedSlot = InMemoryKeychainSlot(oldStamp)
        // No persisted edition — a cache from before the metadata existed.
        let productSlot = InMemoryKeychainSlot()
        let majorSlot = InMemoryKeychainSlot()
        let service = makeService(
            transport: transport,
            keySlot: InMemoryKeychainSlot("KEY-OK"),
            instanceSlot: InMemoryKeychainSlot("inst_OK"),
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot,
            clock: { now }
        )

        XCTAssertTrue(service.shouldRevalidate(), "stale stamp should permit revalidation")
        let result = try await service.validate()
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.productApproved)
        XCTAssertEqual(result.status, .active)
        // Stamp refreshed to "now" → throttle now suppresses the next check.
        XCTAssertFalse(service.shouldRevalidate(), "valid validation should refresh the throttle stamp")
        // And the edition metadata healed from the confirmed response.
        XCTAssertEqual(productSlot.readResult(), .found("7"))
        XCTAssertEqual(majorSlot.readResult(), .found("1"))
    }

    // MARK: - currentLicenseState: presence

    func testCurrentLicenseStatePresentAbsentIndeterminate() {
        // Present + confirmed edition: full offline grant.
        let present = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot()
        )
        XCTAssertEqual(present.currentLicenseState().presence, .present)
        XCTAssertEqual(present.currentLicenseState().edition, .compatible)
        XCTAssertTrue(present.currentLicenseState().grantsBYOK)

        // Absent: nothing stored.
        let absent = makeService(transport: StubLicenseTransport())
        XCTAssertEqual(absent.currentLicenseState().presence, .absent)
        XCTAssertFalse(absent.currentLicenseState().grantsBYOK)

        // Indeterminate: a genuine read failure on the key slot. Diagnostic
        // only — an unverifiable record must FAIL CLOSED.
        let failingKey = InMemoryKeychainSlot("K")
        failingKey.simulateReadFailure = true
        let indeterminate = makeService(
            transport: StubLicenseTransport(),
            keySlot: failingKey,
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot()
        )
        XCTAssertEqual(indeterminate.currentLicenseState().presence, .indeterminate)
        XCTAssertFalse(indeterminate.currentLicenseState().grantsBYOK, "an unreadable key/instance must never unlock")

        // Same for a failing instance slot.
        let failingInstance = InMemoryKeychainSlot("I")
        failingInstance.simulateReadFailure = true
        let indeterminateInstance = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: failingInstance,
            productSlot: compatibleProductSlot(),
            majorSlot: compatibleMajorSlot()
        )
        XCTAssertEqual(indeterminateInstance.currentLicenseState().presence, .indeterminate)
        XCTAssertFalse(indeterminateInstance.currentLicenseState().grantsBYOK)
    }

    // MARK: - currentLicenseState: edition

    func testCachedKeyWithoutEditionMetadataFailsClosed() {
        // An old cache holds a key but no confirmed product/major — never
        // unlocks offline until an online activate/validate re-confirms.
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I")
        )
        let snapshot = service.currentLicenseState()
        XCTAssertEqual(snapshot.presence, .present)
        XCTAssertEqual(snapshot.edition, .missingMetadata)
        XCTAssertFalse(snapshot.grantsBYOK, "missing edition metadata must fail closed")
    }

    func testCachedWrongProductFailsClosed() {
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: InMemoryKeychainSlot("999"),
            majorSlot: compatibleMajorSlot()
        )
        let snapshot = service.currentLicenseState()
        XCTAssertEqual(snapshot.edition, .incompatible(licensedMajor: 1))
        XCTAssertFalse(snapshot.grantsBYOK)
    }

    func testMajorOneLicenseReadByMajorTwoBuildFailsClosed() {
        // A future Zerro 2 build (requiredMajor 2, its own product) reading a
        // cached major-1 record: fails closed, and the snapshot names the
        // licensed major so the paywall can say "covers Zerro 1.x".
        let majorTwoPolicy = LicenseEditionPolicy(requiredMajor: 2, approvedProductIDs: [8])
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: compatibleProductSlot(),   // product 7 = the major-1 product
            majorSlot: compatibleMajorSlot(),       // major 1
            policy: majorTwoPolicy
        )
        let snapshot = service.currentLicenseState()
        XCTAssertEqual(snapshot.edition, .incompatible(licensedMajor: 1))
        XCTAssertFalse(snapshot.grantsBYOK, "a 1.x license must never unlock a 2.x build")
    }

    func testUnparseableEditionMetadataFailsClosed() {
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: InMemoryKeychainSlot("garbage"),
            majorSlot: InMemoryKeychainSlot("also-garbage")
        )
        let snapshot = service.currentLicenseState()
        XCTAssertEqual(snapshot.edition, .incompatible(licensedMajor: nil))
        XCTAssertFalse(snapshot.grantsBYOK)
    }

    func testEditionReadFailureFailsClosed() {
        // A genuine Keychain READ FAILURE on either edition slot leaves the
        // record unverifiable — `.readFailure` is diagnostic only and must
        // FAIL CLOSED.
        let failingProduct = InMemoryKeychainSlot("7")
        failingProduct.simulateReadFailure = true
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: failingProduct,
            majorSlot: compatibleMajorSlot()
        )
        let snapshot = service.currentLicenseState()
        XCTAssertEqual(snapshot.edition, .readFailure)
        XCTAssertFalse(snapshot.grantsBYOK, "an unverifiable edition must never unlock")

        let failingMajor = InMemoryKeychainSlot("1")
        failingMajor.simulateReadFailure = true
        let majorService = makeService(
            transport: StubLicenseTransport(),
            keySlot: InMemoryKeychainSlot("K"),
            instanceSlot: InMemoryKeychainSlot("I"),
            productSlot: compatibleProductSlot(),
            majorSlot: failingMajor
        )
        XCTAssertEqual(majorService.currentLicenseState().edition, .readFailure)
        XCTAssertFalse(majorService.currentLicenseState().grantsBYOK)
    }

    func testAllSlotsFailingReadsNeverUnlockANewOrExpiredUser() {
        // The attack/failure shape that motivated fail-closed: a brand-new
        // (or expired) machine where EVERY license slot reports a read
        // failure must not conjure `.byok` out of unreadable storage.
        let slots = (0..<5).map { _ -> InMemoryKeychainSlot in
            let slot = InMemoryKeychainSlot("junk")
            slot.simulateReadFailure = true
            return slot
        }
        let service = LicenseService(
            licenseKeySlot: slots[0],
            instanceIDSlot: slots[1],
            lastValidatedSlot: slots[2],
            licensedProductIDSlot: slots[3],
            licensedMajorSlot: slots[4],
            policy: Self.testPolicy,
            transport: StubLicenseTransport()
        )
        XCTAssertFalse(service.currentLicenseState().grantsBYOK)

        // Through the store: with no trial clock underneath, the simulated
        // failures land on `.localTrialExpired` (blocked), never `.byok`.
        let store = EntitlementStore(enforcementMode: .official, licenseService: service)
        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - Policy

    func testPolicyApprovalRules() {
        let policy = LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7])
        XCTAssertTrue(policy.isApproved(productID: 7))
        XCTAssertFalse(policy.isApproved(productID: 8))
        XCTAssertFalse(policy.isApproved(productID: nil), "a missing product id is never approved")
    }

    func testCurrentPolicyApprovesExactlyOneEnvironmentProduct() {
        // The build's policy holds exactly ONE product — the environment's —
        // never both. (The test binary compiles DEBUG → the test product.)
        let policy = LicenseEditionPolicy.current
        XCTAssertEqual(policy.requiredMajor, 1)
        XCTAssertEqual(policy.approvedProductIDs.count, 1)
        if LicenseEditionPolicy.usesTestEnvironment {
            XCTAssertEqual(policy.approvedProductIDs, [LicenseEditionPolicy.testProductID])
            XCTAssertFalse(policy.isApproved(productID: LicenseEditionPolicy.liveProductID))
        } else {
            XCTAssertEqual(policy.approvedProductIDs, [LicenseEditionPolicy.liveProductID])
            XCTAssertFalse(policy.isApproved(productID: LicenseEditionPolicy.testProductID))
        }
    }

    // MARK: - clearLicense

    func testClearLicenseRemovesAllFiveSlots() {
        let keySlot = InMemoryKeychainSlot("K")
        let instanceSlot = InMemoryKeychainSlot("I")
        let lastValidatedSlot = InMemoryKeychainSlot("123")
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: StubLicenseTransport(),
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )
        service.clearLicense()
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        XCTAssertEqual(lastValidatedSlot.readResult(), .absent)
        XCTAssertEqual(productSlot.readResult(), .absent)
        XCTAssertEqual(majorSlot.readResult(), .absent)
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
        let productSlot = compatibleProductSlot()
        let majorSlot = compatibleMajorSlot()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            lastValidatedSlot: lastValidatedSlot,
            productSlot: productSlot,
            majorSlot: majorSlot
        )

        let store = makeHermeticStore(licenseService: service, keySlot: keySlot)
        XCTAssertEqual(store.state, .byok)

        try await store.deactivateThisDevice()

        XCTAssertEqual(transport.requests.first?.path, LicenseService.deactivatePath)
        XCTAssertEqual(transport.requests.first?.parameters["instance_id"], "inst_DEV")
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertEqual(instanceSlot.readResult(), .absent)
        XCTAssertEqual(productSlot.readResult(), .absent)
        XCTAssertEqual(majorSlot.readResult(), .absent)
        XCTAssertEqual(store.state, .localTrialExpired, "deactivation drops to the trial computation")
    }
}
