//
//  TrialCreditsManager.swift
//  Zerro
//
//  Created by Colin Breeding on 6/2/26.
//
//  Overview
//  --------
//  Phase F — the free trial itself: server-funded trial credits, with NO time
//  limit. The trial is simply a pool of generations (default 15), gated purely
//  on credits remaining. This layer authorizes the server-funded generation for
//  a trial user with NO OpenAI key of their own: the user verifies an EMAIL once
//  (a 6-digit code) and the backend returns a short-lived TRIAL session token +
//  a capped credit grant. Those generations then route through the SAME
//  `ManagedProxyClient` /generate proxy — just with a trial token instead of a
//  subscription one. `EntitlementStore` reads `creditsRemaining` to decide
//  `.trial` (credits remain / not yet granted) vs `.expired` (a confirmed zero).
//
//  Where the credential lives
//  --------------------------
//  • The trial token is PERSISTED to the Keychain (`KeychainStore.trialToken`,
//    encoded `token|epoch`) and reloaded on init — the in-memory `cached` copy is
//    just a fast path; the Keychain is the source of truth. Unlike the Managed
//    session token (silently re-derivable from the stored license key), the trial
//    token's only credential is the emailed code, so it can't be re-minted without
//    user action — it MUST survive a relaunch within its TTL, in particular the
//    SIGKILL macOS issues when Screen Recording is granted DURING onboarding (the
//    email step precedes the screen-recording step), or the just-granted trial
//    would read as unverified the moment the user records. Low-sensitivity (a
//    ≤30-min bearer for capped trial credits); the abuse bound is the server-side
//    per-email grant cap (below), not this token. Once the TTL lapses the token
//    is RESUMED silently in the background (H1): `refreshToken()` POSTs
//    `action:"resume"` with the remembered verified email and the server mints a
//    fresh token against the SAME grant — the user never re-verifies. Email
//    ownership is proven exactly once, ever; the server-side grant persists, so a
//    resume RESUMES the same remaining balance and never hands out fresh credits
//    (verify_trial_grant never resets). Only a genuine first-time user (no
//    remembered email) is sent through the email+code flow.
//  • The verified email is remembered in the Keychain (`KeychainStore.trialEmail`)
//    ONLY to pre-fill the capture sheet later. It is never the spend credential.
//  • `creditsRemaining` is cached in UserDefaults for display (the menu-bar
//    "N trial credits left" line) — display only; the server is the spend
//    authority (every /generate response returns the true remaining).
//
//  Abuse bounding is entirely server-side: the cap is keyed to the verified email
//  (`trial_grants.email_normalized` UNIQUE), so delete+reinstall resumes the same
//  remaining balance and can NOT farm fresh credits — the persisted token is only
//  a short-lived (≤30-min) bearer, never a fresh grant. This server-side per-email
//  cap is the real abuse bound; there is no longer any local time gate.
//
//  Conforms to `ProxyTokenProviding` so `ManagedProxyClient` can drive a trial
//  generation with no special-casing. Networking goes through the injectable
//  `ManagedTransport` (stubbed in tests); the clock is injectable for expiry
//  tests; the email/credits stores are injectable seams.
//

import Foundation
import os

// MARK: - TrialStartError

/// Typed failures of the `/trial-start` request/verify flow, mapped to user copy
/// by the capture sheet. Distinct from `ManagedSessionError` (license↔session)
/// and `ManagedGenerationError` (a single generation) — this is about getting a
/// trial token in the first place.
enum TrialStartError: Error, Equatable {
    /// The address wasn't a valid email (client- or server-side check).
    case invalidEmail
    /// A disposable / throwaway domain the backend refuses to grant credits to.
    case disposableEmail
    /// Rate-limited (`429`) — too many requests for this email/IP. Back off.
    case rateLimited
    /// The backend couldn't send the email (Resend failure). Try again.
    case sendFailed
    /// This email already used its trial (verified + credits exhausted).
    case alreadyUsed
    /// This Mac already used its trial under a DIFFERENT email (device binding).
    /// Distinct from `alreadyUsed` (which is about the email): a NEW email won't
    /// help — the physical machine is burned. Route the user to upgrade.
    case deviceTrialUsed
    /// The entered code didn't match.
    case invalidCode
    /// The code expired before it was entered — request a fresh one.
    case codeExpired
    /// Too many wrong codes against this issue — request a fresh one.
    case tooManyAttempts
    /// Couldn't reach the backend (offline/DNS/timeout). Retryable.
    case network(String)
    /// Backend 5xx / unexpected status.
    case server(status: Int)
    /// Response wasn't the JSON shape we expected.
    case malformedResponse
    /// Couldn't serialize the request body — should be unreachable for the
    /// `[String: String]` payload we send. Fail loud here rather than POSTing
    /// an empty body the backend would reject with a confusing generic error.
    case malformedRequest

