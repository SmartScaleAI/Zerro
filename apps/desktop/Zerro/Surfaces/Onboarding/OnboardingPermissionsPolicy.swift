//
//  OnboardingPermissionsPolicy.swift
//  Zerro
//
//  Pure presentation policy for the redesigned permissions step. Keeping the
//  state mapping separate from SwiftUI makes the important relaunch and
//  continue-gate rules inexpensive to verify without invoking macOS TCC.
//

import Foundation

enum OnboardingPermissionPresentationState: Equatable {
    case request
    case granted
    case denied
    case needsRelaunch
}

enum OnboardingPermissionsPolicy {
    static func presentationState(
        for status: PermissionStatus,
        needsRelaunch: Bool = false
    ) -> OnboardingPermissionPresentationState {
        if needsRelaunch { return .needsRelaunch }

        switch status {
        case .notDetermined:
            return .request
        case .granted:
            return .granted
        case .denied:
            return .denied
        }
    }

    static func canContinue(
        screenStatus: PermissionStatus,
        microphoneStatus: PermissionStatus,
        screenNeedsRelaunch: Bool
    ) -> Bool {
        screenStatus == .granted &&
        microphoneStatus == .granted &&
        !screenNeedsRelaunch
    }
}
