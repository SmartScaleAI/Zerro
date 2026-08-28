//
//  CheckoutReturnTests.swift
//  ZerroTests
//
//  Coverage for the `zerro://checkout-complete` deep link. Two layers:
//    • `CheckoutReturn.parse` — pure parsing of the query (key extraction +
//      sanitization; any product hint is ignored). No AppKit, no network.
//    • `AppDelegate.resolveCheckoutReturn` — the side-effecting resolution, with
//      injected `CheckoutReturnEffects` spies so app-foreground / paywall /
//      analytics calls are observed without driving real AppKit. The entitlement
//      layer is fully stubbed (in-memory Keychain + canned LemonSqueezy JSON),
//      so these are deterministic.
//
//  Outcomes under test: a key on the link is PREFILLED, never auto-activated
//  (E-01); an already-active key is success WITHOUT re-POSTing; the no-key
//  path refreshes silently or opens the paywall; a cold-launch deep link
//  buffers + replays; a COMMUNITY build ignores the link as a complete
//  no-op (no storage, network, analytics, field mutation, or window effect).
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
        productSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        majorSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(),
        confirmReplace: @escaping () async -> Bool = { true }
    ) -> LicenseService {
        LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(),
            licensedProductIDSlot: productSlot,
            licensedMajorSlot: majorSlot,
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: transport,
            clock: { Date() },
            instanceNameProvider: { "TestMac-DEADBEEF" },
            confirmReplace: confirmReplace
        )
    }

    /// Seeded slots for a CONFIRMED compatible license (test policy: product 7,
    /// major 1) — the "already licensed" fixtures.
    private func compatibleSlots() -> (product: InMemoryKeychainSlot, major: InMemoryKeychainSlot) {
        (InMemoryKeychainSlot("7"), InMemoryKeychainSlot("1"))
    }

    private func makeStore(
        licenseService: LicenseService,
        keySlot: InMemoryKeychainSlot
    ) -> EntitlementStore {
        EntitlementStore(enforcementMode: .official, licenseService: licenseService)
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// A LemonSqueezy `/activate` success body for the approved product.
    private func activatedResponse() -> (Data, Int) {
        (data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_X" }, "meta": { "product_id": 7 } }"#), 200)
    }

    /// A LemonSqueezy `/activate` at-limit refusal (the failure path).
    private func atLimitResponse() -> (Data, Int) {
        (data("""
        {
          "activated": false,
          "error": "This license key has reached the activation limit.",
          "license_key": { "status": "active", "activation_limit": 2, "activation_usage": 2 },
          "instance": null
        }
        """), 400)
    }

    private let sampleKey = "38B12ACB-19EA-4D77-A38C-1234567890AB"

    // MARK: - Parsing

    func testParseExtractsKey() {
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)")!
        XCTAssertEqual(CheckoutReturn.parse(url)?.licenseKey, sampleKey)
    }

    func testParseIgnoresProductHint() {
        // Older links carry a `product` hint. It's untrusted external input
        // and the store sells one product — the parse keeps only the key.
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)&product=subscription_pro")!
        let parsed = CheckoutReturn.parse(url)
        XCTAssertEqual(parsed, CheckoutReturn(licenseKey: sampleKey))
    }

    func testParseMissingKey() {
        let parsed = CheckoutReturn.parse(URL(string: "zerro://checkout-complete")!)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.licenseKey)
    }

    func testParseNonCheckoutHostReturnsNil() {
        XCTAssertNil(CheckoutReturn.parse(URL(string: "zerro://something-else?license_key=\(sampleKey)")!))
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
            CheckoutReturn(licenseKey: sampleKey),
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
        XCTAssertEqual(store.state, .localTrialExpired, "state must NOT change from a deep link")
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
        let slots = compatibleSlots()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            productSlot: slots.product,
            majorSlot: slots.major
        )
        let store = makeStore(licenseService: service, keySlot: keySlot)
        XCTAssertTrue(store.isPaidEntitled) // precondition: already paid

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: attackerKey),
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
        // Seed a present, edition-confirmed license whose key equals the
        // deep-link key → the store is already `.byok` (paid-entitled).
        let transport = LicenseServiceStubTransport(responses: [])
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let instanceSlot = InMemoryKeychainSlot("instance")
        let slots = compatibleSlots()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            productSlot: slots.product,
            majorSlot: slots.major
        )
        let store = makeStore(licenseService: service, keySlot: keySlot)
        XCTAssertTrue(store.isPaidEntitled)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: sampleKey),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .alreadyActive)
        // No re-activation: the LemonSqueezy /activate endpoint was never hit.
        XCTAssertEqual(transport.callCount, 0)
        // Already-active is still a success → shows the confirmation, hosted in
        // the paywall (only the fresh-key prefill branch reroutes to the
        // activate-key window).
        XCTAssertEqual(store.purchaseSuccess, .license)
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
        XCTAssertEqual(spy.successShown?.plan, "license")
        XCTAssertNil(store.prefillLicenseKey)
    }

    // MARK: - No-key path

    func testNoKeyEntitledRefreshesSilently() async {
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let slots = compatibleSlots()
        let service = makeService(
            transport: LicenseServiceStubTransport(responses: []),
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("instance"),
            productSlot: slots.product,
            majorSlot: slots.major
        )
        let store = makeStore(licenseService: service, keySlot: keySlot)

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: nil),
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
            CheckoutReturn(licenseKey: nil),
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

    // MARK: - Community builds ignore the link entirely

    /// A `KeychainSlot` that records every access so the community no-op can
    /// prove it never touched license or trial storage.
    private final class RecordingKeychainSlot: KeychainSlot {
        private(set) var reads = 0
        private(set) var writes = 0
        private(set) var deletes = 0
        private var value: String?

        init(_ initialValue: String? = nil) { self.value = initialValue }

        func readResult() -> KeychainReadResult {
            reads += 1
            if let value { return .found(value) }
            return .absent
        }
        func write(_ value: String) { writes += 1; self.value = value }
        func delete() { deletes += 1; value = nil }

        var wasNeverTouched: Bool { reads == 0 && writes == 0 && deletes == 0 }
    }

    /// A `LicenseTransport` that records every request; any request at all is
    /// a failure for the community no-op.
    private final class RecordingLicenseTransport: LicenseTransport {
        private(set) var requests: [String] = []

        func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
            requests.append(path)
            return (Data(#"{ "valid": true, "license_key": { "status": "active" }, "meta": { "product_id": 7 } }"#.utf8), 200)
        }
    }

    /// A community store over recording license + trial slots and a recording
    /// transport. The license on file is a COMPLETE compatible record with a
    /// stale validation stamp, so an OFFICIAL store over the same doubles would
    /// refresh, match the key, and re-validate — proving the spies can see
    /// activity when it happens.
    private struct CommunityDoubles {
        let key: RecordingKeychainSlot
        let instance = RecordingKeychainSlot("instance")
        let lastValidated = RecordingKeychainSlot(
            String(Int(Date().addingTimeInterval(-LicenseService.revalidationInterval - 60).timeIntervalSince1970))
        )
        let product = RecordingKeychainSlot("7")
        let major = RecordingKeychainSlot("1")
        let trialStart = RecordingKeychainSlot()
        let trialMaxSeen = RecordingKeychainSlot()
        let transport = RecordingLicenseTransport()

        init(keyOnFile: String) { key = RecordingKeychainSlot(keyOnFile) }

        var allSlots: [RecordingKeychainSlot] { [key, instance, lastValidated, product, major, trialStart, trialMaxSeen] }

        func store(_ mode: EntitlementEnforcementMode) -> EntitlementStore {
            let license = LicenseService(
                licenseKeySlot: key,
                instanceIDSlot: instance,
                lastValidatedSlot: lastValidated,
                licensedProductIDSlot: product,
                licensedMajorSlot: major,
                policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
                transport: transport,
                clock: { Date() },
                instanceNameProvider: { "TestMac-DEADBEEF" },
                confirmReplace: { true }
            )
            let clock = TrialManager(startDateSlot: trialStart, maxDateSeenSlot: trialMaxSeen, clock: { Date() })
            return EntitlementStore(enforcementMode: mode, licenseService: license, trialManager: clock)
        }
    }

    /// Resolves `parsed` against a community store and asserts the COMPLETE
    /// no-op contract: `.ignoredCommunity`, no window effect of any kind, no
    /// analytics, every entitlement UI field left exactly as seeded, and no
    /// license/trial storage access or license request after construction.
    private func assertCommunityIgnores(_ parsed: CheckoutReturn, file: StaticString = #filePath, line: UInt = #line) async {
        let doubles = CommunityDoubles(keyOnFile: sampleKey)
        let store = doubles.store(.community)
        // Construction in community mode touches nothing (proved separately by
        // CommunityLicensingPolicyTests); pin that precondition so any access
        // counted below is attributable to the resolver alone.
        XCTAssertTrue(doubles.allSlots.allSatisfy(\.wasNeverTouched), "precondition: community construction touches no slot", file: file, line: line)
        XCTAssertTrue(doubles.transport.requests.isEmpty, "precondition: community construction sends nothing", file: file, line: line)

        // Seed every entitlement UI field with a distinctive value so "unchanged"
        // is a real assertion rather than nil == nil.
        store.paywallTrigger = .voluntaryUpgrade
        store.focusActivationFieldOnOpen = false
        store.prefillLicenseKey = "SEEDED-PREFILL"
        store.purchaseSuccess = nil
        let stateBefore = store.state

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(parsed, entitlements: store, effects: spy.make())

        XCTAssertEqual(outcome, .ignoredCommunity, file: file, line: line)
        XCTAssertEqual(spy.openedPaywall, 0, "community must never open the Paywall window", file: file, line: line)
        XCTAssertEqual(spy.openedActivateKey, 0, "community must never open the Activate Key window", file: file, line: line)
        XCTAssertEqual(spy.broughtForward, 0, file: file, line: line)
        XCTAssertEqual(spy.dismissed, 0, file: file, line: line)
        XCTAssertEqual(spy.dismissedSettings, 0, file: file, line: line)
        XCTAssertTrue(spy.captures.isEmpty, "no analytics event may be captured", file: file, line: line)

        XCTAssertEqual(store.paywallTrigger, .voluntaryUpgrade, "paywallTrigger must be unchanged", file: file, line: line)
        XCTAssertFalse(store.focusActivationFieldOnOpen, "focusActivationFieldOnOpen must be unchanged", file: file, line: line)
        XCTAssertEqual(store.prefillLicenseKey, "SEEDED-PREFILL", "prefillLicenseKey must be unchanged", file: file, line: line)
        XCTAssertNil(store.purchaseSuccess, "purchaseSuccess must be unchanged", file: file, line: line)
        XCTAssertEqual(store.state, stateBefore, file: file, line: line)

        XCTAssertTrue(doubles.allSlots.allSatisfy(\.wasNeverTouched), "license and trial storage must be untouched", file: file, line: line)
        XCTAssertTrue(doubles.transport.requests.isEmpty, "the license transport must receive no request", file: file, line: line)
    }

    func testCommunityIgnoresCheckoutReturnWithKey() async {
        // Even the exact key on file — the shape an official build treats as
        // `.alreadyActive` — is ignored outright by a community build.
        await assertCommunityIgnores(CheckoutReturn(licenseKey: sampleKey))
    }

    func testCommunityIgnoresCheckoutReturnWithoutKey() async {
        await assertCommunityIgnores(CheckoutReturn(licenseKey: nil))
    }

    func testOfficialStoreOverTheSameDoublesStillActs() async {
        // Control: the recording doubles DO observe activity when licensing is
        // enforced, so the community assertions above are not vacuous. The
        // same key on file → `.alreadyActive`, storage read, success shown.
        let doubles = CommunityDoubles(keyOnFile: sampleKey)
        let store = doubles.store(.official)
        XCTAssertFalse(doubles.key.wasNeverTouched, "official construction reads the license")

        let spy = EffectsSpy()
        let outcome = await AppDelegate.resolveCheckoutReturn(
            CheckoutReturn(licenseKey: sampleKey),
            entitlements: store,
            effects: spy.make()
        )

        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertEqual(spy.openedPaywall, 1)
        XCTAssertEqual(store.purchaseSuccess, .license)
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
        let url = URL(string: "zerro://checkout-complete?license_key=\(sampleKey)")!
        AppDelegate.handleCheckoutReturn(url)
        XCTAssertEqual(AppDelegate.pendingCheckoutURL, url)

        // Wiring runs: the store is set and the buffered URL is replayed + cleared.
        let keySlot = InMemoryKeychainSlot(sampleKey)
        let slots = compatibleSlots()
        let service = makeService(
            transport: LicenseServiceStubTransport(responses: []),
            keySlot: keySlot,
            instanceSlot: InMemoryKeychainSlot("instance"),
            productSlot: slots.product,
            majorSlot: slots.major
        )
        let store = makeStore(licenseService: service, keySlot: keySlot)
        AppDelegate.entitlements = store
        AppDelegate.replayPendingCheckoutURLIfNeeded()
        XCTAssertNil(AppDelegate.pendingCheckoutURL)
        // Keep `store` alive past the weak `AppDelegate.entitlements` assignment
        // for the duration of the replayed resolution.
        withExtendedLifetime(store) {}
    }

    // MARK: - PurchaseSuccessInfo derivation + copy

    func testPurchaseSuccessDerivationFromState() {
        XCTAssertEqual(PurchaseSuccessInfo.fromActivatedState(.byok), .license)
        // Non-licensed states have nothing to confirm.
        XCTAssertNil(PurchaseSuccessInfo.fromActivatedState(.localTrialExpired))
        XCTAssertNil(PurchaseSuccessInfo.fromActivatedState(.localTrial(daysRemaining: 3)))
    }

    func testSuccessDetailAndAnalyticsCopy() {
        XCTAssertEqual(
            PurchaseSuccessInfo.license.detailLine,
            "Your Zerro license is active. Add your provider API key in Settings to start generating."
        )
        XCTAssertEqual(PurchaseSuccessInfo.license.analyticsPlan, "license")
    }

    // MARK: - Manual paste routes through purchaseSuccess; dismiss clears it

    func testManualPasteDerivesPurchaseSuccessAndDismissClears() async {
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let store = makeStore(licenseService: service, keySlot: keySlot)

        // The manual-paste card activates through the SAME store entry point,
        // then derives the confirmation from the resulting state (what
        // `PaywallView.showActivationSuccess` does).
        try? await store.activate(licenseKey: sampleKey)
        XCTAssertEqual(store.state, .byok)
        let info = PurchaseSuccessInfo.fromActivatedState(store.state)
        XCTAssertEqual(info, .license)
        store.purchaseSuccess = info
        XCTAssertEqual(store.purchaseSuccess, .license)

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
        let store = makeStore(licenseService: service, keySlot: keySlot)

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
        XCTAssertEqual(captured.first?.props["product"] as? String, "license")
    }

    /// A MANUAL paste emits NO `purchase_activated` (unchanged from before — only
    /// the view's `purchase_success_shown` fires on a manual success). Gating is
    /// strictly on `origin == .deeplink`.
    func testPaywallModelManualPasteSuccessEmitsNoPurchaseActivated() async {
        let transport = LicenseServiceStubTransport(responses: [activatedResponse()])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let store = makeStore(licenseService: service, keySlot: keySlot)

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

    /// A deep-link key for the WRONG product fails with the specific copy — the
    /// user sees exactly why their key didn't take.
    func testPaywallModelWrongProductShowsSpecificCopy() async {
        let wrongProduct = (data(#"{ "activated": true, "license_key": { "status": "active" }, "instance": { "id": "inst_W" }, "meta": { "product_id": 999 } }"#), 200)
        let transport = LicenseServiceStubTransport(responses: [wrongProduct])
        let keySlot = InMemoryKeychainSlot()
        let service = makeService(transport: transport, keySlot: keySlot)
        let store = makeStore(licenseService: service, keySlot: keySlot)

        let model = PaywallActivationModel()
        model.licenseKey = sampleKey

        let ok = await model.performActivation(using: store)

        XCTAssertFalse(ok)
        XCTAssertEqual(
            model.phase,
            .failed(
                message: "This license key is for a different Zerro product or version.",
                showManageDevices: false
            )
        )
        XCTAssertEqual(keySlot.readResult(), .absent, "a wrong-product key is never persisted")
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
        let slots = compatibleSlots()
        let service = makeService(
            transport: transport,
            keySlot: keySlot,
            instanceSlot: instanceSlot,
            productSlot: slots.product,
            majorSlot: slots.major,
            confirmReplace: { false }
        )
        let store = makeStore(licenseService: service, keySlot: keySlot)

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