    var userMessage: String {
        switch self {
        case .invalidEmail:    return "That doesn\u{2019}t look like a valid email address."
        case .disposableEmail: return "Please use a non-disposable email address."
        case .rateLimited:     return "Too many attempts \u{2014} please wait a bit and try again."
        case .sendFailed:      return "Couldn\u{2019}t send the code \u{2014} please try again."
        case .alreadyUsed:     return "This email has already used its free trial."
        case .deviceTrialUsed: return "This Mac has already used its free trial. Upgrade to keep going."
        case .invalidCode:     return "That code isn\u{2019}t right \u{2014} check it and try again."
        case .codeExpired:     return "That code expired \u{2014} send a new one."
        case .tooManyAttempts: return "Too many incorrect codes \u{2014} send a new one."
        case .network:         return "Couldn\u{2019}t reach Zerro \u{2014} check your connection."
        case .server:          return "Something went wrong \u{2014} please try again."
        case .malformedResponse: return "Unexpected response \u{2014} please try again."
        case .malformedRequest:  return "Something went wrong \u{2014} please try again."
        }
    }
}

// MARK: - TrialCreditsManager

@MainActor
@Observable
final class TrialCreditsManager: ProxyTokenProviding {

    /// Refresh leeway before a token's real expiry, so an in-flight /generate
    /// never races the boundary (mirrors `SessionTokenManager.refreshLeeway`).
    static let refreshLeeway: TimeInterval = 60

