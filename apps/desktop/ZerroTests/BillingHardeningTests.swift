//
//  BillingHardeningTests.swift
//  ZerroTests
//
//  Phase G — the fail-open vs fail-closed split + terminal-state routing,
//  proven at the layer the existing suites don't reach: the live
//  `/entitlement` refresh (`EntitlementStore.refreshManagedEntitlement`).
//
//  The §5 audit contract:
//    • FAIL-OPEN on infrastructure failure — a network blip during the Managed
//      entitlement refresh must NEVER drop an already-entitled `.managed` user
//      to `.expired`. (The computeState/Keychain-layer fail-open is covered by
//      EntitlementStoreManagedTests; this covers the NETWORK layer.)
//    • FAIL-CLOSED on a DEFINITIVE server signal — a `not_entitled` (403) or a
//      terminal status (`cancelled`/`expired`) from the backend IS server truth
//      and must drop the user out of `.managed` to the paywall, clearing the
//      cached entitlement. A server-side revoked grant must not keep reading as
//      active locally for spend purposes.
//    • §9.1 — a `past_due` refresh keeps the user working (still `.managed`,
//      `canGenerate`) with the past-due nudge surfaced via the snapshot status.
//    • §6 terminal-state routing — revoked/expired ⇒ paywall (`canGenerate`
//      false); the record-start gate blocks `.expired`.
//
//  All dependencies are in-memory / stubbed (no Keychain, no network).
//

import XCTest
@testable import Zerro

@MainActor
final class BillingHardeningTests: XCTestCase {

    // MARK: - Builders

    /// A present (cached) BYOK/Managed license over in-memory slots. `readFailure`
    /// makes the slots report `.failure` (the transient Keychain path).
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

