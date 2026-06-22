//
//  PreflightGateTests.swift
//  ZerroTests
//
//  Phase G UX — the record-start PRE-FLIGHT gate: catch every knowable failure
//  BEFORE the user records, not after a wasted capture. Covers
//  `EntitlementStore.preflightBlock(hasOwnAPIKey:)`, the single synchronous,
//  local, fail-open decision the `handleHotkey` gate consults between the
//  `.expired`/`canGenerate` gate and presenting the area selector.
//
//  Contract:
//    • Managed + 0 credits         → .outOfCredits (blocked before recording)
//    • Managed + non-live snapshot → .subscriptionInactive
//    • BYOK + no key on file       → .apiKeyMissing
//    • Everything inconclusive     → nil (FAIL OPEN — record; proxy is backstop)
//    • Entitled with credits / a key → nil (no false blocks)
//
//  All dependencies are in-memory; no Keychain, no network.
//

import XCTest
@testable import Zerro

@MainActor
final class PreflightGateTests: XCTestCase {

    // MARK: - Builders

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

    /// An ephemeral `UserDefaults` pre-seeded with `snapshot` under the cache key
    /// `EntitlementStore` reads at init, so a constructed store comes up `.managed`
    /// with EXACTLY that snapshot (status + credits we choose) — the only way to
    /// model a non-`.active` managed snapshot without driving the network.
    private func defaultsSeeded(with snapshot: ManagedEntitlementSnapshot?) -> UserDefaults {
        let defaults = UserDefaults.ephemeralPreview()
        guard let snapshot else { return defaults }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        defaults.set(try! encoder.encode(snapshot), forKey: "managed_entitlement_snapshot_v1")
        return defaults
    }

