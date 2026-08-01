//
//  OnboardingPermissionsTests.swift
//  ZerroTests
//

import XCTest
@testable import Zerro

final class OnboardingPermissionsTests: XCTestCase {
    func testPresentationStatesFollowPermissionStatus() {
        XCTAssertEqual(
            OnboardingPermissionsPolicy.presentationState(for: .notDetermined),
            .request
        )
        XCTAssertEqual(
            OnboardingPermissionsPolicy.presentationState(for: .granted),
            .granted
        )
        XCTAssertEqual(
            OnboardingPermissionsPolicy.presentationState(for: .denied),
            .denied
        )
    }

    func testScreenRelaunchStateTakesPriorityOverBaseStatus() {
        for status in [PermissionStatus.notDetermined, .granted, .denied] {
            XCTAssertEqual(
                OnboardingPermissionsPolicy.presentationState(
                    for: status,
                    needsRelaunch: true
                ),
                .needsRelaunch
            )
        }
    }

    func testContinueRequiresBothLiveGrantsAndNoPendingRelaunch() {
        XCTAssertTrue(
            OnboardingPermissionsPolicy.canContinue(
                screenStatus: .granted,
                microphoneStatus: .granted,
                screenNeedsRelaunch: false
            )
        )

        XCTAssertFalse(
            OnboardingPermissionsPolicy.canContinue(
                screenStatus: .denied,
                microphoneStatus: .granted,
                screenNeedsRelaunch: false
            )
        )
        XCTAssertFalse(
            OnboardingPermissionsPolicy.canContinue(
                screenStatus: .granted,
                microphoneStatus: .denied,
                screenNeedsRelaunch: false
            )
        )
        XCTAssertFalse(
            OnboardingPermissionsPolicy.canContinue(
                screenStatus: .granted,
                microphoneStatus: .granted,
                screenNeedsRelaunch: true
            )
        )
    }
}
