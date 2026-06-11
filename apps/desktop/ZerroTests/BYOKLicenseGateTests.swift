//
//  BYOKLicenseGateTests.swift
//  ZerroTests
//
//  Phase 6 sub-task E — the $69 BYOK license GATE, pinned as explicit
//  contracts (much of the machinery predates the paid model; these tests
//  assert it holds FOR the paid model and alarms if anyone loosens it):
//
//    1. No valid BYOK license (and no Managed sub / no trial credits) →
//       NEVER `.byok`; the terminal state is `.expired`, `canGenerate` is
//       false, and the record gate routes to the paywall. A BYOK generation
//       is unreachable without a license.
//    2. Fail-open is the deliberate paid-model behavior: an ACTIVATED user
//       is never locked out by a flaky network / Keychain read — only a
//       DEFINITIVE LemonSqueezy negative (disabled/expired) de-activates.
//    3. License and provider keys are INDEPENDENT requirements: the license
//       gates access (`.byok`), the user's provider keys fund usage (the
//       BYOKRouting chat path + the OpenAI/Whisper STT key). Either missing
//       blocks a generation, by different mechanisms.
//
//  The "1 year of updates" window is deliberately NOT gated here — an
//  out-of-window license still generates; the window only constrains app
//  UPDATES (open design item, flagged in the sub-task E review notes).
//

import XCTest
@testable import Zerro

@MainActor
final class BYOKLicenseGateTests: XCTestCase {

    // MARK: - Helpers (mirror EntitlementStoreManagedTests' in-memory stack)

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
        trialCredits: TrialCreditsManager? = nil
    ) -> EntitlementStore {
        EntitlementStore(
            licenseService: license,
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.byok.rawValue),
            trialCredits: trialCredits,
            defaults: .ephemeralPreview()
        )
    }

    private func trialCredits(remaining: Int) -> TrialCreditsManager {
        let mgr = TrialCreditsManager.inMemory()
        mgr.applyCreditsRemaining(remaining)
        return mgr
    }

    // MARK: - 1. No license → BYOK unreachable

    func testNoLicenseNeverYieldsByok() {
        // Across every trial-credit shape, an absent license must never
        // compute to `.byok` — the only paths left are trial or expired.
        let exhausted = makeStore(license: makeLicense(present: false), trialCredits: trialCredits(remaining: 0))
        XCTAssertEqual(exhausted.state, .expired)
        XCTAssertFalse(exhausted.canGenerate, "no license + no credits → record blocked (paywall)")

        let activeTrial = makeStore(license: makeLicense(present: false), trialCredits: trialCredits(remaining: 12))
        guard case .trial = activeTrial.state else {
            return XCTFail("expected .trial, got \(activeTrial.state)")
        }
        // A trial user without their own key NEVER routes to the local BYOK
        // path (here: a fresh unverified trial → the email-capture flow; with
        // a live token it would be .trialProxy — server credits either way).
        // The only license-free way onto .local is trial-on-own-OpenAI-key,
        // which spends THEIR provider money, not a license entitlement.
        XCTAssertNotEqual(activeTrial.generationRoute(hasOwnAPIKey: false), .local)

        let neverGranted = makeStore(license: makeLicense(present: false), trialCredits: nil)
        XCTAssertNotEqual(neverGranted.state, .byok)
    }

    func testDeactivationDropsOutOfByokImmediately() async throws {
        // An activated user who deactivates this device loses `.byok` the
        // moment the local license clears — with exhausted trial credits
        // underneath, the very next record attempt is paywalled.
        let keySlot = InMemoryKeychainSlot("KEY")
        let instanceSlot = InMemoryKeychainSlot("instance")
        let license = LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            transport: StubLicenseTransport(bodies: [#"{"deactivated": true}"#])
        )
        let store = makeStore(license: license, trialCredits: trialCredits(remaining: 0))
        XCTAssertEqual(store.state, .byok)

        try await store.deactivateThisDevice()
        XCTAssertEqual(store.state, .expired)
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - 2. Fail-open for a PAID license (deliberate)

    func testActivatedUserSurvivesTransientKeychainFailure() {
        // A read failure is `.indeterminate`, which grants BYOK (fail OPEN) —
        // a $69 payer is never locked out by a flaky local read.
        let store = makeStore(
            license: makeLicense(present: true, readFailure: true),
            trialCredits: trialCredits(remaining: 0)
        )
        XCTAssertEqual(store.state, .byok)
        XCTAssertTrue(store.canGenerate)
    }

    func testOnlyDefinitiveLSNegativesRevoke() {
        // The validate verdict that clears a license: ONLY valid:false with
        // disabled/expired (refund/chargeback/expiry). `inactive` (slot freed
        // elsewhere), unknown status, or a bare valid:false all FAIL OPEN.
        XCTAssertTrue(ValidationResult(valid: false, status: .disabled).isDefinitiveRevocation)
        XCTAssertTrue(ValidationResult(valid: false, status: .expired).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: false, status: .inactive).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: false, status: nil).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: false, status: .active).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: true, status: .active).isDefinitiveRevocation)
    }

    // MARK: - 3. License AND provider keys — independent requirements

    func testLicenseGatesAccessKeysFundUsage() {
        // Keys without a license: the gate never reaches the BYOK path —
        // state is .expired regardless of what's in the key slots (provider
        // keys are not an entitlement).
        let unlicensed = makeStore(license: makeLicense(present: false), trialCredits: trialCredits(remaining: 0))
        XCTAssertFalse(unlicensed.canGenerate)

        // License without keys: the gate opens (.byok → .local route), but
        // the generation itself fails closed at the chat-key check — the
        // routing returns nil with no provider keys, which the pipeline maps
        // to missingAPIKey → the .apiKeyMissing pill. Both requirements hold.
        let licensed = makeStore(license: makeLicense(present: true), trialCredits: trialCredits(remaining: 0))
        XCTAssertEqual(licensed.state, .byok)
        XCTAssertEqual(licensed.generationRoute(hasOwnAPIKey: false), .local)
        XCTAssertNil(
            BYOKRouting.effectiveEntry(selectedModelID: ModelRegistry.defaultModelID, availableProviders: []),
            "a licensed BYOK user with no provider keys must still fail closed at generation"
        )
    }
}

// MARK: - Stub transport (deactivate happy path)

/// Serves canned JSON bodies in order with HTTP 200 — just enough for the
/// deactivate round-trip above. (`OfflineLicenseTransport`, the app target's
/// always-throwing stub, covers the no-network paths.)
private final class StubLicenseTransport: LicenseTransport {
    private var bodies: [String]

    init(bodies: [String]) {
        self.bodies = bodies
    }

    func post(path: String, parameters: [String: String]) async throws -> (Data, Int) {
        let body = bodies.isEmpty ? "{}" : bodies.removeFirst()
        return (Data(body.utf8), 200)
    }
}
