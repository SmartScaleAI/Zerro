//
//  LicenseEditionPolicy.swift
//  Zerro
//
//  The single source of truth for WHICH Lemon Squeezy product licenses this
//  build, and WHICH license major it requires. The product ID is the
//  security boundary: activation and validation grant access only when the
//  License API response's `meta.product_id` is in the approved set, and a
//  cached license unlocks offline only when its persisted product ID and
//  licensed major match the running policy. (Variant IDs are display-level
//  and never consulted.)
//
//  Environment: Debug and Staging builds license against the TEST-mode
//  product; production Release builds against the LIVE product — the same
//  split `BillingLinks` uses for the checkout, so a purchase made from a
//  build always yields a key that same build accepts. A production build
//  never approves the test product (the sets are disjoint by construction —
//  one ID each, chosen at compile time).
//
//  This is deliberately independent of the OFFICIAL_BUILD boundary:
//  `EntitlementEnforcementMode` decides WHETHER licensing is enforced at
//  all (community builds ignore it entirely); this policy decides WHAT a
//  license must be when it is enforced.
//
//  Majors: every Zerro 1.x.x build requires major 1 and accepts the same
//  product. A future Zerro 2.x ships with `requiredMajor: 2` and its own
//  product IDs, so a cached major-1 license fails closed there into the
//  new-version purchase flow instead of silently unlocking. Injectable so
//  tests exercise both majors and arbitrary product sets.
//

import Foundation

struct LicenseEditionPolicy: Equatable, Sendable {

    /// The license major this build requires. Zerro 1.x.x builds ship 1.
    let requiredMajor: Int

    /// The Lemon Squeezy product IDs whose keys license this build. One
    /// entry per environment — never both.
    let approvedProductIDs: Set<Int>

    // MARK: - Known products

    /// The live Zerro license product.
    static let liveProductID = 1_134_072
    /// The Lemon Squeezy test-mode Zerro license product.
    static let testProductID = 1_312_648

    /// Whether this build transacts against Lemon Squeezy's test mode
    /// (Debug and Staging) or live mode (production Release). Shared with
    /// `BillingLinks`' checkout selection so licensing and checkout always
    /// agree.
    static var usesTestEnvironment: Bool {
        #if DEBUG || STAGING
        true
        #else
        false
        #endif
    }

    /// The policy for THIS build: major 1, and exactly one approved product
    /// for the build's environment.
    static var current: LicenseEditionPolicy {
        LicenseEditionPolicy(
            requiredMajor: 1,
            approvedProductIDs: [usesTestEnvironment ? testProductID : liveProductID]
        )
    }

    // MARK: - Checks

    /// Whether a License API `meta.product_id` licenses this build. A nil
    /// (missing) product ID is never approved — fail closed.
    func isApproved(productID: Int?) -> Bool {
        guard let productID else { return false }
        return approvedProductIDs.contains(productID)
    }
}
