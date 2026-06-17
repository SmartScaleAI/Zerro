//
//  CheckoutReturnTests.swift
//  ZerroTests
//
//  Coverage for the `zerro://checkout-complete` deep link's automatic license
//  activation (Step 4 billing). Two layers:
//    • `CheckoutReturn.parse` — pure parsing of the query (key extraction +
//      sanitization, product → kind map). No AppKit, no network.
//    • `AppDelegate.resolveCheckoutReturn` — the side-effecting resolution, with
//      injected `CheckoutReturnEffects` spies so app-foreground / paywall /
//      analytics calls are observed without driving real AppKit. The entitlement
//      layer is fully stubbed (in-memory Keychain + canned LemonSqueezy / session
//      JSON), so these are deterministic.
//
//  Outcomes under test: success entitles + dismisses + clears nothing it
//  shouldn't; failure opens the paywall with the attempted key prefilled; an
//  already-active key is success WITHOUT re-POSTing; the no-key path is byte-for-
//  byte the prior behavior; a cold-launch deep link buffers + replays.
//

import XCTest
@testable import Zerro

@MainActor
final class CheckoutReturnTests: XCTestCase {

    // MARK: - Effects spy

    /// Captures the side effects `resolveCheckoutReturn` performs so tests can
    /// assert them without real AppKit / analytics.
    private final class EffectsSpy {
        var broughtForward = 0
        var dismissed = 0
        var openedPaywall = 0
        var captures: [(event: String, properties: [String: Any])] = []

        func make() -> AppDelegate.CheckoutReturnEffects {
            AppDelegate.CheckoutReturnEffects(
                bringAppForward: { self.broughtForward += 1 },
                dismissPaywall: { self.dismissed += 1 },
                openPaywall: { self.openedPaywall += 1 },
                capture: { self.captures.append((event: $0, properties: $1)) }
            )
        }

        /// The single `purchase_activated` capture's `outcome`, or nil if none.
        var capturedOutcome: String? {
            captures.first { $0.event == "purchase_activated" }?.properties["outcome"] as? String
        }

        var capturedProduct: String? {
            captures.first { $0.event == "purchase_activated" }?.properties["product"] as? String
        }

        /// The `purchase_success_shown` capture's `(method, plan)`, or nil.
        var successShown: (method: String, plan: String)? {
            guard let props = captures.first(where: { $0.event == "purchase_success_shown" })?.properties,
                  let method = props["method"] as? String,
                  let plan = props["plan"] as? String else { return nil }
            return (method, plan)
        }
    }

    // MARK: - Store fixtures

