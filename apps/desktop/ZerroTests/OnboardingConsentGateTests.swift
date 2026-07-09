//
//  OnboardingConsentGateTests.swift
//  ZerroTests
//
//  I-03 — the consent gate that defers telemetry startup:
//    • OnboardingState.hasCurrentConsent: false with no / stale accepted terms,
//      true once the CURRENT terms version is on record.
//    • recordConsent() fires the deferred AppDelegate.startTelemetryOnConsent
//      hook exactly once (one-shot), AFTER the consent write.
//  Analytics.start() itself is deliberately NOT unit-tested here (DEBUG-guarded
//  and touches the PostHog singleton).
//

import XCTest
@testable import Zerro

@MainActor
final class OnboardingConsentGateTests: XCTestCase {

    private static let suiteName = "OnboardingConsentGateTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppDelegate.startTelemetryOnConsent = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        AppDelegate.startTelemetryOnConsent = nil
        super.tearDown()
    }

    // MARK: - hasCurrentConsent

    func testHasCurrentConsentIsFalseWhenNeverAccepted() {
        XCTAssertFalse(OnboardingState.hasCurrentConsent(defaults: defaults))
    }

    func testHasCurrentConsentIsFalseForAStaleAcceptedVersion() {
        // An older Terms version on record must NOT count as current consent
        // (the re-consent launch is exactly this state).
        defaults.set("2020-01-01", forKey: "vf.consent.termsAcceptedVersion")
        XCTAssertFalse(OnboardingState.hasCurrentConsent(defaults: defaults))
    }

    func testHasCurrentConsentIsTrueAfterRecordConsent() {
        let state = OnboardingState(defaults: defaults)
        state.recordConsent()
        XCTAssertTrue(OnboardingState.hasCurrentConsent(defaults: defaults))
    }

    // MARK: - deferred telemetry hook

    func testRecordConsentFiresTheDeferredHookExactlyOnceAfterTheWrite() {
        var fired = 0
        var consentWasOnRecordWhenFired = false
        AppDelegate.startTelemetryOnConsent = { [defaults] in
            fired += 1
            // The hook must run AFTER the consent record is written.
            consentWasOnRecordWhenFired = OnboardingState.hasCurrentConsent(defaults: defaults!)
        }

        let state = OnboardingState(defaults: defaults)
        state.recordConsent()
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(consentWasOnRecordWhenFired)
        XCTAssertNil(AppDelegate.startTelemetryOnConsent, "hook is one-shot — cleared before invoking")

        // A second accept (e.g. a later re-consent in the same process) must
        // not fire the startup again.
        state.recordConsent()
        XCTAssertEqual(fired, 1)
    }

    func testRecordConsentWithNoHookRegisteredIsANoOp() {
        // The consented-at-launch path never registers the hook; recordConsent
        // must still work (and persist) without one.
        let state = OnboardingState(defaults: defaults)
        state.recordConsent()
        XCTAssertTrue(OnboardingState.hasCurrentConsent(defaults: defaults))
    }
}
