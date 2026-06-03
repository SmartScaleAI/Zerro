//
//  ManagedBackend.swift
//  Zerro
//
//  Created by Colin Breeding on 6/2/26.
//
//  Overview
//  --------
//  Phase E of the billing system — the shared config + wire shapes for the
//  Managed (Zerro-hosted credits) backend. This is the app's half of the
//  Supabase Edge Functions stood up in Phase D (D1 session/entitlement +
//  D2 generate proxy); it adds NO backend, only the Swift types that talk to
//  the three already-deployed endpoints.
//
//  Three endpoints (base URL is NOT a secret — it ships in the binary; the
//  trust boundary is the server, never the client, see billing-plan §6.1):
//    • POST /session     { license_key } → { token, expires_at, entitlement }
//    • POST /generate    Bearer <token> + { mode, audio, frames } → { prompt, … }
//    • GET  /entitlement Bearer <token> → entitlement snapshot (display only)
//
//  The raw license key rides ONLY to /session (exchanged there for a short-
//  lived JWT, §6.3); /generate and /entitlement see the Bearer token, never
//  the key. That split is enforced by `SessionTokenManager` owning the key
//  and `ManagedProxyClient` only ever seeing tokens.
//
//  Networking goes through the injectable `ManagedTransport` so the unit
//  tests stub every endpoint with canned JSON + status codes, never touching
//  the real backend (mirrors `LicenseTransport` from Phase C).
//

import Foundation

// MARK: - ManagedBackend

/// Non-secret configuration for the Managed backend. The function base URL is
/// a public constant (the security model never trusts the client; see §6.1),
/// kept in one place so a future project move is a single-line change.
enum ManagedBackend {

    /// Supabase Edge Functions base. NOT a secret — anyone can call these;
    /// the server enforces auth + credits regardless of who calls.
    static let functionsBaseURLString = "https://wjxqmurgwyxwkezncxke.supabase.co/functions/v1"

    static let baseURL = URL(string: functionsBaseURLString)!

    static var sessionURL: URL { baseURL.appendingPathComponent("session") }
    static var generateURL: URL { baseURL.appendingPathComponent("generate") }
    static var entitlementURL: URL { baseURL.appendingPathComponent("entitlement") }
    /// Phase F — the email-gated trial-credits endpoint (request + verify code).
    static var trialStartURL: URL { baseURL.appendingPathComponent("trial-start") }

    /// MIME the app declares for the isolated `audio.m4a`. Must be one of the
    /// backend's `ALLOWED_AUDIO_MIME` (`audio/mp4` / `audio/m4a` / `audio/x-m4a`,
    /// see `supabase/functions/generate/config.ts`).
    static let audioMime = "audio/m4a"
    /// Filename the backend logs/uses for the upload (it re-derives the real
    /// container itself). Must end `.m4a` to satisfy the fuse's default.
    static let audioFilename = "recording.m4a"
    /// Frame MIME — the only one the backend accepts (`ALLOWED_FRAME_MIME`).
    static let frameMime = "image/jpeg"

    /// Lenient ISO-8601 parse for the backend's `expires_at` / `reset_date`
    /// fields, which come from JS `Date.toISOString()` — i.e. WITH fractional
    /// seconds and a trailing `Z` (e.g. `2026-06-01T12:03:00.000Z`). The two
    /// formatters cover the with/without-fractional shapes; returns `nil` for
    /// anything unparseable (a `null` reset_date is a legitimate absence).
    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = isoFractional.date(from: raw) { return d }
        return isoPlain.date(from: raw)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - ManagedStatus

/// The subscription status the backend reports (`EntitlementSnapshot.status`).
/// `pastDue` is the dunning state (§9.1): the user keeps generating on
/// remaining credits and we show a quiet "update your card" nudge — it is NOT
/// a gate. `cancelled`/`expired` are terminal — the entitlement layer drops
/// such a user out of `.managed`.
enum ManagedStatus: String, Codable, Equatable {
    case active
    case pastDue = "past_due"
    case cancelled
    case expired

    /// Whether a session/entitlement carrying this status should still be
    /// treated as a live Managed subscriber. `active` + `pastDue` keep
    /// working (§9.1); the terminal states do not.
    var isLive: Bool {
        switch self {
        case .active, .pastDue: return true
        case .cancelled, .expired: return false
        }
    }
}

// MARK: - ManagedEntitlementSnapshot

/// The display-only entitlement snapshot the app caches and renders against
/// (menu-bar credits line, Billing readout, past-due nudge). NEVER the spend
/// authority — `generate` decides server-side. `Codable` so it round-trips
/// through the local display cache (see `EntitlementStore`); built from the
/// wire DTO via `init(dto:)`.
struct ManagedEntitlementSnapshot: Codable, Equatable {
    let tier: ManagedTier
    let status: ManagedStatus
    let creditsRemaining: Int
    let creditsLimit: Int
    /// The current-period end / credit-reset anchor. `nil` if the backend
    /// hasn't set one yet.
    let resetDate: Date?

