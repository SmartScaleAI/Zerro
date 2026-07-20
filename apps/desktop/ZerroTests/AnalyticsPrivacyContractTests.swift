//
//  AnalyticsPrivacyContractTests.swift
//  ZerroTests
//
//  I-08 — the analytics privacy contract, pinned where seams exist WITHOUT
//  faking the PostHog SDK:
//    • the opt-out gate: Analytics.isEnabled reads the Settings toggle
//      (default ON when unset) and CrashReporting.capture() no-ops to nil
//      when it's off — nothing reaches the SDK;
//    • the DEBUG posture: in this (Debug) test build Analytics.start()
//      returns before SDK setup, observable as a nil distinctId — the
//      compile-time `#if DEBUG` no-send guard itself can only be verified
//      by inspection, this pins its observable consequence;
//    • the CrashReporting context scrubber: allowlisted keys only,
//      secret-shaped and >80-char values dropped whole (never truncated
//      into the event).
//
//  NOT unit-reachable (documented, not faked): the enabled-path dispatch
//  into PostHogSDK.shared (no injection seam — testing it would mean
//  touching the real singleton), and optIn()/optOut() bridging in
//  Analytics.setEnabled. The recording-pipeline secret masking that feeds
//  scrubbed values (Redactor.maskSecrets / SecretDetector) is covered by
//  RedactorTests + SecretDetectorTests; the I-03 consent-gated startup is
//  covered by OnboardingConsentGateTests; the I-04 path redaction by
//  MetricKitRedactionTests.
//

import XCTest
@testable import Zerro

final class AnalyticsPrivacyContractTests: XCTestCase {

    /// The live Settings-toggle value, saved/restored so these tests can't
    /// perturb the developer's real preference (the key lives in
    /// UserDefaults.standard — Analytics reads it directly by design).
    private var savedToggle: Any?

    override func setUp() {
        super.setUp()
        savedToggle = UserDefaults.standard.object(forKey: CrashReporting.isEnabledDefaultsKey)
    }

    override func tearDown() {
        if let savedToggle {
            UserDefaults.standard.set(savedToggle, forKey: CrashReporting.isEnabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CrashReporting.isEnabledDefaultsKey)
        }
        super.tearDown()
    }

    // MARK: - The opt-out gate

    func testIsEnabledDefaultsOnWhenTheKeyIsUnset() {
        UserDefaults.standard.removeObject(forKey: CrashReporting.isEnabledDefaultsKey)
        XCTAssertTrue(Analytics.isEnabled, "key-absent must mean ON — matching the Settings row default")
    }

    func testIsEnabledTracksTheToggleLiveAndCrashReportingDelegates() {
        UserDefaults.standard.set(false, forKey: CrashReporting.isEnabledDefaultsKey)
        XCTAssertFalse(Analytics.isEnabled)
        XCTAssertFalse(CrashReporting.isEnabled, "one switch gates both product events and error capture")

        UserDefaults.standard.set(true, forKey: CrashReporting.isEnabledDefaultsKey)
        XCTAssertTrue(Analytics.isEnabled, "re-reads on demand — a flip applies without restart")
        XCTAssertTrue(CrashReporting.isEnabled)
    }

    func testCaptureNoOpsToNilWhenTheToggleIsOff() {
        UserDefaults.standard.set(false, forKey: CrashReporting.isEnabledDefaultsKey)
        let before = CrashReporting.lastEventId

        let id = CrashReporting.capture(
            URLError(.timedOut),
            message: "Privacy contract test",
            stage: "test",
            context: ["errorCode": "timeout"]
        )

        XCTAssertNil(id, "opt-out must short-circuit before any SDK work — no diagnostic id minted")
        XCTAssertEqual(CrashReporting.lastEventId, before, "a gated capture must not stamp lastEventId")
    }

    // MARK: - The DEBUG posture

    func testDebugBuildStartNeverBringsUpTheSDK() {
        // The `#if DEBUG` guard in Analytics.start() is compile-time; its
        // observable consequence in this Debug test build is that start()
        // returns before setup, so didStart stays false → distinctId nil.
        Analytics.start()
        XCTAssertNil(Analytics.distinctId, "DEBUG start() must return before PostHog setup — development transmits nothing")
    }

    // MARK: - The context scrubber (allowlist + shape gates)

    func testScrubContextDropsKeysOutsideTheAllowlist() {
        let scrubbed = CrashReporting.scrubContext([
            "errorCode": "auth",
            "modelName": "gpt-5.4-mini",
            "providerStatus": "503",
            // A call-site typo or over-share must be dropped by KEY, so user
            // content can never ride an unknown property name.
            "userEmail": "colin@example.com",
            "filePath": "/Users/colin/Recordings/take-2.mov",
            "promptText": "make the save button teal",
        ])
        XCTAssertEqual(
            scrubbed,
            ["errorCode": "auth", "modelName": "gpt-5.4-mini", "providerStatus": "503"],
            "only allowlisted keys survive"
        )
    }

    func testScrubContextDropsOverlongValuesWhole() {
        // Prose (with spaces) so the length gate is tested in isolation — a
        // spaceless 80-char run would trip the opaque-run secret shape instead.
        let eighty = String(repeating: "err 503 ", count: 10)
        XCTAssertEqual(eighty.count, 80)
        let scrubbed = CrashReporting.scrubContext([
            "providerMessage": eighty + "y",   // 81 — dropped, never truncated
            "errorCode": eighty,               // exactly 80 — kept
        ])
        XCTAssertNil(scrubbed["providerMessage"], "an overlong value is dropped WHOLE — truncation could still leak a prefix")
        XCTAssertEqual(scrubbed["errorCode"], eighty, "the 80-char boundary itself is allowed")
    }

    func testScrubContextDropsSecretShapedValues() {
        let scrubbed = CrashReporting.scrubContext([
            "providerMessage": "sk-proj-abc123",                      // key prefix
            "errorCode": String(repeating: "a", count: 32),           // long opaque run
            "modelName": "gpt-5.4-mini",                              // normal — kept
        ])
        XCTAssertNil(scrubbed["providerMessage"])
        XCTAssertNil(scrubbed["errorCode"])
        XCTAssertEqual(scrubbed["modelName"], "gpt-5.4-mini")
    }

    func testLooksLikeSecretShapeBoundaries() {
        XCTAssertTrue(CrashReporting.looksLikeSecret("sk-anything"), "sk- prefix is always secret-shaped")
        XCTAssertTrue(CrashReporting.looksLikeSecret(String(repeating: "A1_-", count: 8)), "a 32-char opaque run is secret-shaped")
        XCTAssertFalse(CrashReporting.looksLikeSecret(String(repeating: "a", count: 31)), "31 chars is under the opaque-run floor")
        XCTAssertFalse(CrashReporting.looksLikeSecret("model gpt-5.4-mini returned 503"), "spaces break the opaque-run shape — prose passes")
    }
}
