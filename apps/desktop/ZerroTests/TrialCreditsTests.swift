//
//  TrialCreditsTests.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/2/26.
//
//  Phase F — coverage for the server-funded trial-credits layer:
//    • TrialCreditsManager: request/verify flow over the stubbed transport, the
//      in-memory token (validToken / hasActiveTrialToken), credit caching, and
//      the typed-error mapping.
//    • EntitlementStore: the `generationRoute` decision (the unverified trial
//      user → email capture, not a silent failure), `routesThroughManagedProxy`
//      for a trial with a token, and the DUAL expiry (clock OR credits).
//    • ManagedProxyClient: a trial token rides through the SAME /generate proxy.
//  All dependencies are in-memory / stubbed — no Keychain, no network.
//

import CoreMedia
import XCTest
@testable import Zerro

// MARK: - Trial fixtures

private enum TrialFixtures {
    static func codeSent() -> String { #"{"status":"code_sent"}"# }
    static func alreadyUsed() -> String { #"{"status":"already_used"}"# }
    static func verifyOK(token: String = "TRIAL-TOK", remaining: Int = 15) -> String {
        #"{"token":"\#(token)","expires_at":"2030-01-01T00:00:00.000Z","trial_credits_remaining":\#(remaining)}"#
    }
    static func error(_ code: String) -> String { #"{"error":"\#(code)"}"# }
}

private func makeTrialManager(
    _ transport: StubManagedTransport,
    tokenSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(nil),
    emailSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(nil),
    defaults: UserDefaults? = nil
) -> TrialCreditsManager {
    TrialCreditsManager(
        emailSlot: emailSlot,
        tokenSlot: tokenSlot,
        transport: transport,
        defaults: defaults ?? .ephemeralPreview()
    )
}

// MARK: - TrialCreditsManager

@MainActor
final class TrialCreditsManagerTests: XCTestCase {

    func testRequestCodeSucceeds() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.codeSent(), status: 200)
        let mgr = makeTrialManager(transport)

        try await mgr.requestCode(email: "user@example.com")
        // One POST to /trial-start with action=request.
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url, ManagedBackend.trialStartURL)
        let body = try XCTUnwrap(transport.requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "request")
        XCTAssertEqual(json["email"] as? String, "user@example.com")
    }

