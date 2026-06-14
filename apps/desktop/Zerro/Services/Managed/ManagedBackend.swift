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
import os

// MARK: - ManagedBackend

/// Non-secret configuration for the Managed backend. The function base URL is
/// a public constant (the security model never trusts the client; see §6.1),
/// kept in one place so a future project move is a single-line change.
enum ManagedBackend {

    /// Supabase Edge Functions base. NOT a secret — anyone can call these;
    /// the server enforces auth + credits regardless of who calls.
    static let functionsBaseURLString = "https://wjxqmurgwyxwkezncxke.supabase.co/functions/v1"

    /// DEBUG-only base-URL override for local model testing. Set the
    /// ZERRO_FUNCTIONS_BASE_URL environment variable in the Xcode scheme
    /// (e.g. http://127.0.0.1:54321/functions/v1) to point a debug build at
    /// `supabase functions serve`, where CHAT_PROVIDER / CHAT_MODEL can be
    /// flipped per-run via an --env-file — no deploy, production untouched.
    /// Compiled OUT of release builds: ships pinned to the production URL.
    ///
    /// The override is PERSISTED so it survives ANY relaunch — not just an
    /// Xcode Run. The scheme env var is injected only when Xcode launches the
    /// process; the app's own relaunches (the Screen-Recording grant relaunch /
    /// SIGKILL reopen, see `relaunchToApplyScreenRecording`) and any standalone
    /// Finder launch do NOT inherit it. Without persistence those launches
    /// would SILENTLY fall back to the production URL mid-session — writing test
    /// traffic and trial grants to the real DB, and minting trial tokens against
    /// a backend the next Xcode-launched run then rejects (surfacing as a bogus
    /// "verify your email"). So: a launch that sees the env var records it; a
    /// launch without it reads the recorded value back. To deliberately point a
    /// DEBUG build back at production, set ZERRO_FUNCTIONS_BASE_URL to an empty
    /// string (or `production`) once — that clears the persisted override.
    private static let persistedOverrideKey = "dev.functionsBaseURLOverride"

    static let baseURL: URL = {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let raw = ProcessInfo.processInfo.environment["ZERRO_FUNCTIONS_BASE_URL"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "production" {
                // Explicit opt back to production from a DEBUG build.
                defaults.removeObject(forKey: persistedOverrideKey)
            } else if let url = URL(string: trimmed) {
                defaults.set(trimmed, forKey: persistedOverrideKey)
                Log.billing.notice("Managed backend (DEBUG, from env): \(trimmed, privacy: .public)")
                return url
            }
        } else if let persisted = defaults.string(forKey: persistedOverrideKey),
                  let url = URL(string: persisted) {
            // No env var (self-relaunch / Finder launch) — reuse the recorded
            // override rather than silently falling back to production.
            Log.billing.notice("Managed backend (DEBUG, persisted override): \(persisted, privacy: .public)")
            return url
        }
        Log.billing.notice("Managed backend (DEBUG): production \(functionsBaseURLString, privacy: .public)")
        #endif
        return URL(string: functionsBaseURLString)!
    }()

    /// DEBUG: true when the backend is pointed at a dev/local override (from the
    /// scheme env var OR the persisted fallback) rather than the production
    /// default. Throwaway dev-only credentials — the `ZERRO_DEV_LICENSE_KEY`
    /// test key — may be used ONLY when this is true, so a test key can never
    /// reach the production `/session`. Derived from `baseURL` so it stays in
    /// lockstep with the persisted-override resolution above (in particular it
    /// survives the onboarding Screen-Recording relaunch, which drops the env
    /// var but keeps the persisted override). Always false in release.
    static var usesDevOverride: Bool {
        #if DEBUG
        return baseURL.absoluteString != functionsBaseURLString
        #else
        return false
        #endif
    }

