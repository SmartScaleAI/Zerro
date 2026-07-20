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

    // MARK: - H-06: record-attempt gate ordering (consent outranks permissions)

    /// The re-onboarding loop: a completed user owing BOTH re-consent and a
    /// permission re-grant must be routed to CONSENT first — the permission
    /// jump would let the flow's tail run completeOnboarding() without ever
    /// running recordConsent(), latching needsConsent true forever.
    func testConsentOutranksAMissingPermissionAtTheRecordGate() {
        for (screen, mic) in [(false, true), (true, false), (false, false), (true, true)] {
            XCTAssertEqual(
                OnboardingState.recordGateAction(
                    hasCompletedOnboarding: true,
                    needsConsent: true,
                    screenGranted: screen,
                    micGranted: mic
                ),
                .reconsent,
                "consent owed (screen=\(screen) mic=\(mic)) must route to reconsent, never .permissions"
            )
        }
    }

    func testFirstRunStillOpensOnboardingRegardlessOfConsentOrPermissions() {
        for needsConsent in [true, false] {
            XCTAssertEqual(
                OnboardingState.recordGateAction(
                    hasCompletedOnboarding: false,
                    needsConsent: needsConsent,
                    screenGranted: false,
                    micGranted: false
                ),
                .openOnboarding
            )
        }
    }

    func testCompletedUserWithRevokedPermissionAndCurrentConsentRoutesToPermissions() {
        XCTAssertEqual(
            OnboardingState.recordGateAction(
                hasCompletedOnboarding: true,
                needsConsent: false,
                screenGranted: false,
                micGranted: true
            ),
            .requestPermissions
        )
        XCTAssertEqual(
            OnboardingState.recordGateAction(
                hasCompletedOnboarding: true,
                needsConsent: false,
                screenGranted: true,
                micGranted: false
            ),
            .requestPermissions
        )
    }

    func testNothingOwedProceeds() {
        XCTAssertEqual(
            OnboardingState.recordGateAction(
                hasCompletedOnboarding: true,
                needsConsent: false,
                screenGranted: true,
                micGranted: true
            ),
            .proceed
        )
    }

    // MARK: - H-06: reconsent lifecycle

    /// A completed install with stale terms enters reconsent mode at init
    /// (the launch gate); a permission jump that moved the step off .consent
    /// (the pre-fix hijack, or the reverse race) is repaired by
    /// beginReconsent(); accepting clears BOTH flags so the next record
    /// attempt falls through to the permission gate.
    func testBeginReconsentRepinsConsentAfterAPermissionJump() {
        defaults.set(true, forKey: "vf.onboarding.hasCompletedOnboarding")
        defaults.set("2020-01-01", forKey: "vf.consent.termsAcceptedVersion")
        let state = OnboardingState(defaults: defaults)
        XCTAssertTrue(state.isReconsenting, "stale terms on a completed install → reconsent at launch")
        XCTAssertEqual(state.currentStep, .consent)

        // Reverse race: a (pre-fix) permission jump moved the window off the
        // consent step while reconsent was pending.
        state.jump(to: .permissions)
        XCTAssertEqual(state.currentStep, .permissions)
        XCTAssertTrue(state.isReconsenting)

        // The record gate's consent branch repairs the pin…
        state.beginReconsent()
        XCTAssertEqual(state.currentStep, .consent)
        XCTAssertTrue(state.isReconsenting, "accept must take the reconsent DISMISS path, not advance()")
    }

    func testRecordConsentClearsReconsentSoTheNextAttemptHitsThePermissionGate() {
        defaults.set(true, forKey: "vf.onboarding.hasCompletedOnboarding")
        defaults.set("2020-01-01", forKey: "vf.consent.termsAcceptedVersion")
        let state = OnboardingState(defaults: defaults)
        state.beginReconsent()

        state.recordConsent()
        XCTAssertFalse(state.needsConsent, "accept records the current terms version")
        XCTAssertFalse(state.isReconsenting, "accept leaves reconsent mode")

        // The NEXT record attempt (permission still revoked) now falls
        // through the consent gate to the permission gate — the loop is broken.
        XCTAssertEqual(
            OnboardingState.recordGateAction(
                hasCompletedOnboarding: state.hasCompletedOnboarding,
                needsConsent: state.needsConsent,
                screenGranted: false,
                micGranted: true
            ),
            .requestPermissions
        )
    }
}