    // MARK: - Cached token
    //
    // The token is mirrored to the Keychain (`tokenSlot`) so it SURVIVES an app
    // relaunch within its TTL — critically the SIGKILL macOS issues when Screen
    // Recording is granted during onboarding (which happens AFTER the email
    // step). The in-memory copy is just a fast path; the Keychain is the source
    // of truth that's reloaded on init.

    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }
    @ObservationIgnored private var cached: CachedToken?

    /// Single-flight guard for the silent resume (H1). `refreshToken()` is called
    /// from several places that can race on an expired token (launch preflight,
    /// `validToken()` on a stale cache, the `/generate` 401 retry); concurrent
    /// callers must await ONE resume, not each fire their own.
    @ObservationIgnored private var inFlightResume: Task<String, Error>?

    // MARK: - Dependencies

    private let emailSlot: KeychainSlot
    private let tokenSlot: KeychainSlot
    private let defaults: UserDefaults
    private let transport: ManagedTransport
    private let clock: () -> Date

    private static let creditsKey = "trial_credits_remaining_v1"
    private static let limitKey = "trial_credits_limit_v1"
    private static let grantIdKey = "trial_grant_id_v1"

    // MARK: - Init

    init(
        emailSlot: KeychainSlot? = nil,
        tokenSlot: KeychainSlot? = nil,
        transport: ManagedTransport? = nil,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.emailSlot = emailSlot ?? KeychainStore.trialEmail
        self.tokenSlot = tokenSlot ?? KeychainStore.trialToken
        self.transport = transport ?? URLSessionManagedTransport()
        self.defaults = defaults
        self.clock = clock
        // Reload a persisted token so a relaunch (e.g. the onboarding
        // Screen-Recording SIGKILL) keeps the just-verified trial usable.
        self.cached = Self.loadToken(from: self.tokenSlot)
    }

    // MARK: - Display state

    /// Credits remaining for display, or `nil` if the user has never verified.
    /// Cached so the menu-bar line is correct at launch before any network call.
    var creditsRemaining: Int? {
        defaults.object(forKey: Self.creditsKey) as? Int
    }

    /// The grant TOTAL (E4) — the denominator the trial usage meter draws its
    /// proportional bar against. Cached from the last verify/resume response;
    /// `nil` before verification or against an older server that doesn't send
    /// `trial_credits_limit` (the meter then stays bar-less). Display only.
    var creditsLimit: Int? {
        defaults.object(forKey: Self.limitKey) as? Int
    }

    /// The opaque trial grant id from the last verify/resume, or `nil`. Passed
    /// through checkout custom_data on conversion so the lemonsqueezy-webhook
    /// links this exact grant to the new subscription (the email-normalization
    /// match is the fallback). Cached in UserDefaults so it survives a relaunch
    /// before any resume. Display/handoff only — never a spend credential.
    var trialGrantId: String? {
        defaults.string(forKey: Self.grantIdKey)
    }

    /// The last verified email, for pre-filling the capture sheet. Never used as
    /// a credential.
    var rememberedEmail: String? {
        if case .found(let value) = emailSlot.readResult(), !value.isEmpty { return value }
        return nil
    }

    /// True when a usable (comfortably-unexpired) trial token is cached, i.e. the
    /// user has verified this session and trial generations can route through the
    /// proxy. `EntitlementStore.routesThroughManagedProxy` reads this for `.trial`.
    var hasActiveTrialToken: Bool {
        guard let cached else { return false }
        return cached.expiresAt.timeIntervalSince(clock()) > Self.refreshLeeway
    }

    // MARK: - trial-start flow

    /// Request a verification code be emailed (`action: "request"`). Throws a
    /// typed `TrialStartError` the capture sheet renders.
    func requestCode(email: String) async throws {
        let dto = try await postTrialStart(["action": "request", "email": email])
        if let error = dto.error {
            throw Self.mapError(error, status: nil)
        }
        if dto.status == "device_trial_used" {
            throw TrialStartError.deviceTrialUsed
        }
        if dto.status == "already_used" {
            throw TrialStartError.alreadyUsed
        }
        // status == "code_sent" → nothing to do; the sheet advances to code entry.
    }

    /// Verify a code (`action: "verify"`). On success caches the trial token,
    /// remembers the email, records the credit balance, and returns the credits
    /// remaining. Throws a typed `TrialStartError` otherwise.
    @discardableResult
    func verifyCode(email: String, code: String) async throws -> Int {
        let dto = try await postTrialStart(["action": "verify", "email": email, "code": code])
        if let error = dto.error {
            throw Self.mapError(error, status: nil)
        }
        if dto.status == "device_trial_used" {
            throw TrialStartError.deviceTrialUsed
        }
        if dto.status == "already_used" {
            throw TrialStartError.alreadyUsed
        }
        guard let token = dto.token, let remaining = dto.trialCreditsRemaining else {
            throw TrialStartError.malformedResponse
        }
        let expiresAt = ManagedBackend.parseISODate(dto.expiresAt)
            ?? clock().addingTimeInterval(Self.refreshLeeway)
        let token0 = CachedToken(token: token, expiresAt: expiresAt)
        cached = token0
        persistToken(token0) // survive a relaunch / onboarding SIGKILL
        emailSlot.write(email)
        setCreditsRemaining(remaining)
        setCreditsLimit(dto.trialCreditsLimit)
        setGrantId(dto.trialGrantId)
        Log.billing.notice("trial verified — credits=\(remaining, privacy: .public)")
        return remaining
    }

    // MARK: - ProxyTokenProviding

    /// The cached trial token if it's still comfortably unexpired, otherwise a
    /// silently-resumed one (H1). Mirrors `SessionTokenManager.validToken()`: a
    /// stale cache no longer throws — it attempts a background resume against the
    /// remembered verified email. Only a genuine first-time user (no remembered
    /// email) ends up at `.notEntitled`, which routes to the email-capture flow.
    func validToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(clock()) > Self.refreshLeeway {
            return cached.token
        }
        return try await refreshToken()
    }

    /// Silently re-mint an expired trial token (the H1 fix). Verification is a
    /// PERMANENT server-side fact (the per-email grant), not the liveness of the
    /// ≤30-min token, so an expired token resumes in the background using the
    /// remembered verified email — the user sees nothing. Single-flighted so
    /// concurrent expired-token callers await one `resume`. Throws `.notEntitled`
    /// only when there's no verified email to resume against (first-time user) or
    /// the server reports the grant is gone/exhausted — the caller then routes to
    /// the email+code flow.
    @discardableResult
    func refreshToken() async throws -> String {
        if let inFlight = inFlightResume {
            return try await inFlight.value
        }
        let task = Task { try await self.performResume() }
        inFlightResume = task
        defer { inFlightResume = nil }
        return try await task.value
    }

    /// One resume round-trip: POST `{ action:"resume", email }` and, on a fresh
    /// token, cache + persist it and update the cached balance silently.
    private func performResume() async throws -> String {
        // The remembered email is the resume credential. None on file → never
        // verified → re-verify from scratch (no token to drop).
        guard let email = rememberedEmail else {
            clearStaleToken()
            throw ManagedSessionError.notEntitled
        }

        let dto: TrialStartResponseDTO
        do {
            dto = try await postTrialStart(["action": "resume", "email": email])
        } catch {
            // Treat the server response as untrusted and the call as best-effort:
            // ANY failure (network, 5xx, malformed) drops the stale token and
            // routes to re-verify rather than crashing. With the server-side
            // expires_at guard the success path always carries a valid expiry.
            clearStaleToken()
            throw ManagedSessionError.notEntitled
        }

        // A previously-verified email → fresh token + the persisted balance.
        // Cache, persist (survive relaunch), and proceed silently.
        if let token = dto.token, let remaining = dto.trialCreditsRemaining {
            let expiresAt = ManagedBackend.parseISODate(dto.expiresAt)
                ?? clock().addingTimeInterval(Self.refreshLeeway)
            let token0 = CachedToken(token: token, expiresAt: expiresAt)
            cached = token0
            persistToken(token0) // survive a relaunch
            setCreditsRemaining(remaining)
            setCreditsLimit(dto.trialCreditsLimit)
            setGrantId(dto.trialGrantId)
            Log.billing.notice("trial token resumed silently — credits=\(remaining, privacy: .public)")
            return token0.token
        }

        // `needs_verification` (no grant) / `already_used` / any unexpected shape
        // → drop the stale token and route to re-verify.
        clearStaleToken()
        throw ManagedSessionError.notEntitled
    }

    /// Drop the stale token (memory + Keychain) but KEEP the remembered email and
    /// cached credits — we're routing to re-verify, not forgetting the user.
    private func clearStaleToken() {
        cached = nil
        tokenSlot.delete()
    }

    // MARK: - Credit bookkeeping

    /// Reflect a just-completed generation's `credits_remaining` (display cache).
    func applyCreditsRemaining(_ remaining: Int) {
        setCreditsRemaining(max(0, remaining))
    }

    /// Drop the trial token (memory + Keychain) + cached credits (on definitive
    /// trial revocation / exhaustion / re-verify-needed). The remembered email is
    /// kept for re-fill.
    func clear() {
        cached = nil
        tokenSlot.delete()
        defaults.removeObject(forKey: Self.creditsKey)
        defaults.removeObject(forKey: Self.limitKey)
        defaults.removeObject(forKey: Self.grantIdKey)
    }

    /// FULL reset of all locally-cached verification state — the token (memory +
    /// Keychain), the cached credits, AND the remembered email. Returns the
    /// onboarding email step to its unverified, first-run state. Used by the DEBUG
    /// reset controls; safe because the SERVER grant is the source of truth, so a
    /// later re-verify of the same email resumes the same grant (no refarm).
    func forgetVerification() {
        cached = nil
        tokenSlot.delete()
        defaults.removeObject(forKey: Self.creditsKey)
        defaults.removeObject(forKey: Self.limitKey)
        defaults.removeObject(forKey: Self.grantIdKey)
        emailSlot.delete()
    }

    private func setCreditsRemaining(_ remaining: Int) {
        defaults.set(remaining, forKey: Self.creditsKey)
    }

    /// Persist the grant total when the server sends one; a `nil` (older
    /// server) keeps any previously-cached limit rather than erasing it.
    private func setCreditsLimit(_ limit: Int?) {
        guard let limit else { return }
        defaults.set(limit, forKey: Self.limitKey)
    }

    /// Persist the grant id when the server sends one; a `nil` (older server)
    /// keeps any previously-cached id rather than erasing it.
    private func setGrantId(_ grantId: String?) {
        guard let grantId, !grantId.isEmpty else { return }
        defaults.set(grantId, forKey: Self.grantIdKey)
    }

    // MARK: - Token persistence
    //
    // Encoded as `token|epochSeconds` (a JWT contains no `|`, so the first
    // separator is unambiguous). Low-sensitivity short-lived bearer; see the
    // `KeychainStore.trialToken` header.

    private func persistToken(_ token: CachedToken) {
        let epoch = Int(token.expiresAt.timeIntervalSince1970)
        tokenSlot.write("\(token.token)|\(epoch)")
    }

    private static func loadToken(from slot: KeychainSlot) -> CachedToken? {
        guard case .found(let raw) = slot.readResult(),
              let sep = raw.firstIndex(of: "|") else { return nil }
        let token = String(raw[raw.startIndex..<sep])
        let epochStr = String(raw[raw.index(after: sep)...])
        guard !token.isEmpty, let epoch = TimeInterval(epochStr) else { return nil }
        return CachedToken(token: token, expiresAt: Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Networking

    private func postTrialStart(_ payload: [String: String]) async throws -> TrialStartResponseDTO {
        var request = URLRequest(url: ManagedBackend.trialStartURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Trial device binding: attach the hashed hardware id so the backend can
        // cap one grant per physical Mac. Sent on every action (request/verify
        // carry the cap; resume forwards it for telemetry only). Omitted when the
        // hardware UUID is unreadable (rare) so the backend degrades to the
        // email-only cap rather than the trial failing.
        var body = payload
        if let deviceIdHash = DeviceIdentity.hashedDeviceID() {
            body["device_id_hash"] = deviceIdHash
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw TrialStartError.malformedRequest
        }

        let (data, status): (Data, Int)
        do {
            (data, status) = try await transport.send(request)
        } catch {
            throw TrialStartError.network(error.localizedDescription)
        }

        // Decode the body first — the backend returns a typed `error` string on
        // 4xx so we can map precisely (invalid_code vs code_expired, etc.).
        let dto = try? JSONDecoder().decode(TrialStartResponseDTO.self, from: data)

        switch status {
        case 200...299:
            guard let dto else { throw TrialStartError.malformedResponse }
            return dto
        default:
            // Map via the typed error string when present, else by status.
            throw Self.mapError(dto?.error, status: status)
        }
    }

    /// Map a backend error string (and/or HTTP status) to a `TrialStartError`.
    private static func mapError(_ error: String?, status: Int?) -> TrialStartError {
        switch error {
        case "invalid_email":     return .invalidEmail
        case "disposable_email":  return .disposableEmail
        case "rate_limited":      return .rateLimited
        case "send_failed":       return .sendFailed
        case "invalid_code":      return .invalidCode
        case "code_expired":      return .codeExpired
        case "too_many_attempts": return .tooManyAttempts
        default:
            if let status { return .server(status: status) }
            return .malformedResponse
        }
    }

    // MARK: - Preview / test support

    /// An offline, empty trial manager so SwiftUI previews never hit the backend.
    /// Non-`#if DEBUG` so `#Preview` blocks compile in every configuration.
    static func inMemory() -> TrialCreditsManager {
        TrialCreditsManager(
            emailSlot: InMemoryKeychainSlot(nil),
            tokenSlot: InMemoryKeychainSlot(nil),
            transport: OfflineManagedTransport(),
            defaults: .ephemeralPreview()
        )
    }
}
