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
//      for a trial with a token, and the credit-only expiry (the trial is
//      `.expired` exactly when its server-funded credits hit zero — no clock).
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
    /// Trial device binding: this Mac already trialed under a different email.
    static func deviceTrialUsed() -> String { #"{"status":"device_trial_used"}"# }
    /// A `verify`/`resume` success body. The same shape covers both actions, so
    /// `expiresAt` is parameterized for the TTL-gap tests (resume returns a token
    /// whose expiry is in the future of the ADVANCED clock). `limit` is the E4
    /// grant total (`trial_credits_limit`); `nil` omits the field, modeling an
    /// older server — the default, so pre-E4 tests double as backward-compat
    /// coverage.
    static func verifyOK(
        token: String = "TRIAL-TOK",
        remaining: Int = 15,
        limit: Int? = nil,
        grantId: String? = nil,
        expiresAt: String = "2030-01-01T00:00:00.000Z"
    ) -> String {
        let limitField = limit.map { #","trial_credits_limit":\#($0)"# } ?? ""
        let grantField = grantId.map { #","trial_grant_id":"\#($0)""# } ?? ""
        return #"{"token":"\#(token)","expires_at":"\#(expiresAt)","trial_credits_remaining":\#(remaining)\#(limitField)\#(grantField)}"#
    }
    /// The resume "first-time user" signal — no token, route to email+code.
    static func needsVerification() -> String { #"{"status":"needs_verification"}"# }
    static func error(_ code: String) -> String { #"{"error":"\#(code)"}"# }
}

/// A mutable clock the test can advance after a manager is constructed, to
/// simulate an away-gap that outlives the trial token's TTL.
private final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// ISO-8601 (with fractional seconds, matching JS `Date.toISOString()`) so the
/// fixture's `expires_at` round-trips through `ManagedBackend.parseISODate`.
private func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func makeTrialManager(
    _ transport: StubManagedTransport,
    tokenSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(nil),
    emailSlot: InMemoryKeychainSlot = InMemoryKeychainSlot(nil),
    defaults: UserDefaults? = nil,
    clock: @escaping () -> Date = { Date() }
) -> TrialCreditsManager {
    TrialCreditsManager(
        emailSlot: emailSlot,
        tokenSlot: tokenSlot,
        transport: transport,
        defaults: defaults ?? .ephemeralPreview(),
        clock: clock
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

    // MARK: - Trial device binding

    func testRequestInjectsDeviceIdHash() async throws {
        // Every /trial-start POST carries the hashed hardware id so the backend
        // can cap one grant per physical Mac. The hash must match DeviceIdentity
        // and be a well-formed 64-char SHA-256 hex digest.
        let deviceHash = try XCTUnwrap(
            DeviceIdentity.hashedDeviceID(),
            "hardware UUID should be readable in the test host"
        )
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.codeSent(), status: 200)
        let mgr = makeTrialManager(transport)

        try await mgr.requestCode(email: "user@example.com")
        let body = try XCTUnwrap(transport.requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["device_id_hash"] as? String, deviceHash)
        XCTAssertEqual(deviceHash.count, 64)
        XCTAssertTrue(deviceHash.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    func testRequestDeviceTrialUsedThrows() async {
        // This Mac already trialed under a different email → distinct typed error
        // (NOT alreadyUsed: a new email won't help).
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.deviceTrialUsed(), status: 200)
        let mgr = makeTrialManager(transport)
        await assertTrialThrows(.deviceTrialUsed) { try await mgr.requestCode(email: "fresh@b.com") }
    }

    func testVerifyDeviceTrialUsedThrows() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.deviceTrialUsed(), status: 200)
        let mgr = makeTrialManager(transport)
        await assertTrialThrows(.deviceTrialUsed) { _ = try await mgr.verifyCode(email: "fresh@b.com", code: "123456") }
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

    func testVerifyDecodesAndCachesCreditsLimit() async throws {
        // E4: `trial_credits_limit` (the grant total) is decoded from the verify
        // response and cached, so the trial usage meter has a bar denominator.
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(remaining: 34, limit: 40), status: 200)
        let mgr = makeTrialManager(transport)

        XCTAssertNil(mgr.creditsLimit)
        _ = try await mgr.verifyCode(email: "user@example.com", code: "123456")
        XCTAssertEqual(mgr.creditsRemaining, 34)
        XCTAssertEqual(mgr.creditsLimit, 40)
    }

    func testVerifyCachesTrialGrantIdForCheckout() async throws {
        // The grant id is returned by verify and cached so the conversion checkout
        // can pass it through custom_data (exact trial↔subscription link).
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(grantId: "grant-uuid-1"), status: 200)
        let mgr = makeTrialManager(transport)

        XCTAssertNil(mgr.trialGrantId)
        _ = try await mgr.verifyCode(email: "user@example.com", code: "123456")
        XCTAssertEqual(mgr.trialGrantId, "grant-uuid-1")
    }

    func testVerifyWithoutGrantIdLeavesItNil() async throws {
        // Backward-compat: an older server omits trial_grant_id; conversion then
        // falls back to the server-side email-normalization match.
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(), status: 200) // no grantId
        let mgr = makeTrialManager(transport)

        _ = try await mgr.verifyCode(email: "user@example.com", code: "123456")
        XCTAssertNil(mgr.trialGrantId)
    }

    func testClearRemovesCachedTrialGrantId() async throws {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(grantId: "grant-uuid-1"), status: 200)
        let mgr = makeTrialManager(transport)
        _ = try await mgr.verifyCode(email: "user@example.com", code: "123456")
        XCTAssertEqual(mgr.trialGrantId, "grant-uuid-1")

        mgr.clear()
        XCTAssertNil(mgr.trialGrantId)
    }

    func testVerifyWithoutCreditsLimitStaysBarless() async throws {
        // Backward-compat (E4): an older server omits `trial_credits_limit` —
        // the verify still succeeds and the limit stays nil (bar-less meter),
        // never a decode failure.
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.verifyOK(remaining: 15), status: 200)
        let mgr = makeTrialManager(transport)

        _ = try await mgr.verifyCode(email: "user@example.com", code: "123456")
        XCTAssertEqual(mgr.creditsRemaining, 15)
        XCTAssertNil(mgr.creditsLimit)
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
        transport.enqueue(TrialFixtures.verifyOK(limit: 40), status: 200)
        let mgr = makeTrialManager(transport)
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")
        XCTAssertTrue(mgr.hasActiveTrialToken)

        mgr.clear()
        XCTAssertFalse(mgr.hasActiveTrialToken)
        XCTAssertNil(mgr.creditsRemaining)
        XCTAssertNil(mgr.creditsLimit)
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

    // MARK: - H1: silent token resume

    /// A verified manager whose cached token has gone stale after an away-gap
    /// longer than the token TTL — the exact condition that used to force a full
    /// re-verify. `transport` should have a `verify` then a `resume` response
    /// queued; the returned clock box is already advanced past the TTL.
    private func staleVerifiedManager(
        _ transport: StubManagedTransport,
        remaining: Int = 15
    ) async throws -> (mgr: TrialCreditsManager, base: Date) {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let nowBox = ClockBox(base)
        let mgr = makeTrialManager(transport, clock: { nowBox.now })
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")
        XCTAssertTrue(mgr.hasActiveTrialToken)
        // A day-long gap — far past the 30-min token TTL.
        nowBox.now = base.addingTimeInterval(86_400)
        XCTAssertFalse(mgr.hasActiveTrialToken)
        return (mgr, base)
    }

    func testRefreshTokenSilentlyResumesForVerifiedEmail() async throws {
        // The bug's absence: a TTL-length away-gap must NOT force re-verification —
        // refreshToken() resumes silently against the remembered email.
        let transport = StubManagedTransport()
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        transport.enqueue(
            TrialFixtures.verifyOK(token: "TOK1", remaining: 15, expiresAt: isoString(base.addingTimeInterval(1800))),
            status: 200
        )
        // The resumed token is valid for 30 min past the ADVANCED clock.
        transport.enqueue(
            TrialFixtures.verifyOK(token: "TOK2", remaining: 11, limit: 40, expiresAt: isoString(base.addingTimeInterval(86_400 + 1800))),
            status: 200
        )
        let (mgr, _) = try await staleVerifiedManager(transport)

        let token = try await mgr.validToken() // stale → silent resume
        XCTAssertEqual(token, "TOK2")
        XCTAssertTrue(mgr.hasActiveTrialToken)
        XCTAssertEqual(mgr.creditsRemaining, 11)         // persisted balance, not 15
        XCTAssertEqual(mgr.creditsLimit, 40)             // E4: limit cached from resume too
        XCTAssertEqual(mgr.rememberedEmail, "a@b.com")   // unchanged
        // The second POST was a `resume` (no code), not a re-verify.
        let body = try XCTUnwrap(transport.requests[1].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "resume")
        XCTAssertNil(json["code"])
    }

    func testRefreshTokenWithoutVerifiedEmailThrowsNotEntitled() async {
        // A genuine first-time user (no remembered email) has nothing to resume
        // against → notEntitled, which routes to the email+code capture flow. No
        // network call is made.
        let transport = StubManagedTransport()
        let mgr = makeTrialManager(transport)
        do {
            _ = try await mgr.refreshToken()
            XCTFail("expected notEntitled")
        } catch let error as ManagedSessionError {
            XCTAssertEqual(error, .notEntitled)
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testRefreshTokenNeedsVerificationDropsTokenAndReVerifies() async throws {
        // Server says the grant is gone (needs_verification) → drop the stale
        // token and surface notEntitled (re-verify), keeping the remembered email.
        let transport = StubManagedTransport()
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        transport.enqueue(
            TrialFixtures.verifyOK(token: "TOK1", remaining: 15, expiresAt: isoString(base.addingTimeInterval(1800))),
            status: 200
        )
        transport.enqueue(TrialFixtures.needsVerification(), status: 200)
        let (mgr, _) = try await staleVerifiedManager(transport)

        do {
            _ = try await mgr.validToken()
            XCTFail("expected notEntitled")
        } catch let error as ManagedSessionError {
            XCTAssertEqual(error, .notEntitled)
        }
        XCTAssertFalse(mgr.hasActiveTrialToken)
        XCTAssertEqual(mgr.rememberedEmail, "a@b.com") // email kept for re-fill
    }

    func testConcurrentRefreshSingleFlightsOneResume() async throws {
        // Two concurrent expired-token callers must trigger exactly ONE resume.
        // Only one resume response is queued; a second network call would hit the
        // empty `{}` fallback and fail to produce a token.
        let transport = StubManagedTransport()
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        transport.enqueue(
            TrialFixtures.verifyOK(token: "TOK1", remaining: 9, expiresAt: isoString(base.addingTimeInterval(1800))),
            status: 200
        )
        transport.enqueue(
            TrialFixtures.verifyOK(token: "TOK2", remaining: 9, expiresAt: isoString(base.addingTimeInterval(86_400 + 1800))),
            status: 200
        )
        let (mgr, _) = try await staleVerifiedManager(transport)

        async let a = mgr.refreshToken()
        async let b = mgr.refreshToken()
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra, "TOK2")
        XCTAssertEqual(rb, "TOK2")
        // verify + exactly one resume == 2 requests total (no thundering herd).
        XCTAssertEqual(transport.requests.count, 2)
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

// MARK: - Trial email presentation + continuation

@MainActor
final class TrialEmailPresentationTests: XCTestCase {

    func testTerminalStatesKeepEmailAndDeviceCopyDistinct() {
        let emailState = TrialEmailTerminalState(TrialStartError.alreadyUsed)
        let deviceState = TrialEmailTerminalState(TrialStartError.deviceTrialUsed)

        XCTAssertEqual(emailState, .emailAlreadyUsed)
        XCTAssertEqual(deviceState, .deviceAlreadyUsed)
        XCTAssertEqual(emailState?.headline, "Trial already used")
        XCTAssertEqual(deviceState?.headline, "Trial already used")
        XCTAssertTrue(emailState?.message.contains("This email") == true)
        XCTAssertTrue(deviceState?.message.contains("This Mac") == true)
    }

    func testStandaloneRequestRendersAlreadyUsedAsTerminalState() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.alreadyUsed(), status: 200)
        let manager = makeTrialManager(transport)
        let model = TrialEmailModel()
        model.email = "a@b.com"

        model.sendCode(using: manager)
        await waitForModel(model)

        XCTAssertEqual(model.phase, .terminal(.emailAlreadyUsed))
        XCTAssertEqual(model.terminalState, .emailAlreadyUsed)
        XCTAssertEqual(model.step, .email)
    }

    func testStandaloneRequestRendersDeviceUsedAsTerminalState() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.deviceTrialUsed(), status: 200)
        let manager = makeTrialManager(transport)
        let model = TrialEmailModel()
        model.email = "second@b.com"

        model.sendCode(using: manager)
        await waitForModel(model)

        XCTAssertEqual(model.phase, .terminal(.deviceAlreadyUsed))
        XCTAssertEqual(model.terminalState, .deviceAlreadyUsed)
    }

    func testStandaloneVerifyRendersExhaustedEmailAsTerminalState() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.alreadyUsed(), status: 200)
        let manager = makeTrialManager(transport)
        let model = TrialEmailModel()
        model.step = .code
        model.email = "a@b.com"
        model.code = "123456"
        var didVerify = false

        model.verify(using: manager) { didVerify = true }
        await waitForModel(model)

        XCTAssertEqual(model.phase, .terminal(.emailAlreadyUsed))
        XCTAssertFalse(didVerify)
        XCTAssertNil(manager.rememberedEmail)
        XCTAssertFalse(manager.hasActiveTrialToken)
        XCTAssertNil(manager.creditsRemaining)
    }

    func testAcceptedRequestAdvancesToNonDefinitiveDeliveryCopy() async {
        let transport = StubManagedTransport()
        transport.enqueue(TrialFixtures.codeSent(), status: 200)
        let manager = makeTrialManager(transport)
        let model = TrialEmailModel()
        model.email = "user@example.com"

        model.sendCode(using: manager)
        await waitForModel(model)

        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.phase, .idle)
        let copy = TrialEmailCopy.codeDelivery(to: model.trimmedEmail)
        XCTAssertTrue(copy.hasPrefix("Check user@example.com"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("we sent"))
    }

    func testContinueWithoutTrialAdvancesAndPersistsNoTrialState() {
        let onboarding = OnboardingState(defaults: .ephemeralPreview())
        onboarding.jump(to: .email)
        let manager = makeTrialManager(StubManagedTransport())
        var capturedEvent: String?
        var capturedProperties: [String: Any] = [:]

        TrialEmailNoCodeContinuation.perform(
            on: onboarding,
            capture: {
                capturedEvent = $0
                capturedProperties = $1
            }
        )

        XCTAssertEqual(onboarding.currentStep, .permissions)
        XCTAssertEqual(capturedEvent, "trial_verification_skipped")
        XCTAssertEqual(capturedProperties["reason"] as? String, "code_not_received")
        XCTAssertEqual(capturedProperties["surface"] as? String, "onboarding")
        XCTAssertNil(manager.rememberedEmail)
        XCTAssertFalse(manager.hasActiveTrialToken)
        XCTAssertNil(manager.creditsRemaining)
        XCTAssertNil(manager.trialGrantId)
    }

    private func waitForModel(
        _ model: TrialEmailModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !model.isWorking { return }
            await Task.yield()
        }
        XCTFail("TrialEmailModel did not settle", file: file, line: line)
    }
}

