//
//  ManagedTestSupport.swift
//  ZerroTests
//
//  Created by Colin Breeding on 6/2/26.
//
//  Phase E — shared test doubles for the Managed backend layer. The network
//  goes through `StubManagedTransport` (canned `(Data, status)` responses,
//  every request recorded for assertion) so the SessionTokenManager and
//  ManagedProxyClient tests are deterministic value-in/value-out checks that
//  never touch the real Supabase backend.
//

import Foundation
@testable import Zerro

// MARK: - StubManagedTransport

/// Records every request and returns queued `(Data, status)` responses in
/// order, or throws `error` if set (the transport-failure path). Mirrors
/// `LicenseServiceTests.StubLicenseTransport`.
final class StubManagedTransport: ManagedTransport, @unchecked Sendable {
    struct Stubbed {
        let data: Data
        let status: Int
    }

    var responses: [Stubbed] = []
    var error: Error?
    private(set) var requests: [URLRequest] = []

    var callCount: Int { requests.count }

    func enqueue(_ json: String, status: Int) {
        responses.append(Stubbed(data: Data(json.utf8), status: status))
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { return (Data("{}".utf8), 200) }
        let next = responses.removeFirst()
        return (next.data, next.status)
    }
}

// MARK: - Fixtures

enum ManagedFixtures {
    /// A `/session` success body with the given token. Far-future expiry by
    /// default so `validToken()` treats it as cacheable.
    static func sessionJSON(
        token: String,
        tier: String = "starter",
        status: String = "active",
        creditsRemaining: Int = 100,
        creditsLimit: Int = 100,
        expiresAt: String = "2030-01-01T00:00:00.000Z",
        resetDate: String = "2026-07-01T00:00:00.000Z"
    ) -> String {
        """
        {"token":"\(token)","expires_at":"\(expiresAt)","entitlement":{"tier":"\(tier)","status":"\(status)","credits_remaining":\(creditsRemaining),"credits_limit":\(creditsLimit),"reset_date":"\(resetDate)"}}
        """
    }

    /// An `/entitlement` snapshot body.
    static func entitlementJSON(
        tier: String = "starter",
        status: String = "active",
        creditsRemaining: Int = 100,
        creditsLimit: Int = 100,
        resetDate: String = "2026-07-01T00:00:00.000Z",
        planCreditsUsed: Int = 0,
        planCreditsLimit: Int = 100,
        topupCreditsRemaining: Int = 0
    ) -> String {
        """
        {"tier":"\(tier)","status":"\(status)","credits_remaining":\(creditsRemaining),"credits_limit":\(creditsLimit),"reset_date":"\(resetDate)","plan_credits_used":\(planCreditsUsed),"plan_credits_limit":\(planCreditsLimit),"topup_credits_remaining":\(topupCreditsRemaining)}
        """
    }

    /// A pre-multi-model entitlement body — no plan-vs-top-up breakdown
    /// fields. The client must still decode it (older backend / cache).
    static func entitlementJSONLegacy(
        tier: String = "pro",
        status: String = "active",
        creditsRemaining: Int = 100,
        creditsLimit: Int = 100,
        resetDate: String = "2026-07-01T00:00:00.000Z"
    ) -> String {
        """
        {"tier":"\(tier)","status":"\(status)","credits_remaining":\(creditsRemaining),"credits_limit":\(creditsLimit),"reset_date":"\(resetDate)"}
        """
    }

    /// A `/generate` success body (post-D2: carries `credits_charged`).
    static func generateJSON(
        prompt: String = "Do the thing.",
        creditsRemaining: Int = 99,
        creditsCharged: Int = 4
    ) -> String {
        """
        {"prompt":"\(prompt)","usage":{"input_tokens":1200,"output_tokens":300,"model":"gpt-4o"},"credits_remaining":\(creditsRemaining),"credits_charged":\(creditsCharged)}
        """
    }

    /// A pre-D2 `/generate` body — no `credits_charged`. The client must
    /// still parse it (older backend during a rollout window).
    static func generateJSONPreD2(
        prompt: String = "Do the thing.",
        creditsRemaining: Int = 99
    ) -> String {
        """
        {"prompt":"\(prompt)","usage":{"input_tokens":1200,"output_tokens":300,"model":"gpt-4o"},"credits_remaining":\(creditsRemaining)}
        """
    }

    /// A Dev Mode CALL 1 (`dev_transcribe`) success body — a word-level transcript
    /// and nothing else (the call is free).
    static func transcribeJSON(durationSeconds: Double = 12) -> String {
        """
        {"transcript":{"segments":[{"start":0,"end":2,"text":"make this bigger"}],"words":[{"word":"make","start":0,"end":0.4},{"word":"this","start":0.4,"end":0.7},{"word":"bigger","start":0.7,"end":1.1}],"durationSeconds":\(durationSeconds)}}
        """
    }

    /// A Dev Mode CALL 2 (`mode:"dev"`) success body — the agent_prompt plus the
    /// structured `anchors[]` the server parsed from the model's `zerro_anchors`
    /// block (the M7 contract).
    static func generateDevJSON(
        prompt: String = "Goal: enlarge the button.",
        creditsRemaining: Int = 99,
        creditsCharged: Int = 4
    ) -> String {
        """
        {"prompt":"\(prompt)","usage":{"input_tokens":1200,"output_tokens":300,"model":"gpt-4o"},"credits_remaining":\(creditsRemaining),"credits_charged":\(creditsCharged),"anchors":[{"ref":0,"label":"Get started","type":"button","region":"hero","current_state":"14px","confidence":0.9,"alt_candidates":["Get Started"]}]}
        """
    }

    /// Writes `bytes` to a unique temp file and returns its URL (for the proxy's
    /// audio/frame reads). Caller is responsible for cleanup if it cares.
    static func tempFile(_ bytes: [UInt8] = [0x00, 0x01, 0x02, 0x03]) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-test-\(UUID().uuidString)")
        try? Data(bytes).write(to: url)
        return url
    }
}