    /// True while the subscription is in LemonSqueezy's dunning window — drives
    /// the non-blocking "Payment issue — update your card" nudge (§9.1).
    var isPastDue: Bool { status == .pastDue }

    /// True when the current period's credits are spent. Display-only — the
    /// server still enforces the real block.
    var isOutOfCredits: Bool { creditsRemaining <= 0 }

    /// Builds the domain snapshot from the decoded wire shape, parsing the ISO
    /// `reset_date` into a `Date`.
    init(dto: EntitlementSnapshotDTO) {
        self.tier = dto.tier
        self.status = dto.status
        self.creditsRemaining = dto.creditsRemaining
        self.creditsLimit = dto.creditsLimit
        self.resetDate = ManagedBackend.parseISODate(dto.resetDate)
    }

    /// Returns a copy with `creditsRemaining` replaced — used to reflect a
    /// just-completed generation's `credits_remaining` immediately, before the
    /// authoritative `/entitlement` refresh lands.
    func withCreditsRemaining(_ remaining: Int) -> ManagedEntitlementSnapshot {
        ManagedEntitlementSnapshot(
            tier: tier,
            status: status,
            creditsRemaining: max(0, remaining),
            creditsLimit: creditsLimit,
            resetDate: resetDate
        )
    }

    /// Memberwise init (the DTO path is the usual one; this backs
    /// `withCreditsRemaining` and test fixtures).
    init(tier: ManagedTier, status: ManagedStatus, creditsRemaining: Int, creditsLimit: Int, resetDate: Date?) {
        self.tier = tier
        self.status = status
        self.creditsRemaining = creditsRemaining
        self.creditsLimit = creditsLimit
        self.resetDate = resetDate
    }
}

// MARK: - Wire DTOs

/// The `EntitlementSnapshot` wire shape (snake_case) returned by `/session`
/// (nested) and `/entitlement` (top-level). Decoded as-is, then lifted into
/// the domain `ManagedEntitlementSnapshot`.
struct EntitlementSnapshotDTO: Decodable, Equatable {
    let tier: ManagedTier
    let status: ManagedStatus
    let creditsRemaining: Int
    let creditsLimit: Int
    let resetDate: String?

    enum CodingKeys: String, CodingKey {
        case tier, status
        case creditsRemaining = "credits_remaining"
        case creditsLimit = "credits_limit"
        case resetDate = "reset_date"
    }
}

/// `/session` success body: a short-lived bearer token, its expiry, and the
/// current entitlement snapshot.
struct SessionResponseDTO: Decodable {
    let token: String
    let expiresAt: String
    let entitlement: EntitlementSnapshotDTO

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case entitlement
    }
}

/// `/generate` success body: the finished prompt, token usage, and the
/// post-decrement credit balance. `usage` mirrors the BYOK `TokenUsage` shape
/// so the cost-log path is identical.
struct GenerateResponseDTO: Decodable {
    let prompt: String
    let usage: UsageDTO?
    let creditsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case prompt, usage
        case creditsRemaining = "credits_remaining"
    }

    struct UsageDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let model: String

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case model
        }
    }
}

/// `/trial-start` response body (Phase F). One shape covers both actions: a
/// `request` returns `{ status }` ("code_sent" / "already_used"); a `verify`
/// returns `{ token, expires_at, trial_credits_remaining }` on success or
/// `{ status: "already_used" }`. `error` carries the typed failure string on a
/// 4xx/5xx so the client maps it to a `TrialStartError`.
struct TrialStartResponseDTO: Decodable {
    let token: String?
    let expiresAt: String?
    let trialCreditsRemaining: Int?
    let status: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case token, status, error
        case expiresAt = "expires_at"
        case trialCreditsRemaining = "trial_credits_remaining"
    }
}

// MARK: - ProxyTokenProviding

/// The minimal token surface `ManagedProxyClient` needs, so the SAME proxy can
/// run a Managed subscription generation (token from `SessionTokenManager`) OR a
/// trial generation (token from `TrialCreditsManager`) without knowing which.
/// Both conformers mint/cache a short-lived bearer and surface failures as
/// `ManagedSessionError`. `refreshToken()` re-mints when possible (subscription:
/// re-exchange the license key) or throws when it can't (trial: the credential
/// is an email+code the user must re-enter).
protocol ProxyTokenProviding: AnyObject {
    func validToken() async throws -> String
    @discardableResult func refreshToken() async throws -> String
}

// MARK: - ManagedTransport

/// The minimal HTTP surface the Managed services need, so tests stub every
/// endpoint without a real network. Production uses `URLSessionManagedTransport`.
/// Throws ONLY on a genuine transport failure (offline, DNS, timeout); any HTTP
/// status — including 4xx/5xx — returns normally so callers branch on the
/// backend's own status codes + error bodies.
protocol ManagedTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Production `ManagedTransport` over a dedicated `URLSession`. Mirrors the
/// other clients' session config (no cache). Each request carries its own
/// method/headers/body; this just performs it and reports `(data, status)`.
struct URLSessionManagedTransport: ManagedTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSessionManagedTransport.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }
}
