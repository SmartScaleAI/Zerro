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
        var dismissedSettings = 0
        var openedPaywall = 0
        var openedActivateKey = 0
        var captures: [(event: String, properties: [String: Any])] = []

        func make() -> AppDelegate.CheckoutReturnEffects {
            AppDelegate.CheckoutReturnEffects(
                bringAppForward: { self.broughtForward += 1 },
                dismissPaywall: { self.dismissed += 1 },
                dismissSettings: { self.dismissedSettings += 1 },
                openPaywall: { self.openedPaywall += 1 },
                openActivateKey: { self.openedActivateKey += 1 },
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
        instanceSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        confirmReplace: @escaping () async -> Bool = { true }
    ) -> LicenseService {
        LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(),
            licenseCreatedAtSlot: InMemoryKeychainSlot(),
            transport: transport,
            clock: { Date() },
            instanceNameProvider: { "TestMac-DEADBEEF" },
            confirmReplace: confirmReplace
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

    // MARK: - Deep-link key → PREFILL + CONFIRM (E-01), never auto-activate

    func testKeyDeepLinkPrefillsActivationFieldWithoutActivating() async {
        // A first-time buyer's checkout-return link carries a key. E-01: the app
        // must NOT activate it on its own — it routes the key into the activation
        // field, prefilled + focused, and waits for the user to tap Activate.
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let store = makeStore(licenseService: service, keySlot: keySlot)
        XCTAssertFalse(store.isPaidEntitled) // precondition: a fresh trial user

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: sampleKey, productKind: .byok),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .prefilled)
        // The DEDICATED activate-key window opens (not the full paywall), focused
        // on the field with the key prefilled.
        XCTAssertEqual(spy.openedActivateKey, 1)
        XCTAssertEqual(spy.openedPaywall, 0)
        // Window hygiene: the paywall (the user came from the in-paywall buy flow)
        // and any Settings window AppKit materialized on the reactivation are
        // dismissed so ONLY the Activate window remains.
        XCTAssertEqual(spy.dismissed, 1)
        XCTAssertEqual(spy.dismissedSettings, 1)
        XCTAssertEqual(store.prefillLicenseKey, sampleKey)
        XCTAssertEqual(store.paywallTrigger, .manage)
        XCTAssertTrue(store.focusActivationFieldOnOpen)
        // NOTHING was activated: no POST, no Keychain write, state unchanged.
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(keySlot.readResult(), .absent)
        XCTAssertNil(store.purchaseSuccess)
        if case .trial = store.state {} else { XCTFail("state must NOT change from a deep link") }
        // CRITICAL: a spoofed link must not pollute the purchase funnel — the
        // handler emits NO analytics at all (purchase_activated fires only when
        // the user taps Activate; purchase_success_shown only on a real success).
        XCTAssertTrue(spy.captures.isEmpty)
    }

    func testKeyDeepLinkNeverOverwritesAnExistingPaidLicense() async {
        // A PAYING user (license A on file) receives a hostile/mistaken link with
        // a DIFFERENT key B. The deep link must neither activate B nor clobber A —
        // it only prefills B for the user to consider; A is left fully intact.
        let existingKey = "AAAA1111-BBBB-2222-CCCC-333344445555"
        let attackerKey = "DEAD0000-BEEF-1111-FACE-222233334444"
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot(existingKey)
        let instanceSlot = InMemoryKeychainSlot("instance-A")
        let service = makeService(transport: transport, keySlot: keySlot, instanceSlot: instanceSlot)
        let store = makeStore(licenseService: service, keySlot: keySlot, productKind: .byok)
        XCTAssertTrue(store.isPaidEntitled) // precondition: already paid

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: attackerKey, productKind: .byok),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .prefilled)
        XCTAssertEqual(store.prefillLicenseKey, attackerKey)
        // Routed to the dedicated activate-key window, never the full paywall, with
        // the paywall + any materialized Settings window dismissed.
        XCTAssertEqual(spy.openedActivateKey, 1)
        XCTAssertEqual(spy.openedPaywall, 0)
        XCTAssertEqual(spy.dismissed, 1)
        XCTAssertEqual(spy.dismissedSettings, 1)
        // The existing license A is untouched: no POST, Keychain still holds A,
        // and the user is still .byok-entitled.
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(keySlot.readResult(), .found(existingKey))
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(spy.captures.isEmpty)
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
        // Already-active is still a success → shows the confirmation. This branch
        // is left exactly as before: the success hosts in the paywall, NOT the new
        // activate-key window (only the fresh-key prefill branch reroutes).
        XCTAssertEqual(store.purchaseSuccess, .byok)
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(spy.openedActivateKey, 0)
        XCTAssertEqual(spy.dismissed, 0)
        XCTAssertEqual(spy.dismissedSettings, 0)
        // E-01: the handler no longer fires `purchase_activated` — a deep link
        // never counts as a purchase outcome. The success SCREEN being shown is
        // still recorded (and this branch isn't spoofable: it requires THIS
        // device's exact active key).
        XCTAssertNil(spy.capturedOutcome)
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
        XCTAssertEqual(spy.dismissedSettings, 0)
        XCTAssertEqual(spy.openedPaywall, 0)
        XCTAssertEqual(spy.openedActivateKey, 0)
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
        // The no-key "brand-new buyer must paste" branch is unchanged: it still
        // opens the full paywall, NOT the dedicated activate-key window.
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(spy.openedActivateKey, 0)
        XCTAssertEqual(spy.dismissedSettings, 0)
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
            "Zerro Cloud is active. 300 credits available, resets Jul 1, 2026."
        )
        XCTAssertEqual(
            PurchaseSuccessInfo.byok.detailLine { _ in "" },
            "Bring-your-own-key is active. Add your provider API key in Settings to start generating."
        )
        XCTAssertEqual(
            PurchaseSuccessInfo.topup(added: 100, total: 220).detailLine { _ in "" },
            "Added 100 credits. 220 total."
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
        XCTAssertEqual(spy.openedActivateKey, 0)
        XCTAssertEqual(spy.dismissed, 0)
        XCTAssertEqual(spy.dismissedSettings, 0)
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
        // `PaywallView.showActivationSuccess` does).
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

    // MARK: - PaywallActivationModel: purchase_activated gating (E-01 Property 3, positive half)

    /// The Activate tap is the SINGLE place `purchase_activated` may fire — and
    /// only for a deep-link-originated key, so the funnel records a real,
    /// user-initiated conversion (the handler itself never emits it). Captures the
    /// analytics through the model's injectable `capture` seam (the global
    /// `Analytics.capture` is a no-op until `Analytics.start()` runs).
    func testPaywallModelDeepLinkSuccessEmitsPurchaseActivated() async {
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let session = StubManagedTransport()
        session.enqueue(#"{"error":"not_entitled"}"#, status: 403) // → BYOK
        let store = makeStore(licenseService: service, keySlot: keySlot, sessionTransport: session)

        var captured: [(event: String, props: [String: Any])] = []
        let model = PaywallActivationModel()
        model.origin = .deeplink
        model.licenseKey = sampleKey
        model.capture = { captured.append((event: $0, props: $1)) }

        let ok = await model.performActivation(using: store)

        XCTAssertTrue(ok)
        XCTAssertEqual(store.state, .byok)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.event, "purchase_activated")
        XCTAssertEqual(captured.first?.props["outcome"] as? String, "success")
        XCTAssertEqual(captured.first?.props["method"] as? String, "deeplink")
        XCTAssertEqual(captured.first?.props["product"] as? String, "byok")
    }

    /// A MANUAL paste emits NO `purchase_activated` (unchanged from before — only
    /// the view's `purchase_success_shown` fires on a manual success). Gating is
    /// strictly on `origin == .deeplink`.
    func testPaywallModelManualPasteSuccessEmitsNoPurchaseActivated() async {
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let session = StubManagedTransport()
        session.enqueue(#"{"error":"not_entitled"}"#, status: 403)
        let store = makeStore(licenseService: service, keySlot: keySlot, sessionTransport: session)

        var captured: [(event: String, props: [String: Any])] = []
        let model = PaywallActivationModel()
        model.origin = .manualPaste // the default; explicit for the contrast
        model.licenseKey = sampleKey
        model.capture = { captured.append((event: $0, props: $1)) }

        let ok = await model.performActivation(using: store)

        XCTAssertTrue(ok)
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(captured.isEmpty, "a manual paste must not emit purchase_activated")
    }

    /// A deep-link activation that FAILS emits `purchase_activated` outcome:failed
    /// (a real, user-initiated attempt that the funnel should record as a loss).
    func testPaywallModelDeepLinkFailureEmitsFailedOutcome() async {
        let transport = LicenseServiceStubTransport(responses: [atLimitResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let store = makeStore(licenseService: service, keySlot: keySlot)

        var captured: [(event: String, props: [String: Any])] = []
        let model = PaywallActivationModel()
        model.origin = .deeplink
        model.licenseKey = sampleKey
        model.capture = { captured.append((event: $0, props: $1)) }

        let ok = await model.performActivation(using: store)

        XCTAssertFalse(ok)
        if case .failed = model.phase {} else { XCTFail("expected a .failed phase") }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.event, "purchase_activated")
        XCTAssertEqual(captured.first?.props["outcome"] as? String, "failed")
        XCTAssertEqual(captured.first?.props["method"] as? String, "deeplink")
    }

    /// Declining the E-01 replace confirmation is a quiet no-op: phase returns to
    /// `.idle`, NOTHING is emitted (a spoofed/mistaken key must never look like a
    /// failed purchase), and the existing license is untouched.
    func testPaywallModelReplaceCancelledEmitsNothingAndReturnsIdle() async {
        let existingKey = "AAAA1111-BBBB-2222-CCCC-333344445555"
        let attackerKey = "DEAD0000-BEEF-1111-FACE-222233334444"
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot(existingKey)
        let instanceSlot = InMemoryKeychainSlot("instance-A")
        let service = makeService(transport: transport, keySlot: keySlot, instanceSlot: instanceSlot, confirmReplace: { false })
        let store = makeStore(licenseService: service, keySlot: keySlot, productKind: .byok)

        var captured: [(event: String, props: [String: Any])] = []
        let model = PaywallActivationModel()
        model.origin = .deeplink
        model.licenseKey = attackerKey
        model.capture = { captured.append((event: $0, props: $1)) }

        let ok = await model.performActivation(using: store)

        XCTAssertFalse(ok)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(captured.isEmpty, "a declined replace must emit no funnel analytics")
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(keySlot.readResult(), .found(existingKey))
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
