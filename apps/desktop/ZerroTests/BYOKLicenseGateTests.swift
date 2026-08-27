//
//  BYOKLicenseGateTests.swift
//  ZerroTests
//
//  The $39 license GATE, pinned as explicit contracts (much of the
//  machinery predates the paid model; these tests assert it holds FOR the
//  paid model and alarms if anyone loosens it):
//
//    1. No valid license (and no active trial) → NEVER `.byok`; the terminal
//       state is `.localTrialExpired`, `canGenerate` is false, and the record
//       gate routes to the paywall. Generation is unreachable without a
//       license or an active trial.
//    2. The fail-open/fail-closed split: NETWORK trouble fails open for a
//       user whose complete cached record is readable and compatible — but
//       the LOCAL record fails closed. A Keychain read failure, missing or
//       malformed metadata, or a wrong product/major never unlocks; only a
//       DEFINITIVE LemonSqueezy negative (disabled/expired) de-activates a
//       verified license.
//    3. License and provider keys are INDEPENDENT requirements: the license
//       gates access (`.byok`), the user's provider keys fund usage (the
//       BYOKRouting chat path + the transcription path). Either missing
//       blocks a generation, by different mechanisms.
//
//  The major-version update boundary is deliberately NOT gated here — a
//  license generates for as long as its major matches; the boundary only
//  constrains which app UPDATES are offered (`UpdateMajorPolicy`).
//

import XCTest
@testable import Zerro

@MainActor
final class BYOKLicenseGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeLicense(present: Bool, readFailure: Bool = false) -> LicenseService {
        let keySlot = InMemoryKeychainSlot(present ? "KEY" : nil)
        let instanceSlot = InMemoryKeychainSlot(present ? "instance" : nil)
        keySlot.simulateReadFailure = readFailure
        instanceSlot.simulateReadFailure = readFailure
        return LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            licensedProductIDSlot: InMemoryKeychainSlot(present ? "7" : nil),
            licensedMajorSlot: InMemoryKeychainSlot(present ? "1" : nil),
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: OfflineLicenseTransport()
        )
    }

    /// A trial clock that started `daysAgo` days back (relative to a fixed
    /// `now`), so tests can pin an active or elapsed trial deterministically.
    private func makeClock(daysAgo: Int) -> TrialManager {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return TrialManager(
            startDateSlot: InMemoryKeychainSlot(String(Int(start.timeIntervalSince1970))),
            maxDateSeenSlot: InMemoryKeychainSlot(),
            clock: { now }
        )
    }

    /// No trial clock → the unlicensed branch lands on the gated state.
    private func makeStore(license: LicenseService, trialManager: TrialManager? = nil) -> EntitlementStore {
        EntitlementStore(enforcementMode: .official, licenseService: license, trialManager: trialManager)
    }

    // MARK: - 1. No license → BYOK unreachable

    func testNoLicenseNeverYieldsByok() {
        // No license, no clock → gated.
        let gated = makeStore(license: makeLicense(present: false))
        XCTAssertEqual(gated.state, .localTrialExpired)
        XCTAssertFalse(gated.canGenerate, "no license + no trial → record blocked (paywall)")

        // No license, elapsed clock → gated.
        let elapsed = makeStore(license: makeLicense(present: false), trialManager: makeClock(daysAgo: TrialManager.trialLengthDays + 3))
        XCTAssertEqual(elapsed.state, .localTrialExpired)
        XCTAssertFalse(elapsed.canGenerate)

        // No license, active clock → the trial grants, but it is NOT `.byok`.
        let active = makeStore(license: makeLicense(present: false), trialManager: makeClock(daysAgo: 2))
        guard case .localTrial = active.state else {
            return XCTFail("expected .localTrial, got \(active.state)")
        }
        XCTAssertNotEqual(active.state, .byok)
        XCTAssertTrue(active.canGenerate)
    }

    func testDeactivationDropsOutOfByokImmediately() async throws {
        // An activated user who deactivates this device loses `.byok` the
        // moment the local license clears — with no trial underneath, the
        // very next record attempt is paywalled.
        let keySlot = InMemoryKeychainSlot("KEY")
        let instanceSlot = InMemoryKeychainSlot("instance")
        let license = LicenseService(
            licenseKeySlot: keySlot,
            instanceIDSlot: instanceSlot,
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            licensedProductIDSlot: InMemoryKeychainSlot("7"),
            licensedMajorSlot: InMemoryKeychainSlot("1"),
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: StubLicenseTransport(bodies: [#"{"deactivated": true}"#])
        )
        let store = makeStore(license: license)
        XCTAssertEqual(store.state, .byok)

        try await store.deactivateThisDevice()
        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    // MARK: - 2. Local reads fail CLOSED; only definitive negatives revoke

    func testKeychainReadFailureNeverGrantsByok() {
        // A read failure is `.indeterminate` — an UNVERIFIABLE record. It
        // must fail closed: with no trial underneath, the store lands on
        // `.localTrialExpired` (blocked), never `.byok`. (The condition is
        // transient; a later successful read restores the license.)
        let store = makeStore(license: makeLicense(present: true, readFailure: true))
        XCTAssertNotEqual(store.state, .byok)
        XCTAssertEqual(store.state, .localTrialExpired)
        XCTAssertFalse(store.canGenerate)
    }

    func testOnlyDefinitiveLSNegativesRevoke() {
        // The validate verdict that clears a license: ONLY valid:false with
        // disabled/expired (refund/chargeback/expiry). `inactive` (slot freed
        // elsewhere), unknown status, or a bare valid:false all FAIL OPEN.
        XCTAssertTrue(ValidationResult(valid: false, status: .disabled, productApproved: true).isDefinitiveRevocation)
        XCTAssertTrue(ValidationResult(valid: false, status: .expired, productApproved: true).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: false, status: .inactive, productApproved: true).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: false, status: nil, productApproved: false).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: false, status: .active, productApproved: true).isDefinitiveRevocation)
        XCTAssertFalse(ValidationResult(valid: true, status: .active, productApproved: true).isDefinitiveRevocation)
    }

    // MARK: - 3. License AND provider keys — independent requirements

    func testLicenseGatesAccessKeysFundUsage() {
        // Keys without a license: the gate never opens — state is gated
        // regardless of what's in the key slots (provider keys are not an
        // entitlement).
        let unlicensed = makeStore(license: makeLicense(present: false))
        XCTAssertFalse(unlicensed.canGenerate)

        // License without keys: the gate opens (.byok), but the generation
        // itself fails closed at the chat-key check — the routing returns nil
        // with no provider keys, which the pipeline maps to missingAPIKey →
        // the .apiKeyMissing pill; the pre-flight catches it first. Both
        // requirements hold.
        let licensed = makeStore(license: makeLicense(present: true))
        XCTAssertEqual(licensed.state, .byok)
        XCTAssertTrue(licensed.canGenerate)
        XCTAssertEqual(licensed.preflightBlock(canGenerateLocally: false), .apiKeyMissing)
        XCTAssertNil(
            BYOKRouting.effectiveEntry(selectedModelID: ModelRegistry.defaultModelID, availableProviders: []),
            "a licensed user with no provider keys must still fail closed at generation"
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
