//
//  PermissionsRevocationCacheTests.swift
//  ZerroTests
//
//  H-09 — the stale screen-recording cache after an idle revocation.
//
//  The bug: `PermissionsManager` caches a successful `SCShareableContent`
//  probe in `screenRecordingGrantedViaShareable`, and while that cache was
//  true `computeScreenRecordingStatus` reported `.granted` without consulting
//  CGPreflight. A probe result is live evidence only at the moment it ran —
//  revoke Screen Recording in System Settings while the app sits idle and no
//  probe re-runs, so the cache stayed true, the record-start gate (which
//  refreshes statuses and reads `.granted`) passed, and SCStream then failed
//  at capture with a generic error instead of the actionable permission flow.
//
//  The fix: whenever the strict check reads not-granted, the compute path
//  CLEARS the cache before trusting it, so a revocation surfaces as
//  `.denied` / `.notDetermined` on the very next refresh. These tests drive
//  the strict check through the DEBUG-only injection seam
//  (`strictScreenRecordingCheckOverrideForTesting`) so no live TCC state is
//  read; each manager gets an ephemeral UserDefaults and Analytics is inert
//  in tests (never `start()`ed).
//

import XCTest
@testable import Zerro

@MainActor
final class PermissionsRevocationCacheTests: XCTestCase {

    private func makeManager(defaults: UserDefaults = .ephemeralPreview()) -> PermissionsManager {
        PermissionsManager(defaults: defaults)
    }

    /// The reported bug, end to end: cache says granted, the strict check
    /// says revoked → the refresh must clear the cache AND stop reporting
    /// `.granted` (fresh install → `.notDetermined`).
    func testPreflightFalseClearsStaleCacheAndStatus() {
        let manager = makeManager()
        manager.strictScreenRecordingCheckOverrideForTesting = { false }
        manager.seedShareableCacheForTesting(true)

        manager.refreshStatuses()

        XCTAssertFalse(
            manager.isShareableCacheSetForTesting,
            "A strict not-granted read must invalidate the cached shareable success"
        )
        XCTAssertEqual(
            manager.screenRecordingStatus, .notDetermined,
            "With the cache cleared and no prior request, the status falls to .notDetermined — never a stale .granted"
        )
    }

    /// Same revocation, but the user answered the TCC prompt in the past
    /// (the persisted has-requested flag is set) — the status the record
    /// gate reads must be `.denied`, which routes to the permissions step.
    func testIdleRevocationSurfacesAsDeniedAfterPriorRequest() {
        let defaults = UserDefaults.ephemeralPreview()
        defaults.set(true, forKey: "vf.permissions.hasRequestedScreenRecording")
        let manager = makeManager(defaults: defaults)
        manager.strictScreenRecordingCheckOverrideForTesting = { false }
        manager.seedShareableCacheForTesting(true)

        manager.refreshStatuses()

        XCTAssertFalse(manager.isShareableCacheSetForTesting)
        XCTAssertEqual(
            manager.screenRecordingStatus, .denied,
            "An idle revocation must read as .denied on the next refresh so the record gate re-opens permissions"
        )
    }

    /// The grant path must be unweakened: a genuine grant (strict check
    /// true) reports `.granted` exactly as before, cache or no cache.
    func testGenuineGrantStillReportsGranted() {
        let manager = makeManager()
        manager.strictScreenRecordingCheckOverrideForTesting = { true }

        manager.refreshStatuses()
        XCTAssertEqual(manager.screenRecordingStatus, .granted)

        // And a stale-looking cache alongside a real grant changes nothing.
        manager.seedShareableCacheForTesting(true)
        manager.refreshStatuses()
        XCTAssertEqual(manager.screenRecordingStatus, .granted)
    }

    /// Revoke → re-grant round trip: after the cache was invalidated by a
    /// revocation, a later strict-granted read recovers `.granted` (the
    /// cleared cache must not latch the manager into denied).
    func testRegrantAfterRevocationRecovers() {
        let manager = makeManager()
        var granted = false
        manager.strictScreenRecordingCheckOverrideForTesting = { granted }
        manager.seedShareableCacheForTesting(true)

        manager.refreshStatuses()
        XCTAssertNotEqual(manager.screenRecordingStatus, .granted)

        granted = true
        manager.refreshStatuses()
        XCTAssertEqual(manager.screenRecordingStatus, .granted)
    }
}