    private func makeService(
        transport: LicenseTransport,
        keySlot: InMemoryKeychainSlot,
        instanceSlot: InMemoryKeychainSlot = InMemoryKeychainSlot()
    ) -> LicenseService {
        LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(),
            licenseCreatedAtSlot: InMemoryKeychainSlot(),
            transport: transport,
            clock: { Date() },
            instanceNameProvider: { "TestMac-DEADBEEF" }
        )
    }

    private func makeStore(
        licenseService: LicenseService,
        keySlot: InMemoryKeychainSlot,
        productKind: LicenseProductKind? = nil,
        sessionTransport: StubManagedTransport = StubManagedTransport()
    ) -> EntitlementStore {
        EntitlementStore(
            licenseService: licenseService,
            sessionTokens: SessionTokenManager(licenseKeySlot: keySlot, transport: sessionTransport),
            productKindSlot: InMemoryKeychainSlot(productKind?.rawValue),
            defaults: UserDefaults(suiteName: "CheckoutReturnTests-\(UUID().uuidString)")!
        )
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// A LemonSqueezy `/activate` success body.
    private func activatedResponse() -> (Data, Int) {
        (data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_X" } }"#), 200)
    }

    /// A LemonSqueezy `/activate` at-limit refusal (the failure path).
    private func atLimitResponse() -> (Data, Int) {
        (data("""
        {
          "activated": false,
          "error": "This license key has reached the activation limit.",
          "license_key": { "status": "active", "activation_limit": 1, "activation_usage": 1 },
          "instance": null
        }
        """), 400)
    }

    private let sampleKey = "38B12ACB-19EA-4D77-A38C-1234567890AB"

    // MARK: - Parsing

    func testParseExtractsKeyAndManagedProduct() {
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)&product=subscription_pro")!
        let parsed = CheckoutReturn.parse(url)
        XCTAssertEqual(parsed?.licenseKey, sampleKey)
        XCTAssertEqual(parsed?.productKind, .managed)
    }

    func testParseExtractsByokProduct() {
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)&product=byok")!
        XCTAssertEqual(CheckoutReturn.parse(url)?.productKind, .byok)
    }

    func testParseUnknownProductMapsToNil() {
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)&product=mystery")!
        let parsed = CheckoutReturn.parse(url)
        XCTAssertEqual(parsed?.licenseKey, sampleKey)
        XCTAssertNil(parsed?.productKind)
    }

    func testParseMissingProductAndKey() {
        let parsed = CheckoutReturn.parse(URL(string: "zerro://checkout-complete")!)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.licenseKey)
        XCTAssertNil(parsed?.productKind)
    }

    func testParseNonCheckoutHostReturnsNil() {
        XCTAssertNil(CheckoutReturn.parse(URL(string: "zerro://something-else?license_key=\(sampleKey)")!))
    }

    func testProductKindMap() {
        XCTAssertEqual(CheckoutReturn.productKind(from: "subscription_pro"), .managed)
        XCTAssertEqual(CheckoutReturn.productKind(from: "byok"), .byok)
        XCTAssertNil(CheckoutReturn.productKind(from: "other"))
        XCTAssertNil(CheckoutReturn.productKind(from: nil))
    }

    func testParseRejectsMalformedKeys() {
        // Too short.
        XCTAssertNil(CheckoutReturn.parse(URL(string: "zerro://checkout-complete?license_key=ABC")!)?.licenseKey)
        // Illegal characters (not hex/dash).
        let bad = "zerro://checkout-complete?license_key=not_a_valid_license_key!!"
        XCTAssertNil(CheckoutReturn.parse(URL(string: bad)!)?.licenseKey)
    }

    // MARK: - Success

    func testKeyActivationSucceedsEntitlesAndDismisses() async {
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        // The /session probe returns not-entitled (403) → BYOK classification.
        let session = StubManagedTransport()
        session.enqueue(#"{"error":"not_entitled"}"#, status: 403)
        let store = makeStore(licenseService: service, keySlot: keySlot, sessionTransport: session)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: sampleKey, productKind: .byok),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(store.state, .byok)
        // Success now SHOWS the confirmation (opens the paywall) instead of
        // dismissing — the user dismisses via the confirmation's button.
        XCTAssertEqual(store.purchaseSuccess, .byok)
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(spy.dismissed, 0)
        XCTAssertEqual(spy.capturedOutcome, "success")
        XCTAssertEqual(spy.capturedProduct, "byok")
        XCTAssertEqual(spy.successShown?.method, "deeplink")
        XCTAssertEqual(spy.successShown?.plan, "byok")
        XCTAssertNil(store.prefillLicenseKey)
    }

    // MARK: - Failure

    func testKeyActivationFailureOpensPaywallWithPrefill() async {
        let transport = LicenseServiceStubTransport(responses: [atLimitResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let store = makeStore(licenseService: service, keySlot: keySlot)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: sampleKey, productKind: .managed),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .activationFailed)
        // The paywall opens focused on the activation field with the attempted
        // key prefilled so the user can see + retry it.
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(store.prefillLicenseKey, sampleKey)
        XCTAssertEqual(store.paywallTrigger, .manage)
        XCTAssertTrue(store.focusActivationFieldOnOpen)
        XCTAssertEqual(spy.broughtForward, 0)
        XCTAssertEqual(spy.capturedOutcome, "failed")
        XCTAssertEqual(spy.capturedProduct, "managed")
        // A failed activation never wrote the Keychain.
        XCTAssertEqual(keySlot.readResult(), .absent)
    }

    // MARK: - Idempotency (already active)

    func testAlreadyActiveKeyIsSuccessWithoutReactivating() async {
        // Seed a present license whose key equals the deep-link key, kind byok →
        // the store is already `.byok` (paid-entitled).
        let transport = LicenseServiceStubTransport(responses: [])
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let instanceSlot = InMemoryKeychainSlot("instance")
        let service = makeService(transport: transport, keySlot: keySlot, instanceSlot: instanceSlot)
        let store = makeStore(licenseService: service, keySlot: keySlot, productKind: .byok)
        XCTAssertTrue(store.isPaidEntitled)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: sampleKey, productKind: .byok),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .alreadyActive)
        // No re-activation: the LemonSqueezy /activate endpoint was never hit.
        XCTAssertEqual(transport.callCount, 0)
        // Already-active is still a success → shows the confirmation.
        XCTAssertEqual(store.purchaseSuccess, .byok)
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(spy.dismissed, 0)
        XCTAssertEqual(spy.capturedOutcome, "already_active")
        XCTAssertEqual(spy.successShown?.method, "deeplink")
        XCTAssertEqual(spy.successShown?.plan, "byok")
        XCTAssertNil(store.prefillLicenseKey)
    }

    // MARK: - No-key path (unchanged behavior)

    func testNoKeyEntitledRefreshesSilently() async {
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let service = makeService(
            transport: LicenseServiceStubTransport(responses: []),
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("instance")
        )
        let store = makeStore(licenseService: service, keySlot: keySlot, productKind: .byok)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: nil, productKind: nil),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .silentRefresh)
        XCTAssertEqual(spy.broughtForward, 1)
        XCTAssertEqual(spy.dismissed, 1)
        XCTAssertEqual(spy.openedPaywall, 0)
        // No analytics on the no-key path (parity with prior behavior).
        XCTAssertTrue(spy.captures.isEmpty)
    }

    func testNoKeyNotEntitledOpensPaywallFocused() async {
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: LicenseServiceStubTransport(responses: []), keySlot: keySlot)
        // No license, no trial credits → not paid-entitled.
        let store = makeStore(licenseService: service, keySlot: keySlot)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: nil, productKind: nil),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .openedPaywallNoKey)
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(store.paywallTrigger, .manage)
        XCTAssertTrue(store.focusActivationFieldOnOpen)
        XCTAssertNil(store.prefillLicenseKey)
        XCTAssertTrue(spy.captures.isEmpty)
    }

    // MARK: - Cold-launch buffering

    func testColdLaunchBuffersURLBeforeWiringThenReplays() {
        let priorEntitlements = AppDelegate.entitlements
        defer {
            AppDelegate.entitlements = priorEntitlements
            AppDelegate.pendingCheckoutURL = nil
        }

        // Arrive before the store is wired → the URL is buffered, not dropped.
        AppDelegate.entitlements = nil
        AppDelegate.pendingCheckoutURL = nil
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)&product=byok")!
        AppDelegate.handleCheckoutReturn(url)
        XCTAssertEqual(AppDelegate.pendingCheckoutURL, url)

        // Wiring runs: the store is set and the buffered URL is replayed + cleared.
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let service = makeService(
            transport: LicenseServiceStubTransport(responses: []),
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("instance")
        )
        let store = makeStore(licenseService: service, keySlot: keySlot, productKind: .byok)
        AppDelegate.entitlements = store
        AppDelegate.replayPendingCheckoutURLIfNeeded()
        XCTAssertNil(AppDelegate.pendingCheckoutURL)
        // Keep `store` alive past the weak `AppDelegate.entitlements` assignment
        // for the duration of the replayed resolution.
        withExtendedLifetime(store) {}
    }

    // MARK: - PurchaseSuccessInfo derivation + copy

    func testPurchaseSuccessDerivationFromState() {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(
            PurchaseSuccessInfo.fromActivatedState(.managed(creditsRemaining: 300, resetDate: reset)),
            .managed(credits: 300, resetDate: reset)
        )
        XCTAssertEqual(PurchaseSuccessInfo.fromActivatedState(.byok), .byok)
        // Non-paid states have nothing to confirm.
        XCTAssertNil(PurchaseSuccessInfo.fromActivatedState(.trial(creditsRemaining: 5)))
        XCTAssertNil(PurchaseSuccessInfo.fromActivatedState(.expired))
    }

    func testTopupDeltaComputation() {
        XCTAssertEqual(PurchaseSuccessInfo.topupDelta(before: 10, after: 30), .topup(added: 20, total: 30))
        XCTAssertNil(PurchaseSuccessInfo.topupDelta(before: 30, after: 30), "no increase → nothing to confirm")
        XCTAssertNil(PurchaseSuccessInfo.topupDelta(before: 40, after: 30), "a decrease isn't a top-up")
        XCTAssertNil(PurchaseSuccessInfo.topupDelta(before: nil, after: 30), "unknown before → can't compute")
        XCTAssertNil(PurchaseSuccessInfo.topupDelta(before: 10, after: nil), "unknown after → can't compute")
    }

    func testDetailLineCopyPerVariant() {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(
            PurchaseSuccessInfo.managed(credits: 300, resetDate: reset).detailLine { _ in "Jul 1, 2026" },
            "Managed is active. 300 credits available, resets Jul 1, 2026."
        )
        XCTAssertEqual(
            PurchaseSuccessInfo.byok.detailLine { _ in "" },
            "Bring-your-own-key is active. Add your provider API key in Settings to start generating."
        )
        XCTAssertEqual(
            PurchaseSuccessInfo.topup(added: 100, total: 220).detailLine { _ in "" },
            "Added 100 credits \u{2014} 220 total."
        )
    }

    // MARK: - Top-up confirmation (no-key path with a credit increase)

    func testTopUpComputesDeltaAndShowsConfirmation() async {
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let service = makeService(
            transport: LicenseServiceStubTransport(responses: []),
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("instance")
        )
        // First /entitlement seeds the cached balance at 10; the resolve's
        // refresh then sees 30 (the session token is cached across both).
        let session = StubManagedTransport()
        session.enqueue(ManagedFixtures.sessionJSON(token: "SUB-TOK"), status: 200)
        session.enqueue(ManagedFixtures.entitlementJSON(status: "active", creditsRemaining: 10), status: 200)
        session.enqueue(ManagedFixtures.entitlementJSON(status: "active", creditsRemaining: 30), status: 200)
        let store = makeStore(
            licenseService: service,
            keySlot: keySlot,
            productKind: .managed,
            sessionTransport: session
        )

        // Seed the "before" balance.
        await store.refreshManagedEntitlement()
        XCTAssertEqual(store.currentDisplayedCredits, 10)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: nil, productKind: nil),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .topupConfirmed)
        XCTAssertEqual(store.purchaseSuccess, .topup(added: 20, total: 30))
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(spy.dismissed, 0)
        XCTAssertEqual(spy.successShown?.method, "deeplink")
        XCTAssertEqual(spy.successShown?.plan, "topup")
    }

    // MARK: - Manual paste routes through purchaseSuccess; dismiss clears it

    func testManualPasteDerivesPurchaseSuccessAndDismissClears() async {
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let session = StubManagedTransport()
        session.enqueue(#"{"error":"not_entitled"}"#, status: 403) // → BYOK
        let store = makeStore(licenseService: service, keySlot: keySlot, sessionTransport: session)

        // The manual-paste card activates through the SAME store entry point,
        // then derives the confirmation from the resulting state (what
        // `PaywallView.showManualActivationSuccess` does).
        try? await store.activate(licenseKey: sampleKey)
        XCTAssertEqual(store.state, .byok)
        let info = PurchaseSuccessInfo.fromActivatedState(store.state)
        XCTAssertEqual(info, .byok)
        store.purchaseSuccess = info
        XCTAssertEqual(store.purchaseSuccess, .byok)

        // Dismissing the confirmation clears the one-shot.
        store.purchaseSuccess = nil
        XCTAssertNil(store.purchaseSuccess)
    }
}

/// A standalone stub of `LicenseTransport` for these tests (the one in
/// `LicenseServiceTests` is nested + private). Returns queued responses in order;
/// records the call count so the idempotency test can assert "never POSTed".
private final class LicenseServiceStubTransport: LicenseTransport {
    private var responses: [(Data, Int)]
    private(set) var callCount = 0

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
        callCount += 1
        guard !responses.isEmpty else { return (Data("{}".utf8), 200) }
        return responses.removeFirst()
    }
}
