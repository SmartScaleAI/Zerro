//
//  OnboardingState.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  Live state for the onboarding window. Owned by the App as @State and
//  injected into the onboarding scene's environment. Matches the
//  @MainActor @Observable pattern AppState and PreferencesStore use.
//
//  Persists two pieces of state to UserDefaults:
//    • hasCompletedOnboarding — sticky flag set on All Set, gates
//      first-launch window auto-present and hotkey inertness.
//    • currentStep — survives the SIGKILL macOS issues when an app
//      gains Screen Recording permission. Without persisting this,
//      the user would land back on Welcome after every Screen
//      Recording grant and could never progress past step 2. The
//      step is cleared on completeOnboarding so a future re-trigger
//      of onboarding starts clean.
//
//  This DOES extend "resume where you left off" beyond the original
//  spec's no-resume guidance — but only because the OS-mandated kill
//  is a different beast from a user intentionally quitting. A normal
//  Cmd-Q mid-onboarding will also resume, which is a small UX cost
//  worth paying to make the OS-kill path survivable.
//
//  UserDefaults-backed manually (rather than via @AppStorage) because
//  @AppStorage is a SwiftUI property wrapper that only works in Views,
//  not in an @Observable class.
//

import Foundation
import Observation

/// Namespace for onboarding window-scene constants. Lives alongside the
/// state so callers that need to programmatically open or dismiss the
/// window (e.g. the All Set step's Done action) can do so without
/// hard-coding string identifiers.
enum OnboardingScene {
    static let windowID = "onboarding"
}

@MainActor
@Observable
final class OnboardingState {

    // MARK: - Persisted

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Survives the OS-issued SIGKILL on Screen Recording grant.
    /// Persisted on every change; cleared on completeOnboarding.
    var currentStep: OnboardingStep {
        didSet { defaults.set(currentStep.rawValue, forKey: Keys.currentStep) }
    }

    // MARK: - Dev sub-state pins
    //
    // DEBUG-only overrides set by the dev panel. When non-nil, the
    // permission step uses the pinned value instead of the live
    // PermissionsManager value, so we can render any sub-state for
    // visual review without actually toggling system permissions.
    // Production code reads these as nil — only OnboardingDevPanel
    // writes them.

    var pinnedScreenSubState: PermissionStatus?
    var pinnedMicSubState: PermissionStatus?
    var pinnedAccessSubState: PermissionStatus?
    var pinnedAPIKeySubState: APIKeyValidationState?

    // MARK: - Storage

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let hasCompletedOnboarding = "vf.onboarding.hasCompletedOnboarding"
        static let currentStep            = "vf.onboarding.currentStep"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        // `integer(forKey:)` returns 0 for missing keys, which maps to
        // .welcome — exactly the right default for first-ever launches.
        let rawStep = defaults.integer(forKey: Keys.currentStep)
        self.currentStep = OnboardingStep(rawValue: rawStep) ?? .welcome
    }

    // MARK: - Navigation

    func advance() {
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }

    func goBack() {
        if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
            currentStep = prev
        }
    }

    func jump(to step: OnboardingStep) {
        currentStep = step
    }

    // MARK: - Lifecycle

    func completeOnboarding() {
        hasCompletedOnboarding = true
        // Clear the persisted step so a future re-trigger of the
        // onboarding window (permission revocation path) starts at
        // Welcome rather than All Set.
        currentStep = .welcome
    }
}