    static var sessionURL: URL { baseURL.appendingPathComponent("session") }
    static var generateURL: URL { baseURL.appendingPathComponent("generate") }
    static var entitlementURL: URL { baseURL.appendingPathComponent("entitlement") }
    /// Phase F — the email-gated trial-credits endpoint (request + verify code).
    static var trialStartURL: URL { baseURL.appendingPathComponent("trial-start") }
    /// Phase 6 (typed-artifact refactor) — the free "Write agent prompt"
    /// conversion endpoint.
    static var convertURL: URL { baseURL.appendingPathComponent("convert") }

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
    /// COMBINED spendable balance: plan remaining + non-expired top-up packs
    /// (multi-model F4) — the same number the server's spend gate checks.
    /// This is the headline/picker balance, NEVER the usage-meter input.
    let creditsRemaining: Int
    let creditsLimit: Int
    /// The current-period end / credit-reset anchor. `nil` if the backend
    /// hasn't set one yet.
    let resetDate: Date?
    // ---- Plan-vs-top-up breakdown (multi-model F4 / 6F) ----------------------
    // The usage meter's bar MUST track these plan-only figures: deriving usage
    // from the combined `creditsRemaining` over-reports consumption for a
    // top-up holder. Optional — absent from a pre-multi-model backend and from
    // locally cached snapshots written before this build; the meter degrades
    // to a bar-less card rather than guessing.
    /// Plan credits consumed this period (bar numerator).
    let planCreditsUsed: Int?
    /// The plan allowance the bar tracks against (== creditsLimit today;
    /// explicit so the meter never guesses which cap to use).
    let planCreditsLimit: Int?
    /// Non-expired top-up balance (survives the monthly reset). 0 when the
    /// user never bought a pack.
    let topupCreditsRemaining: Int?

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
        self.planCreditsUsed = dto.planCreditsUsed
        self.planCreditsLimit = dto.planCreditsLimit
        self.topupCreditsRemaining = dto.topupCreditsRemaining
    }

    /// Returns a copy with `creditsRemaining` replaced — used to reflect a
    /// just-completed generation's `credits_remaining` immediately, before the
    /// authoritative `/entitlement` refresh lands. The plan breakdown is
    /// carried through UNCHANGED (it may be a charge stale until the refresh —
    /// the meter prefers a briefly-stale bar over a guessed split, since the
    /// charge may have drawn on the top-up bucket, not the plan).
    func withCreditsRemaining(_ remaining: Int) -> ManagedEntitlementSnapshot {
        ManagedEntitlementSnapshot(
            tier: tier,
            status: status,
            creditsRemaining: max(0, remaining),
            creditsLimit: creditsLimit,
            resetDate: resetDate,
            planCreditsUsed: planCreditsUsed,
            planCreditsLimit: planCreditsLimit,
            topupCreditsRemaining: topupCreditsRemaining
        )
    }

    /// Memberwise init (the DTO path is the usual one; this backs
    /// `withCreditsRemaining` and test fixtures). Plan-breakdown fields
    /// default nil so pre-multi-model call sites (dev overrides, fixtures)
    /// compile unchanged.
    init(
        tier: ManagedTier,
        status: ManagedStatus,
        creditsRemaining: Int,
        creditsLimit: Int,
        resetDate: Date?,
        planCreditsUsed: Int? = nil,
        planCreditsLimit: Int? = nil,
        topupCreditsRemaining: Int? = nil
    ) {
        self.tier = tier
        self.status = status
        self.creditsRemaining = creditsRemaining
        self.creditsLimit = creditsLimit
        self.resetDate = resetDate
        self.planCreditsUsed = planCreditsUsed
        self.planCreditsLimit = planCreditsLimit
        self.topupCreditsRemaining = topupCreditsRemaining
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
    /// Plan-vs-top-up breakdown (multi-model F4) — optional so a pre-multi-
    /// model backend still decodes during a rollout window.
    let planCreditsUsed: Int?
    let planCreditsLimit: Int?
    let topupCreditsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case tier, status
        case creditsRemaining = "credits_remaining"
        case creditsLimit = "credits_limit"
        case resetDate = "reset_date"
        case planCreditsUsed = "plan_credits_used"
        case planCreditsLimit = "plan_credits_limit"
        case topupCreditsRemaining = "topup_credits_remaining"
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
    /// The EXACT credits the server charged for this generation (multi-model
    /// D2) — usually the model's fixed price, but the anti-abuse circuit
    /// breaker can meter it higher, and an idempotent replay reports the
    /// ORIGINAL charge (0 on the rare uncharged-race path). The "−N credits"
    /// toast reads this, never the local price table. Optional: a pre-D2
    /// backend omits it and the toast simply doesn't show a charge.
    let creditsCharged: Int?

    enum CodingKeys: String, CodingKey {
        case prompt, usage
        case creditsRemaining = "credits_remaining"
        case creditsCharged = "credits_charged"
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
/// returns `{ token, expires_at, trial_credits_remaining, trial_credits_limit }`
/// on success or `{ status: "already_used" }`. `error` carries the typed
/// failure string on a 4xx/5xx so the client maps it to a `TrialStartError`.
/// `trialCreditsLimit` (E4) is the persisted grant TOTAL — the denominator the
/// trial usage meter draws its bar against. Optional: an older server omits it
/// and the meter degrades to the bar-less display.
struct TrialStartResponseDTO: Decodable {
    let token: String?
    let expiresAt: String?
    let trialCreditsRemaining: Int?
    let trialCreditsLimit: Int?
    let status: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case token, status, error
        case expiresAt = "expires_at"
        case trialCreditsRemaining = "trial_credits_remaining"
        case trialCreditsLimit = "trial_credits_limit"
    }
}

// MARK: - ProxyTokenProviding

/// The minimal token surface `ManagedProxyClient` needs, so the SAME proxy can
/// run a Managed subscription generation (token from `SessionTokenManager`) OR a
/// trial generation (token from `TrialCreditsManager`) without knowing which.
/// Both conformers mint/cache a short-lived bearer and surface failures as
/// `ManagedSessionError`. `refreshToken()` re-mints silently when possible
/// (subscription: re-exchange the license key; trial: POST `action:"resume"`
/// with the remembered verified email — H1) and throws `.notEntitled` only when
/// it genuinely can't (trial: no verified email on record → first-time verify).
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
        // /generate is a long call: upload (audio + ~30 JPEG frames) + server
        // Whisper + multimodal chat. 60s proved too tight — the app timed out
        // while the server was still mid-generation (and the server then paid
        // for a result nobody received). Align with the server's own provider
        // budget: GENERATE_OPENAI/PROVIDER_TIMEOUT_MS defaults to 120s, plus
        // upload + transcription headroom. Request = max quiet gap between
        // bytes; resource = whole-transfer ceiling.
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
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