    /// A `.managed` store carrying `snapshot` (nil → no cached snapshot yet).
    private func managedStore(snapshot: ManagedEntitlementSnapshot?) -> EntitlementStore {
        EntitlementStore(
            licenseService: makeLicense(present: true),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.managed.rawValue),
            defaults: defaultsSeeded(with: snapshot)
        )
    }

    private func snapshot(
        _ status: ManagedStatus,
        credits: Int
    ) -> ManagedEntitlementSnapshot {
        ManagedEntitlementSnapshot(
            status: status,
            creditsRemaining: credits,
            creditsLimit: 100,
            resetDate: nil
        )
    }

    private func byokStore() -> EntitlementStore {
        EntitlementStore(
            licenseService: makeLicense(present: true),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.byok.rawValue),
            defaults: .ephemeralPreview()
        )
    }

    /// A trial store (no license). `expired: true` seeds confirmed-exhausted
    /// trial credits so it computes to `.expired`; otherwise it's a live
    /// (never-granted) trial.
    private func trialStore(expired: Bool = false) -> EntitlementStore {
        var trialCredits: TrialCreditsManager?
        if expired {
            let mgr = TrialCreditsManager.inMemory()
            mgr.applyCreditsRemaining(0)
            trialCredits = mgr
        }
        return EntitlementStore(
            licenseService: makeLicense(present: false),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(nil),
            trialCredits: trialCredits,
            defaults: .ephemeralPreview()
        )
    }

    // MARK: - Managed: out of credits

    func testManagedZeroCreditsBlocksOutOfCredits() {
        let store = managedStore(snapshot: snapshot(.active, credits: 0))
        XCTAssertEqual(store.preflightBlock(hasOwnAPIKey: false), .outOfCredits)
    }

    func testManagedWithCreditsDoesNotBlock() {
        let store = managedStore(snapshot: snapshot(.active, credits: 42))
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false)) // records normally
    }

    func testManagedTrialFundedCombinedBalanceDoesNotBlock() {
        // Cross-ledger fix: a converted user whose PLAN is exhausted but who still
        // has linked trial credits has a positive COMBINED creditsRemaining (the
        // server folds the trial remainder in). The preflight gate reads that
        // combined number, so it must NOT block — the recording proceeds and the
        // server drains the trial remainder via consume_combined_credit. Modeled
        // as a snapshot whose combined balance is entirely trial-funded.
        let combined = ManagedEntitlementSnapshot(
            status: .active,
            creditsRemaining: 5,            // == trial remainder; plan is spent
            creditsLimit: 100,
            resetDate: nil,
            planCreditsUsed: 100,
            planCreditsLimit: 100,
            topupCreditsRemaining: 0,
            trialCreditsRemaining: 5
        )
        let store = managedStore(snapshot: combined)
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false)) // proceeds, charged across ledgers
    }

    func testManagedNoSnapshotFailsOpen() {
        // Snapshot hasn't been fetched yet (launch refresh not landed) → records.
        let store = managedStore(snapshot: nil)
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false))
    }

    // MARK: - Overspend → negative → blocked (the one final uncapped generation)

    func testOverspendClampsSnapshotToZeroAndBlocksNextGeneration() {
        // A small positive balance (5) runs ONE costlier generation: the server
        // charges in full and returns a NEGATIVE remaining (−6). The toast gets
        // the raw negative, but the cached snapshot clamps to 0 — never up to a
        // positive, so the prior negative is never netted away — and the NEXT
        // pre-flight blocks with .outOfCredits.
        let store = managedStore(snapshot: snapshot(.active, credits: 5))
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false)) // 5 credits → records

        // Apply the just-completed overspend (charged 10, server remaining −6).
        let effective = store.applyGenerationSpend(charged: 10, remaining: -6, isTrial: false)
        XCTAssertEqual(effective, -6) // the toast shows the true (negative) value

        // The snapshot lands on 0 (not a raw negative, not clamped UP to positive)…
        XCTAssertEqual(store.managedSnapshot?.creditsRemaining, 0)
        // …so the next generation is blocked client-side, routed to the top-up paywall.
        XCTAssertEqual(store.preflightBlock(hasOwnAPIKey: false), .outOfCredits)
    }

    // MARK: - Managed: inactive subscription

    func testManagedCancelledSnapshotBlocksSubscriptionInactive() {
        let store = managedStore(snapshot: snapshot(.cancelled, credits: 50))
        XCTAssertEqual(store.preflightBlock(hasOwnAPIKey: false), .subscriptionInactive)
    }

    func testManagedExpiredSnapshotBlocksSubscriptionInactive() {
        let store = managedStore(snapshot: snapshot(.expired, credits: 50))
        XCTAssertEqual(store.preflightBlock(hasOwnAPIKey: false), .subscriptionInactive)
    }

    // MARK: - Managed: past_due (§9.1) — still works on remaining credits

    func testManagedPastDueWithCreditsDoesNotBlock() {
        // past_due is LIVE — keeps working on remaining credits (§9.1).
        let store = managedStore(snapshot: snapshot(.pastDue, credits: 10))
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false))
    }

    func testManagedPastDueZeroCreditsBlocksOutOfCredits() {
        // past_due but nothing left to spend → still out of credits.
        let store = managedStore(snapshot: snapshot(.pastDue, credits: 0))
        XCTAssertEqual(store.preflightBlock(hasOwnAPIKey: false), .outOfCredits)
    }

    // MARK: - BYOK: missing key

    func testByokWithoutKeyBlocksApiKeyMissing() {
        let store = byokStore()
        XCTAssertEqual(store.preflightBlock(hasOwnAPIKey: false), .apiKeyMissing)
    }

    func testByokWithKeyDoesNotBlock() {
        let store = byokStore()
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: true))
    }

    // MARK: - Trial / expired

    func testActiveTrialDoesNotBlock() {
        // A live trial with no own key is handled by the generation route
        // (email capture), not a pre-flight failure block.
        let store = trialStore()
        guard case .trial = store.state else { return XCTFail("expected .trial") }
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false))
    }

    func testExpiredIsHandledByCanGenerateNotPreflight() {
        // Trial credits exhausted → `.expired`; the `canGenerate` gate (not
        // pre-flight) routes it to the paywall, so pre-flight returns nil.
        let store = trialStore(expired: true)
        XCTAssertEqual(store.state, .expired)
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: false))
    }

    // MARK: - Fail-open under a transient Keychain failure

    func testByokKeychainBlipDoesNotBlock() {
        // A flaky license-key read surfaces as `.byok` (grantsBYOK fails open).
        // The gate reads the OpenAI key separately; a blip there reports
        // hasOwnAPIKey == true (the slot fails toward "present"), so no block.
        let store = byokStore()
        XCTAssertNil(store.preflightBlock(hasOwnAPIKey: true)) // blip ⇒ "has key" ⇒ record
    }
}