    func testRequestCodeAlreadyUsedThrows() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.alreadyUsed(), status: 200)
        let mgr = makeTrialManager(transport)
        await assertTrialThrows(.alreadyUsed) { try await mgr.requestCode(email: "a@b.com") }
    }

    func testRequestCodeDisposableMapped() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.error("disposable_email"), status: 422)
        let mgr = makeTrialManager(transport)
        await assertTrialThrows(.disposableEmail) { try await mgr.requestCode(email: "a@mailinator.com") }
    }

    func testVerifyStoresTokenAndCredits() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(token: "TRIAL-TOK", remaining: 15), status: 200)
        let mgr = makeTrialManager(transport)

        // Before verifying: no token, no credits.
        XCTAssertFalse(mgr.hasActiveTrialToken)
        XCTAssertNil(mgr.creditsRemaining)

        let remaining = try await mgr.verifyCode(email: "user@example.com", code: "123456")
        XCTAssertEqual(remaining, 15)

        // Token cached + usable, credits + email remembered.
        XCTAssertTrue(mgr.hasActiveTrialToken)
        XCTAssertEqual(mgr.creditsRemaining, 15)
        XCTAssertEqual(mgr.rememberedEmail, "user@example.com")
        let token = try await mgr.validToken()
        XCTAssertEqual(token, "TRIAL-TOK")
    }

    func testVerifyInvalidCodeMapped() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.error("invalid_code"), status: 400)
        let mgr = makeTrialManager(transport)
        await assertTrialThrows(.invalidCode) { _ = try await mgr.verifyCode(email: "a@b.com", code: "000000") }
        XCTAssertFalse(mgr.hasActiveTrialToken)
    }

    func testVerifyAlreadyUsedThrows() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.alreadyUsed(), status: 200)
        let mgr = makeTrialManager(transport)
        await assertTrialThrows(.alreadyUsed) { _ = try await mgr.verifyCode(email: "a@b.com", code: "123456") }
    }

    func testValidTokenThrowsWithoutVerification() async {
        let mgr = makeTrialManager(StubManagedTransport())
        do {
            _ = try await mgr.validToken()
            XCTFail("expected notEntitled")
        } catch let error as ManagedSessionError {
            XCTAssertEqual(error, .notEntitled)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testClearDropsTokenAndCredits() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(), status: 200)
        let mgr = makeTrialManager(transport)
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")
        XCTAssertTrue(mgr.hasActiveTrialToken)

        mgr.clear()
        XCTAssertFalse(mgr.hasActiveTrialToken)
        XCTAssertNil(mgr.creditsRemaining)
        // `clear` keeps the remembered email (for re-fill on revocation).
        XCTAssertEqual(mgr.rememberedEmail, "a@b.com")
    }

    func testTokenSurvivesRelaunch() async throws {
        // Regression: the trial token must survive an app relaunch within its TTL
        // — specifically the SIGKILL macOS issues when Screen Recording is granted
        // during onboarding (the email step runs BEFORE the screen-recording step).
        // Otherwise the just-verified trial reads as unverified ("verify your
        // email") the moment the user records. Shared Keychain slots simulate the
        // same device across the relaunch.
        let tokenSlot = InMemoryKeychainSlot(nil)
        let emailSlot = InMemoryKeychainSlot(nil)
        let defaults = UserDefaults.ephemeralPreview()

        // Session 1: verify → token cached + PERSISTED.
        let t1 = StubManagedTransport()
        t1.enqueue(TrialFixtures.verifyOK(token: "TOK", remaining: 15), status: 200)
        let mgr1 = makeTrialManager(t1, tokenSlot: tokenSlot, emailSlot: emailSlot, defaults: defaults)
        _ = try await mgr1.verifyCode(email: "a@b.com", code: "123456")
        XCTAssertTrue(mgr1.hasActiveTrialToken)

        // Session 2: a FRESH manager over the SAME slots (in-memory cache empty,
        // as after a relaunch) must reload the persisted token.
        let mgr2 = makeTrialManager(StubManagedTransport(), tokenSlot: tokenSlot, emailSlot: emailSlot, defaults: defaults)
        XCTAssertTrue(mgr2.hasActiveTrialToken)
        let token = try await mgr2.validToken()
        XCTAssertEqual(token, "TOK")
    }

    func testForgetVerificationClearsPersistedToken() async throws {
        let tokenSlot = InMemoryKeychainSlot(nil)
        let t1 = StubManagedTransport()
        t1.enqueue(TrialFixtures.verifyOK(token: "TOK", remaining: 15), status: 200)
        let mgr1 = makeTrialManager(t1, tokenSlot: tokenSlot)
        _ = try await mgr1.verifyCode(email: "a@b.com", code: "123456")
        mgr1.forgetVerification()

        // A fresh manager over the same slot must NOT reload a token.
        let mgr2 = makeTrialManager(StubManagedTransport(), tokenSlot: tokenSlot)
        XCTAssertFalse(mgr2.hasActiveTrialToken)
    }

    func testForgetVerificationClearsTokenCreditsAndEmail() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(token: "T", remaining: 10), status: 200)
        let mgr = makeTrialManager(transport)
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")
        XCTAssertTrue(mgr.hasActiveTrialToken)
        XCTAssertEqual(mgr.creditsRemaining, 10)
        XCTAssertEqual(mgr.rememberedEmail, "a@b.com")

        // FULL reset (DEBUG "Reset Onboarding" / "Reset Trial Email") wipes the
        // remembered email too, so nothing locally reads as verified.
        mgr.forgetVerification()
        XCTAssertFalse(mgr.hasActiveTrialToken)
        XCTAssertNil(mgr.creditsRemaining)
        XCTAssertNil(mgr.rememberedEmail)
    }

    private func assertTrialThrows(
        _ expected: TrialStartError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as TrialStartError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

// MARK: - EntitlementStore trial routing + dual expiry

@MainActor
final class EntitlementStoreTrialTests: XCTestCase {

    /// A store on an ACTIVE trial clock (no license), with the given trial layer.
    private func trialStore(_ trial: TrialCreditsManager, startedDaysAgo: Int = 1) -> EntitlementStore {
        EntitlementStore(
            trialManager: .inMemory(startedDaysAgo: startedDaysAgo),
            licenseService: .inMemory(),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(nil),
            trialCredits: trial,
            defaults: .ephemeralPreview()
        )
    }

    private func verifiedManager(remaining: Int = 15) async throws -> TrialCreditsManager {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(remaining: remaining), status: 200)
        let mgr = makeTrialManager(transport)
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")
        return mgr
    }

    // MARK: generationRoute

    func testUnverifiedTrialRoutesToEmailCapture() {
        // Fresh trial layer (no token, no key) → the capture sheet, NOT a silent
        // failure or a local path that would fail with apiKeyMissing.
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        XCTAssertEqual(store.generationRoute(hasOwnAPIKey: false), .trialNeedsEmail)
    }

    func testTrialWithOwnKeyRoutesLocal() {
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        XCTAssertEqual(store.generationRoute(hasOwnAPIKey: true), .local)
    }

    func testVerifiedTrialRoutesToProxy() async throws {
        let mgr = try await verifiedManager()
        let store = trialStore(mgr)
        XCTAssertEqual(store.generationRoute(hasOwnAPIKey: false), .trialProxy)
        XCTAssertTrue(store.routesThroughManagedProxy)
    }

    func testUnverifiedTrialDoesNotRouteThroughProxy() {
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        XCTAssertFalse(store.routesThroughManagedProxy) // no token yet
    }

    // MARK: display

    func testVerifiedTrialStateCarriesCredits() async throws {
        let mgr = try await verifiedManager(remaining: 9)
        let store = trialStore(mgr)
        store.refresh()
        guard case .trial(_, let credits) = store.state else {
            return XCTFail("expected .trial, got \(store.state)")
        }
        XCTAssertEqual(credits, 9)
    }

    func testUnverifiedTrialStateHasNilCredits() {
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        guard case .trial(_, let credits) = store.state else {
            return XCTFail("expected .trial, got \(store.state)")
        }
        XCTAssertNil(credits)
    }

    // MARK: needs-verification affordance (Settings/Billing + banner)

    func testUnverifiedTrialNeedsEmailVerification() {
        // No remembered email, no cached credits → the persistent "verify your
        // email" affordance should show.
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        XCTAssertTrue(store.needsTrialEmailVerification)
    }

    func testVerifiedTrialDoesNotNeedVerification() async throws {
        let mgr = try await verifiedManager(remaining: 12)
        let store = trialStore(mgr)
        store.refresh()
        XCTAssertFalse(store.needsTrialEmailVerification) // credits + email on file
    }

    func testNonTrialNeverNeedsVerification() async throws {
        // A verified-but-now-expired-clock store is .expired, not .trial.
        let mgr = try await verifiedManager(remaining: 5)
        let expired = trialStore(mgr, startedDaysAgo: 30)
        XCTAssertEqual(expired.state, .expired)
        XCTAssertFalse(expired.needsTrialEmailVerification)
    }

    #if DEBUG
    func testDevResetTrialVerificationReturnsStoreToUnverified() async throws {
        // A verified trial store does NOT need verification...
        let mgr = try await verifiedManager(remaining: 8)
        let store = trialStore(mgr)
        store.refresh()
        XCTAssertFalse(store.needsTrialEmailVerification)

        // ...but a DEBUG reset (used by "Reset Onboarding") wipes the local cache
        // so the email step is unverified again — local cache is never proof.
        store.devResetTrialVerification()
        XCTAssertTrue(store.needsTrialEmailVerification)
        XCTAssertFalse(store.routesThroughManagedProxy) // token gone too
    }
    #endif

    // MARK: dual expiry (clock OR credits)

    func testExhaustedCreditsExpireEvenWithLiveClock() {
        // Active clock, but credits cached at 0 → trial is over (Layer 2).
        let mgr = makeTrialManager(StubManagedTransport())
        mgr.applyCreditsRemaining(0) // exhausted, no token needed
        let store = trialStore(mgr, startedDaysAgo: 1) // clock still live
        XCTAssertEqual(store.state, .expired)
        XCTAssertFalse(store.canGenerate)
    }

    func testApplyTrialCreditsRemainingFlipsToExpiredAtZero() async throws {
        let mgr = try await verifiedManager(remaining: 1)
        let store = trialStore(mgr)
        store.refresh()
        guard case .trial = store.state else { return XCTFail("expected .trial") }

        // Spend the last credit → entitlement recomputes to .expired.
        store.applyTrialCreditsRemaining(0)
        XCTAssertEqual(store.state, .expired)
    }

    func testExpiredClockStillExpiredRegardlessOfCredits() async throws {
        let mgr = try await verifiedManager(remaining: 15) // has credits
        let store = trialStore(mgr, startedDaysAgo: 30)     // clock long expired
        XCTAssertEqual(store.state, .expired)
    }
}