    /// A `.managed` store whose `/session` + `/entitlement` traffic is driven by
    /// `transport`. The session manager has a key on file so the exchange runs.
    /// The underlying trial credits are seeded exhausted (0) so that when a
    /// definitive revocation clears the Managed license, the store falls through
    /// to `.expired` (the paywall) rather than a leftover trial.
    private func makeManagedStore(
        transport: StubManagedTransport
    ) -> EntitlementStore {
        let sessionTokens = SessionTokenManager(
            licenseKeySlot: InMemoryKeychainSlot("KEY"),
            transport: transport
        )
        let exhaustedTrial = TrialCreditsManager.inMemory()
        exhaustedTrial.applyCreditsRemaining(0)
        return EntitlementStore(
            licenseService: makeLicense(present: true),
            sessionTokens: sessionTokens,
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.managed.rawValue),
            trialCredits: exhaustedTrial,
            defaults: .ephemeralPreview()
        )
    }

    private func isManaged(_ state: EntitlementState) -> Bool {
        if case .managed = state { return true }
        return false
    }

    // MARK: - FAIL-OPEN (network layer)

    func testManagedRefreshFailsOpenOnNetworkBlip() async {
        // The refresh can't complete (offline). An entitled Managed user must
        // stay `.managed` — never dropped to `.expired` over a transient failure.
        let transport = StubManagedTransport()
        transport.error = URLError(.notConnectedToInternet)
        let store = makeManagedStore(transport: transport)
        XCTAssertTrue(isManaged(store.state)) // precondition

        await store.refreshManagedEntitlement()

        XCTAssertTrue(isManaged(store.state), "network blip must NOT drop a managed user")
        XCTAssertNotEqual(store.state, .expired)
        XCTAssertTrue(store.canGenerate)
    }

    func testManagedRefreshFailsOpenOnServer5xx() async {
        // A 5xx on the /session mint is inconclusive → fail open, stay managed.
        let transport = StubManagedTransport()
        transport.enqueue(#"{"error":"server_error"}"#, status: 503)
        let store = makeManagedStore(transport: transport)

        await store.refreshManagedEntitlement()

        XCTAssertTrue(isManaged(store.state))
        XCTAssertTrue(store.canGenerate)
    }

    // MARK: - FAIL-CLOSED (definitive server revocation)

    func testManagedRefreshFailsClosedOnNotEntitled() async {
        // /session mints a token, then /entitlement returns 403 not_entitled —
        // the subscription was cancelled/expired server-side. This is server
        // truth: the user must drop out of `.managed` to the paywall, and the
        // cached entitlement must be cleared (no stale local "active").
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "SUB-TOK"), status: 200)
        transport.enqueue(#"{"error":"not_entitled"}"#, status: 403)
        let store = makeManagedStore(transport: transport)
        XCTAssertTrue(isManaged(store.state))

        await store.refreshManagedEntitlement()

        XCTAssertEqual(store.state, .expired, "definitive revocation drops to the paywall")
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.managedSnapshot, "the cached entitlement is cleared on revocation")
        XCTAssertFalse(store.routesThroughManagedProxy)
    }

    func testManagedRefreshFailsClosedOnTerminalStatus() async {
        // /entitlement returns 200 but with a TERMINAL status (cancelled) — a
        // dropped-cancel that the mirror has since caught. `isLive == false` →
        // treated as a definitive revocation (mirrors the §14.6 server guard).
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "SUB-TOK"), status: 200)
        transport.enqueue(ManagedFixtures.entitlementJSON(status: "cancelled"), status: 200)
        let store = makeManagedStore(transport: transport)

        await store.refreshManagedEntitlement()

        XCTAssertEqual(store.state, .expired)
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.managedSnapshot)
    }

    // MARK: - §9.1 past-due keeps working (+ nudge surfaced)

    func testManagedRefreshPastDueKeepsWorkingWithNudge() async {
        // payment_failed → past_due. The user keeps generating on remaining
        // credits (§9.1); the snapshot status drives the "update your card" nudge.
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "SUB-TOK"), status: 200)
        transport.enqueue(
            ManagedFixtures.entitlementJSON(status: "past_due", creditsRemaining: 20),
            status: 200
        )
        let store = makeManagedStore(transport: transport)

        await store.refreshManagedEntitlement()

        XCTAssertTrue(isManaged(store.state), "past_due is still a working managed state")
        XCTAssertTrue(store.canGenerate)
        XCTAssertEqual(store.managedSnapshot?.status, .pastDue) // drives the nudge
        XCTAssertEqual(store.managedSnapshot?.creditsRemaining, 20)
    }

    // MARK: - successful refresh updates the display credits

    func testManagedRefreshSuccessUpdatesCredits() async {
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "SUB-TOK"), status: 200)
        transport.enqueue(
            ManagedFixtures.entitlementJSON(status: "active", creditsRemaining: 42),
            status: 200
        )
        let store = makeManagedStore(transport: transport)

        await store.refreshManagedEntitlement()

        XCTAssertTrue(isManaged(store.state))
        XCTAssertEqual(store.managedSnapshot?.status, .active)
        XCTAssertEqual(store.managedSnapshot?.creditsRemaining, 42)
    }

    // MARK: - FAIL-CLOSED on spend: a local flag alone never authorizes

    func testManagedRouteRequiresTheProxyPath() {
        // `.managed` routes to `.managedProxy` — which AppState only runs WITH a
        // managedProxyClient + a session token (see AppState.runPromptGeneration);
        // the local flag never authorizes a server-funded generation by itself
        // (the proxy enforces credits regardless — proven server-side).
        let transport = StubManagedTransport()
        let store = makeManagedStore(transport: transport)
        XCTAssertEqual(store.generationRoute(canGenerateLocally: false), .managedProxy)
    }

    func testExpiredStateBlocksTheRecordGate() {
        // Terminal state → the record-start gate refuses (paywall), no dead end.
        // No license + trial credits confirmed exhausted → `.expired`.
        let exhaustedTrial = TrialCreditsManager.inMemory()
        exhaustedTrial.applyCreditsRemaining(0)
        let store = EntitlementStore(
            licenseService: makeLicense(present: false),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(nil),
            trialCredits: exhaustedTrial,
            defaults: .ephemeralPreview()
        )
        XCTAssertEqual(store.state, .expired)
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - revocation is idempotent / safe to repeat

    func testRepeatedRevocationStaysExpired() async {
        let transport = StubManagedTransport()
        transport.enqueue(ManagedFixtures.sessionJSON(token: "SUB-TOK"), status: 200)
        transport.enqueue(#"{"error":"not_entitled"}"#, status: 403)
        let store = makeManagedStore(transport: transport)

        await store.refreshManagedEntitlement() // drops to expired
        XCTAssertEqual(store.state, .expired)

        // A second refresh is a no-op (guard: not routesThroughManagedProxy).
        await store.refreshManagedEntitlement()
        XCTAssertEqual(store.state, .expired)
    }
}
