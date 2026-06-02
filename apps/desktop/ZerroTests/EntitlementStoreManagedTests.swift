//
//  EntitlementStoreManagedTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/2/26.
//
//  Phase E — coverage for Managed precedence + the routing decision. All
//  dependencies are in-memory (no Keychain, no network), so these are
//  deterministic checks on `computeState`'s precedence ladder and the
//  `routesThroughManagedProxy` branch the generation pipeline reads.
//
//  Precedence under test: Managed subscription > BYOK license > trial clock >
//  expired — with the fail-open contract: a transient Keychain read failure for
//  an entitled user never drops them to `.expired`.
//

import XCTest
@testable import Zerro

@MainActor
final class EntitlementStoreManagedTests: XCTestCase {

    /// Builds a `LicenseService` over in-memory slots. `present` seeds a key +
    /// instance (a usable cached license); `readFailure` makes both slots report
    /// `.failure` (the transient-failure / fail-open path).
    private func makeLicense(present: Bool, readFailure: Bool = false) -> LicenseService {
        let keySlot = InMemoryKeychainSlot(present ? "KEY" : nil)
        let instanceSlot = InMemoryKeychainSlot(present ? "instance" : nil)
        keySlot.simulateReadFailure = readFailure
        instanceSlot.simulateReadFailure = readFailure
        return LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            transport: OfflineLicenseTransport()
        )
    }

    private func makeStore(
        license: LicenseService,
        productKind: LicenseProductKind?,
        startedDaysAgo: Int = 1
    ) -> EntitlementStore {
        EntitlementStore(
            trialManager: .inMemory(startedDaysAgo: startedDaysAgo),
            licenseService: license,
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(productKind?.rawValue),
            defaults: .ephemeralPreview()
        )
    }

    private func isManaged(_ state: EntitlementState) -> Bool {
        if case .managed = state { return true }
        return false
    }

    // MARK: - Precedence

    func testManagedOutranksExpiredTrial() {
        // License present + kind managed + trial long expired → still .managed.
        let store = makeStore(
            license: makeLicense(present: true),
            productKind: .managed,
            startedDaysAgo: 30
        )
        XCTAssertTrue(isManaged(store.state))
        XCTAssertTrue(store.routesThroughManagedProxy)
        XCTAssertTrue(store.canGenerate)
    }

    func testByokOutranksTrialButManagedKindWins() {
        // Same present license, kind byok → .byok (local path, not the proxy).
        let store = makeStore(
            license: makeLicense(present: true),
            productKind: .byok,
            startedDaysAgo: 1
        )
        XCTAssertEqual(store.state, .byok)
        XCTAssertFalse(store.routesThroughManagedProxy)
    }

    func testUnresolvedKindWithLicenseFailsOpenToByok() {
        // License present but kind not yet resolved → defaults to .byok (the
        // server-money-free path; a background probe upgrades a real managed
        // key to .managed later).
        let store = makeStore(
            license: makeLicense(present: true),
            productKind: nil,
            startedDaysAgo: 30
        )
        XCTAssertEqual(store.state, .byok)
        XCTAssertFalse(store.routesThroughManagedProxy)
    }

    func testNoLicenseActiveTrial() {
        let store = makeStore(
            license: makeLicense(present: false),
            productKind: nil,
            startedDaysAgo: 1
        )
        guard case .trial = store.state else {
            return XCTFail("expected .trial, got \(store.state)")
        }
    }

    func testNoLicenseExpiredTrial() {
        let store = makeStore(
            license: makeLicense(present: false),
            productKind: nil,
            startedDaysAgo: 30
        )
        XCTAssertEqual(store.state, .expired)
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - Fail-open

    func testTransientKeychainFailureKeepsManaged() {
        // Both license slots report .failure → indeterminate presence. With kind
        // managed, the user stays .managed (fail OPEN), never dropped to expired.
        let store = makeStore(
            license: makeLicense(present: true, readFailure: true),
            productKind: .managed,
            startedDaysAgo: 30
        )
        XCTAssertTrue(isManaged(store.state))
        XCTAssertNotEqual(store.state, .expired)
    }

    func testTransientKeychainFailureKeepsByok() {
        let store = makeStore(
            license: makeLicense(present: true, readFailure: true),
            productKind: .byok,
            startedDaysAgo: 30
        )
        XCTAssertEqual(store.state, .byok)
    }

    // MARK: - Routing

    func testRoutesThroughManagedProxyOnlyWhenManaged() {
        let managed = makeStore(license: makeLicense(present: true), productKind: .managed)
        let byok = makeStore(license: makeLicense(present: true), productKind: .byok)
        let trial = makeStore(license: makeLicense(present: false), productKind: nil)

        XCTAssertTrue(managed.routesThroughManagedProxy)   // → ManagedProxyClient
        XCTAssertFalse(byok.routesThroughManagedProxy)      // → direct OpenAI
        XCTAssertFalse(trial.routesThroughManagedProxy)     // → direct OpenAI
    }
}
