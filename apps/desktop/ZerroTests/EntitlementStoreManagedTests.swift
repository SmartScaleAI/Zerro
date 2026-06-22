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
//  Precedence under test: Managed subscription > BYOK license > trial credits >
//  expired — with the fail-open contract: a transient Keychain read failure for
//  an entitled user never drops them to `.expired`. The trial is now a pure
//  credit pool (no clock): `.trial` while credits remain (or before any grant),
//  `.expired` only on a CONFIRMED zero balance.
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
        trialCredits: TrialCreditsManager? = nil
    ) -> EntitlementStore {
        EntitlementStore(
            licenseService: license,
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(productKind?.rawValue),
            trialCredits: trialCredits,
            defaults: .ephemeralPreview()
        )
    }

    /// A trial layer whose server-funded credits are confirmed exhausted (0) —
    /// the only way a no-license user computes to `.expired` now that the trial
    /// is purely credit-gated.
    private func exhaustedTrialCredits() -> TrialCreditsManager {
        let mgr = TrialCreditsManager.inMemory()
        mgr.applyCreditsRemaining(0)
        return mgr
    }

    private func isManaged(_ state: EntitlementState) -> Bool {
        if case .managed = state { return true }
        return false
    }

    // MARK: - Precedence

    func testManagedOutranksExpiredTrial() {
        // License present + kind managed + trial credits exhausted → still .managed.
        let store = makeStore(
            license: makeLicense(present: true),
            productKind: .managed,
            trialCredits: exhaustedTrialCredits()
        )
        XCTAssertTrue(isManaged(store.state))
        XCTAssertTrue(store.routesThroughManagedProxy)
        XCTAssertTrue(store.canGenerate)
    }

    func testByokOutranksTrialButManagedKindWins() {
        // Same present license, kind byok → .byok (local path, not the proxy).
        let store = makeStore(
            license: makeLicense(present: true),
            productKind: .byok
        )
        XCTAssertEqual(store.state, .byok)
        XCTAssertFalse(store.routesThroughManagedProxy)
    }

    func testUnresolvedKindWithLicenseFailsOpenToByok() {
        // License present but kind not yet resolved → defaults to .byok (the
        // server-money-free path; a background probe upgrades a real managed
        // key to .managed later). Exhausted trial credits underneath confirm the
        // license — not a leftover trial — is what's granting access.
        let store = makeStore(
            license: makeLicense(present: true),
            productKind: nil,
            trialCredits: exhaustedTrialCredits()
        )
        XCTAssertEqual(store.state, .byok)
        XCTAssertFalse(store.routesThroughManagedProxy)
    }

    func testNoLicenseActiveTrial() {
        // No license, never-granted trial (nil credits) → .trial (pre-trial).
        let store = makeStore(
            license: makeLicense(present: false),
            productKind: nil
        )
        guard case .trial = store.state else {
            return XCTFail("expected .trial, got \(store.state)")
        }
    }

    func testNoLicenseExpiredTrial() {
        // No license + trial credits confirmed exhausted → .expired.
        let store = makeStore(
            license: makeLicense(present: false),
            productKind: nil,
            trialCredits: exhaustedTrialCredits()
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
            trialCredits: exhaustedTrialCredits()
        )
        XCTAssertTrue(isManaged(store.state))
        XCTAssertNotEqual(store.state, .expired)
    }

    func testTransientKeychainFailureKeepsByok() {
        let store = makeStore(
            license: makeLicense(present: true, readFailure: true),
            productKind: .byok,
            trialCredits: exhaustedTrialCredits()
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

    // MARK: - Conversion link (trial_grant_id → checkout custom_data)

    func testTrialGrantIdForCheckoutPassesThroughFromTrialLayer() async throws {
        // After a trial verify, the cached grant id surfaces through the store so
        // the conversion checkout can carry it in custom_data (exact link).
        let transport = StubManagedTransport()
        transport.enqueue(
            #"{"token":"T","expires_at":"2030-01-01T00:00:00.000Z","trial_credits_remaining":15,"trial_grant_id":"grant-uuid-9"}"#,
            status: 200,
        )
        let mgr = TrialCreditsManager(
            emailSlot: InMemoryKeychainSlot(nil),
            tokenSlot: InMemoryKeychainSlot(nil),
            transport: transport,
            defaults: .ephemeralPreview()
        )
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")

        let store = makeStore(license: makeLicense(present: false), productKind: nil, trialCredits: mgr)
        XCTAssertEqual(store.trialGrantIdForCheckout, "grant-uuid-9")
    }

    func testTrialGrantIdForCheckoutNilWithoutTrialLayer() {
        let store = makeStore(license: makeLicense(present: false), productKind: nil)
        XCTAssertNil(store.trialGrantIdForCheckout)
    }

    func testCheckoutURLCarriesTrialGrantIdWhenProvided() {
        let base = URL(string: "https://store.example.com/checkout/buy/abc")!
        let url = BillingLinks.checkoutURL(base, product: .subscriptionPro, trialGrantId: "grant-uuid-9")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains { $0.name == "checkout[custom][trial_grant_id]" && $0.value == "grant-uuid-9" })
        XCTAssertTrue(items.contains { $0.name == "checkout[custom][product]" && $0.value == "subscription_pro" })
    }

    func testCheckoutURLOmitsTrialGrantIdWhenNil() {
        let base = URL(string: "https://store.example.com/checkout/buy/abc")!
        let url = BillingLinks.checkoutURL(base, product: .byok) // no grant id
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(items.contains { $0.name == "checkout[custom][trial_grant_id]" })
    }

    // MARK: - Affiliate referral (server-side IP match → aff_ref)

    /// A resolved affiliate code rides as the top-level `aff_ref` query param
    /// LemonSqueezy reads to attribute the sale, alongside the existing custom
    /// data (which stays nested under checkout[custom][…]).
    func testCheckoutURLAppendsAffRefWhenProvided() {
        let base = URL(string: "https://store.getzerro.app/checkout/buy/abc")!
        let url = BillingLinks.checkoutURL(base, product: .subscriptionPro, trialGrantId: "grant-9", affRef: "ZylBs")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains { $0.name == "aff_ref" && $0.value == "ZylBs" })
        XCTAssertTrue(items.contains { $0.name == "checkout[custom][product]" && $0.value == "subscription_pro" })
        XCTAssertTrue(items.contains { $0.name == "checkout[custom][trial_grant_id]" && $0.value == "grant-9" })
    }

    /// No affiliate (nil or empty) → no `aff_ref`, byte-identical to a plain
    /// checkout so a non-referred purchase is unaffected.
    func testCheckoutURLOmitsAffRefWhenNilOrEmpty() {
        let base = URL(string: "https://store.getzerro.app/checkout/buy/abc")!
        let plain = BillingLinks.checkoutURL(base, product: .byok)
        let withNil = BillingLinks.checkoutURL(base, product: .byok, affRef: nil)
        let withEmpty = BillingLinks.checkoutURL(base, product: .byok, affRef: "")
        for url in [withNil, withEmpty] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertFalse(items.contains { $0.name == "aff_ref" })
        }
        XCTAssertEqual(withNil.absoluteString, plain.absoluteString)
    }
}