// MARK: - ManagedProxyClient with a trial token

@MainActor
final class TrialProxyRoutingTests: XCTestCase {

    func testTrialTokenRidesThroughTheProxy() async throws {
        // Verify a trial token via the trial manager's transport...
        let trialTransport = StubManagedTransport()
        trialTransport.enqueue(TrialFixtures.verifyOK(token: "TRIAL-XYZ", remaining: 15), status: 200)
        let trial = makeTrialManager(trialTransport)
        _ = try await trial.verifyCode(email: "a@b.com", code: "123456")

        // ...then drive the SAME proxy with the trial token provider.
        let genTransport = StubManagedTransport()
        genTransport.enqueue(ManagedFixtures.generateJSON(prompt: "Trial prompt.", creditsRemaining: 14), status: 200)
        // The proxy's default session manager is unused on this path.
        let proxy = ManagedProxyClient(sessionTokens: .inMemory(), transport: genTransport)

        let result = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: [ExtractedFrame(url: ManagedFixtures.tempFile(), timestamp: .zero, index: 0)],
            mode: .instruct,
            durationSeconds: 5,
            tokenProvider: trial
        )

        XCTAssertEqual(result.result.prompt, "Trial prompt.")
        XCTAssertEqual(result.creditsRemaining, 14)
        // The /generate request carried the TRIAL token, never a subscription one.
        XCTAssertEqual(genTransport.requests.count, 1)
        XCTAssertEqual(genTransport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer TRIAL-XYZ")
    }
}
