//
//  WhatsNewPolicyTests.swift
//  ZerroTests
//
//  The pure launch-time decision for the "What's New" auto-pop
//  (`WhatsNewPolicy.decide`) — the full matrix from the plan: fresh-install
//  seeding, the unchanged/changed version split, and each suppression input
//  (checkbox off, onboarding incomplete, missing changelog entry), plus the
//  downgrade non-trigger. The caller-side `lastSeen` bump is exercised
//  through ZerroApp's launch reconcile, not here — `decide` stays
//  side-effect-free by design.
//

import XCTest
@testable import Zerro

@MainActor
final class WhatsNewPolicyTests: XCTestCase {

    /// The happy-path inputs; each test overrides the one input it probes.
    private func decide(
        current: String = "1.4.22",
        lastSeen: String? = "1.4.21",
        autoShowEnabled: Bool = true,
        onboardingComplete: Bool = true,
        hasEntry: Bool = true
    ) -> WhatsNewPolicy.Decision {
        WhatsNewPolicy.decide(
            current: current,
            lastSeen: lastSeen,
            autoShowEnabled: autoShowEnabled,
            onboardingComplete: onboardingComplete,
            hasEntry: hasEntry
        )
    }

    // MARK: - First-ever install

    func testFreshInstallSeedsWithoutPresenting() {
        // No recorded marker → a fresh install. Onboarding owns that launch;
        // the caller records the marker silently.
        XCTAssertEqual(decide(lastSeen: nil), .seedOnly(version: "1.4.22"))
    }

    func testFreshInstallSeedsEvenWhenOtherGatesWouldFail() {
        // Seeding is unconditional — it must happen even mid-onboarding or
        // with the checkbox off, so the NEXT update is measured from here.
        XCTAssertEqual(
            decide(lastSeen: nil, autoShowEnabled: false, onboardingComplete: false, hasEntry: false),
            .seedOnly(version: "1.4.22")
        )
    }

    // MARK: - Version unchanged

    func testSameVersionDoesNothing() {
        XCTAssertEqual(decide(lastSeen: "1.4.22"), .none)
    }

    // MARK: - The auto-pop

    func testVersionChangePresents() {
        XCTAssertEqual(decide(), .present(version: "1.4.22"))
    }

    func testPatchLevelChangePresents() {
        // "Every version change" includes patches — plain string inequality,
        // no semantic threshold.
        XCTAssertEqual(
            decide(current: "1.4.23", lastSeen: "1.4.22"),
            .present(version: "1.4.23")
        )
    }

    // MARK: - Suppression inputs

    func testCheckboxOffSuppresses() {
        XCTAssertEqual(decide(autoShowEnabled: false), .none)
    }

    func testOnboardingIncompleteSuppresses() {
        XCTAssertEqual(decide(onboardingComplete: false), .none)
    }

    func testMissingChangelogEntrySuppresses() {
        // A release that forgot to update `Changelog` must not pop an empty
        // window.
        XCTAssertEqual(decide(hasEntry: false), .none)
    }

    // MARK: - Downgrade

    func testDowngradeStillMatchesInequalityButIsHarmless() {
        // QA installing an older build: `current != lastSeen` holds, so the
        // policy presents the OLDER version's notes (acceptable — not a real
        // user path). What must never happen is a re-pop loop: the caller
        // moves `lastSeen` to `current` on handling, so the next launch is
        // `.none`. Pin the two-step behavior here.
        XCTAssertEqual(
            decide(current: "1.4.21", lastSeen: "1.4.22"),
            .present(version: "1.4.21")
        )
        XCTAssertEqual(decide(current: "1.4.21", lastSeen: "1.4.21"), .none)
    }

    // MARK: - Changelog data integrity

    func testEntryLookupMatchesExactVersionOnly() {
        // `entries` is non-empty and the lookup is exact-match — the
        // defensive `hasEntry` guard feeds off this.
        guard let newest = Changelog.entries.first else {
            XCTFail("the bundled changelog must never ship empty")
            return
        }
        XCTAssertEqual(Changelog.entry(for: newest.version)?.version, newest.version)
        XCTAssertNil(Changelog.entry(for: "0.0.0-never-shipped"))
    }

    func testShippedChangelogContainsExactlyTheReleasedVersions() {
        // Settings → About & Support → What's New shows every entry, so the
        // shipped list is exactly the released 1.x versions, newest first,
        // and nothing older than the 1.0.0 reset.
        XCTAssertEqual(Changelog.entries.map(\.version), ["1.0.2", "1.0.1", "1.0.0"])
        // Newest release: the single GitHub Releases update-verification note.
        XCTAssertEqual(Changelog.entry(for: "1.0.2")?.highlights.count, 1)
        // 1.0.1 (the single update-channel note) is preserved beneath it.
        XCTAssertEqual(Changelog.entry(for: "1.0.1")?.highlights.count, 1)
        // The 1.0.0 entry is preserved unchanged at the bottom.
        XCTAssertEqual(Changelog.entry(for: "1.0.0")?.highlights.count, 4)
    }

    func testEntriesAreUniquePerVersion() {
        // Duplicate versions would make `entry(for:)` ambiguous and render
        // twice in the window.
        let versions = Changelog.entries.map(\.version)
        XCTAssertEqual(versions.count, Set(versions).count, "one entry per version")
    }
}
