//
//  AffiliateAttribution.swift
//  Zerro
//
//  Resolves the LemonSqueezy affiliate referral for the current buyer so the
//  checkout the app opens can carry `aff_ref` and the sale is credited.
//
//  Why this is server-side
//  -----------------------
//  The referral is captured in the BROWSER: when a visitor lands on
//  getzerro.app/?aff=CODE, the marketing site POSTs the code to the `affiliate`
//  Edge Function, which stores it keyed to the visitor's public IP. A native app
//  can't read a browser cookie, and the buyer's default browser may differ from
//  the one they clicked the link in — so a browser-only hand-off is unreliable.
//
//  Instead, at checkout the app asks the backend "what affiliate matched my
//  public IP recently?" and tags the checkout itself. The match is by network
//  egress IP, so it's BEST-EFFORT: it lands when the buyer purchases from the
//  same network they clicked from, and returns nil otherwise. Attribution must
//  never block or slow a purchase, so every failure path silently yields nil.
//
//  Ref: https://docs.lemonsqueezy.com/help/affiliates-for-merchants/getting-referrals
//

import Foundation

enum AffiliateAttribution {

    /// GET /affiliate success body: the matched referral code, or null when no
    /// recent click matched this device's IP.
    private struct LookupResponse: Decodable {
        let affRef: String?
        enum CodingKeys: String, CodingKey { case affRef = "aff_ref" }
    }

    /// A short-timeout, cacheless session dedicated to the lookup so it can never
    /// inherit the long `/generate` budget and stall the checkout button. Bounded
    /// well under a second of perceptible delay in the common case.
    private static let lookupSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    /// The affiliate referral code for this device, or nil when nothing matched /
    /// the lookup failed or timed out. NEVER throws — callers open the checkout
    /// regardless; a nil simply means an unattributed (but working) purchase.
    /// `transport` is injectable so tests exercise the decode/branch logic with
    /// canned responses and never touch the network.
    static func referralCode(
        transport: ManagedTransport = URLSessionManagedTransport(session: AffiliateAttribution.lookupSession)
    ) async -> String? {
        var request = URLRequest(url: ManagedBackend.affiliateURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, status) = try await transport.send(request)
            guard status == 200 else { return nil }
            let code = try JSONDecoder().decode(LookupResponse.self, from: data).affRef
            guard let code, !code.isEmpty else { return nil }
            Log.billing.notice("affiliate: referral matched for this device")
            return code
        } catch {
            // Offline / timeout / decode failure → no attribution, no error.
            return nil
        }
    }
}