// MARK: - EntitlementStore trial routing + dual expiry

@MainActor
final class EntitlementStoreTrialTests: XCTestCase {

    /// A store on the free trial (no license), backed by the given trial layer.
    /// Trial standing is now decided purely by that layer's credit balance.
    private func trialStore(_ trial: TrialCreditsManager) -> EntitlementStore {
        EntitlementStore(
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
        XCTAssertEqual(store.generationRoute(canGenerateLocally: false), .trialNeedsEmail)
    }

    func testTrialWithOwnKeyRoutesLocal() {
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        XCTAssertEqual(store.generationRoute(canGenerateLocally: true), .local)
    }

    func testVerifiedTrialRoutesToProxy() async throws {
        let mgr = try await verifiedManager()
        let store = trialStore(mgr)
        XCTAssertEqual(store.generationRoute(canGenerateLocally: false), .trialProxy)
        XCTAssertTrue(store.routesThroughManagedProxy)
    }

    func testUnverifiedTrialDoesNotRouteThroughProxy() {
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        XCTAssertFalse(store.routesThroughManagedProxy) // no token yet
    }

    func testExpiredTokenButVerifiedEmailRoutesToProxyNotEmail() async throws {
        // H1 decouple: an expired token with a verified email on record resumes
        // silently — so the route is the proxy (which resumes), NOT the first-time
        // email capture, and the "verify your email" affordance stays hidden.
        let transport = StubManagedTransport()
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        transport.enqueue(
            TrialFixtures.verifyOK(token: "TOK1", remaining: 10, expiresAt: isoString(base.addingTimeInterval(1800))),
            status: 200
        )
        let nowBox = ClockBox(base)
        let mgr = makeTrialManager(transport, clock: { nowBox.now })
        _ = try await mgr.verifyCode(email: "a@b.com", code: "123456")
        nowBox.now = base.addingTimeInterval(86_400) // gap > TTL
        XCTAssertFalse(mgr.hasActiveTrialToken)

        let store = trialStore(mgr)
        XCTAssertEqual(store.generationRoute(canGenerateLocally: false), .trialProxy)
        XCTAssertFalse(store.needsTrialEmailVerification)
    }

    // MARK: display

    func testVerifiedTrialStateCarriesCredits() async throws {
        let mgr = try await verifiedManager(remaining: 9)
        let store = trialStore(mgr)
        store.refresh()
        guard case .trial(let credits) = store.state else {
            return XCTFail("expected .trial, got \(store.state)")
        }
        XCTAssertEqual(credits, 9)
    }

    func testUnverifiedTrialStateHasNilCredits() {
        let store = trialStore(makeTrialManager(StubManagedTransport()))
        guard case .trial(let credits) = store.state else {
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
        // A verified store whose credits are exhausted is .expired, not .trial —
        // so the verify affordance stays hidden (nothing left to verify into).
        let mgr = try await verifiedManager(remaining: 5)
        mgr.applyCreditsRemaining(0)
        let expired = trialStore(mgr)
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

    // MARK: credit-only expiry (the trial ends exactly when credits hit zero)

    func testExhaustedCreditsExpire() {
        // Credits cached at 0 → the trial is over. No clock, no token needed.
        let mgr = makeTrialManager(StubManagedTransport())
        mgr.applyCreditsRemaining(0) // exhausted
        let store = trialStore(mgr)
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

    func testPositiveCreditsStayTrialWithNoTimeLimit() async throws {
        // The whole point of the refactor: a trial with credits is `.trial`
        // regardless of how much time has passed (there is no time concept).
        let mgr = try await verifiedManager(remaining: 15)
        let store = trialStore(mgr)
        store.refresh()
        guard case .trial(let credits) = store.state else {
            return XCTFail("expected .trial, got \(store.state)")
        }
        XCTAssertEqual(credits, 15)
        XCTAssertTrue(store.canGenerate)
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
            durationSeconds: 5,
            tokenProvider: trial
        )

        XCTAssertEqual(result.result.prompt, "Trial prompt.")
        XCTAssertEqual(result.creditsRemaining, 14)
        // The /generate request carried the TRIAL token, never a subscription one.
        XCTAssertEqual(genTransport.requests.count, 1)
        XCTAssertEqual(genTransport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer TRIAL-XYZ")
    }

    func testVerifiedUserKeepsGeneratingAfterTTLGap() async throws {
        // The exact regression H1 fixes: a verified user with credits, after an
        // away-gap LONGER than the token TTL (sleep / overnight / vacation),
        // generates with NO re-verification — the token resumes silently and the
        // generation draws from the SAME server-side balance.
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let nowBox = ClockBox(base)
        let trialTransport = StubManagedTransport()
        // verify → token good for 30 min from base.
        trialTransport.enqueue(
            TrialFixtures.verifyOK(token: "TOK1", remaining: 12, expiresAt: isoString(base.addingTimeInterval(1800))),
            status: 200
        )
        // resume → fresh token good for 30 min past the ADVANCED clock.
        trialTransport.enqueue(
            TrialFixtures.verifyOK(token: "TOK2", remaining: 12, expiresAt: isoString(base.addingTimeInterval(86_400 + 1800))),
            status: 200
        )
        let trial = makeTrialManager(trialTransport, clock: { nowBox.now })
        _ = try await trial.verifyCode(email: "a@b.com", code: "123456")

        // Long away-gap → the cached token is stale.
        nowBox.now = base.addingTimeInterval(86_400)
        XCTAssertFalse(trial.hasActiveTrialToken)

        // A generation now silently resumes the token, then proceeds.
        let genTransport = StubManagedTransport()
        genTransport.enqueue(ManagedFixtures.generateJSON(prompt: "After the gap.", creditsRemaining: 11), status: 200)
        let proxy = ManagedProxyClient(sessionTokens: .inMemory(), transport: genTransport)

        let result = try await proxy.generate(
            audioURL: ManagedFixtures.tempFile(),
            frames: [ExtractedFrame(url: ManagedFixtures.tempFile(), timestamp: .zero, index: 0)],
            durationSeconds: 5,
            tokenProvider: trial
        )

        XCTAssertEqual(result.result.prompt, "After the gap.")
        XCTAssertEqual(result.creditsRemaining, 11) // drew from the same balance
        // The /generate call carried the RESUMED token, not the stale one.
        XCTAssertEqual(genTransport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer TOK2")
        // verify + exactly one resume — no re-verify round-trip.
        XCTAssertEqual(trialTransport.requests.count, 2)
    }
}

// MARK: - DeviceIdentity (trial device binding)

final class DeviceIdentityTests: XCTestCase {

    func testHashedDeviceIDIsStableNonNil64Hex() throws {
        // On a real Mac (the test host) the platform UUID is readable, so the hash
        // is a non-nil, 64-char lowercase-hex SHA-256 digest...
        let a = try XCTUnwrap(DeviceIdentity.hashedDeviceID(), "platform UUID should be readable on the test host")
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(a, a.lowercased())
        // ...and stable across calls within the process (memoized hardware read).
        XCTAssertEqual(DeviceIdentity.hashedDeviceID(), a)
    }

    func testHashedDeviceIDNeverLeaksTheRawUUID() throws {
        // The hash must not be the raw IOPlatformUUID, which is upper-case with
        // dashes (e.g. "XXXXXXXX-XXXX-..."). A 64-hex digest contains neither.
        let hash = try XCTUnwrap(DeviceIdentity.hashedDeviceID())
        XCTAssertFalse(hash.contains("-"))
        XCTAssertEqual(hash, hash.lowercased())
    }
}
