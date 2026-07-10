//
//  RedactionFloorTests.swift
//  ZerroTests
//
//  F-04 — the redaction FLOOR on the third-party path. A Managed/trial user
//  could switch "Redact Detected Secrets" OFF and upload RAW frames to Zerro's
//  servers; the toggle is now floored to ON whenever generation routes through
//  the managed proxy (`AppState.effectiveRedactSecrets`, fed by the same
//  `EntitlementStore.routesThroughManagedProxy` signal the routing reads —
//  whose per-state semantics are covered in BillingHardeningTests /
//  TrialCreditsTests). The toggle only loosens the BYOK path, where the
//  user's own key talks straight to their own provider. `startRecording`
//  captures the effective flag into `recordingRedactSecrets`, which every
//  downstream consumer (keyframe pipeline + both dev-anchor paths) reads.
//

import XCTest
@testable import Zerro

@MainActor
final class RedactionFloorTests: XCTestCase {

    /// The F-04 fix: Managed/trial (routes through the proxy) + toggle OFF
    /// still redacts.
    func testManagedRouteWithToggleOffForcesRedaction() {
        XCTAssertTrue(AppState.effectiveRedactSecrets(
            toggle: false, routesThroughManagedProxy: true
        ))
    }

    /// BYOK (local route) honors the toggle — OFF stays OFF.
    func testByokRouteHonorsToggleOff() {
        XCTAssertFalse(AppState.effectiveRedactSecrets(
            toggle: false, routesThroughManagedProxy: false
        ))
    }

    /// Toggle ON redacts on both routes.
    func testToggleOnRedactsOnBothRoutes() {
        XCTAssertTrue(AppState.effectiveRedactSecrets(
            toggle: true, routesThroughManagedProxy: true
        ))
        XCTAssertTrue(AppState.effectiveRedactSecrets(
            toggle: true, routesThroughManagedProxy: false
        ))
    }

    /// Fail-safe: an unavailable routing signal (no entitlement store wired)
    /// errs toward redaction.
    func testUnavailableRoutingSignalErrsTowardRedaction() {
        XCTAssertTrue(AppState.effectiveRedactSecrets(
            toggle: false, routesThroughManagedProxy: nil
        ))
    }

    /// The real BYOK-side signal end-to-end: a fresh in-memory entitlement
    /// store (no license, no managed snapshot, no trial token) does not route
    /// through the proxy, so the toggle governs.
    func testFreshEntitlementStoreLeavesToggleInCharge() {
        let store = EntitlementStore(licenseService: .inMemory())
        XCTAssertFalse(AppState.effectiveRedactSecrets(
            toggle: false, routesThroughManagedProxy: store.routesThroughManagedProxy
        ))
    }
}
