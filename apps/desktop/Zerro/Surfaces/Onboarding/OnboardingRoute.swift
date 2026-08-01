//
//  OnboardingRoute.swift
//  Zerro
//
//  Stable, versioned routing for the redesigned onboarding flow.
//

import Foundation

/// The product path selected on the setup screen. Raw string values are
/// persisted, so they must remain stable across releases.
enum OnboardingPath: String, CaseIterable, Equatable, Hashable {
    case free
    case byok

    /// Production progress order for this path. Re-consent is deliberately not
    /// included: it is a focused returning-user gate, not first-run progress.
    var screens: [OnboardingScreen] {
        switch self {
        case .free:
            return [.setup, .mode, .permissions, .complete]
        case .byok:
            return [.setup, .mode, .keys, .permissions, .complete]
        }
    }
}

/// Stable destinations in the redesigned flow. These string values replace the
/// legacy persisted `OnboardingStep.rawValue`, whose meaning changes whenever a
/// step is inserted or removed.
enum OnboardingScreen: String, CaseIterable, Equatable, Hashable {
    case setup
    case mode
    case keys
    /// Retained only so a partially-completed pre-redesign route can migrate.
    case transcription
    case permissions
    case complete
    case reconsent

    var analyticsName: String { rawValue }
}

/// A normalized persisted route. Keeping normalization pure makes corrupt or
/// partially-written defaults deterministic and easy to pin in tests.
struct OnboardingRoute: Equatable {
    var path: OnboardingPath
    var screen: OnboardingScreen

    init(path: OnboardingPath, screen: OnboardingScreen) {
        self.path = path
        self.screen = Self.normalized(screen: screen, for: path)
    }

    var progressScreens: [OnboardingScreen] { path.screens }

    var progressIndex: Int? {
        progressScreens.firstIndex(of: screen)
    }

    var nextScreen: OnboardingScreen? {
        guard let progressIndex else { return nil }
        let nextIndex = progressIndex + 1
        guard progressScreens.indices.contains(nextIndex) else { return nil }
        return progressScreens[nextIndex]
    }

    var previousScreen: OnboardingScreen? {
        guard let progressIndex else { return nil }
        let previousIndex = progressIndex - 1
        guard progressScreens.indices.contains(previousIndex) else { return nil }
        return progressScreens[previousIndex]
    }

    static func normalized(
        screen: OnboardingScreen,
        for path: OnboardingPath
    ) -> OnboardingScreen {
        if screen == .reconsent { return .reconsent }
        if screen == .transcription, path == .byok { return .keys }
        return path.screens.contains(screen) ? screen : .setup
    }
}

/// Shared defaults keys for the new router and the legacy compatibility bridge.
/// The old keys stay readable through the redesign rollout so an update cannot
/// strand somebody between steps (especially across the Screen Recording kill).
enum OnboardingPersistenceKeys {
    static let routeSchemaVersion = "vf.onboarding.routeSchemaVersion"
    static let path = "vf.onboarding.path"
    static let screen = "vf.onboarding.screen"

    static let legacyCompleted = "vf.onboarding.hasCompletedOnboarding"
    static let legacyStep = "vf.onboarding.currentStep"
    static let legacyBYOKPathActive = "vf.onboarding.byokPathActive"
    static let legacyBYOKSetupStep = "vf.onboarding.byokSetupStep"
}

/// Pure one-time migration from the previously-shipped six-step flow and nested
/// BYOK subflow. The legacy keys remain readable so an interrupted setup can
/// resume safely after updating to the redesigned flow.
enum OnboardingRouteMigration {
    static let currentSchemaVersion = 3

    struct Input: Equatable {
        var persistedSchemaVersion: Int?
        var persistedPath: String?
        var persistedScreen: String?
        var legacyStepRawValue: Int
        var legacyBYOKPathActive: Bool
        var legacyBYOKSetupStep: Int
        var legacyBYOKSelected: Bool
        var hasCompletedOnboarding: Bool
        var needsConsent: Bool
    }

    static func resolve(_ input: Input) -> OnboardingRoute {
        if input.hasCompletedOnboarding, input.needsConsent {
            let persistedPath = input.persistedSchemaVersion == currentSchemaVersion
                ? input.persistedPath.flatMap(OnboardingPath.init(rawValue:))
                : nil
            return OnboardingRoute(path: persistedPath ?? legacyPath(from: input), screen: .reconsent)
        }

        if input.persistedSchemaVersion == currentSchemaVersion,
           let pathRaw = input.persistedPath,
           let screenRaw = input.persistedScreen,
           let path = OnboardingPath(rawValue: pathRaw),
           let screen = OnboardingScreen(rawValue: screenRaw) {
            return OnboardingRoute(path: path, screen: screen)
        }

        let path = legacyPath(from: input)
        let legacyStep = OnboardingStep(rawValue: input.legacyStepRawValue) ?? .welcome

        let screen: OnboardingScreen
        switch legacyStep {
        case .welcome, .consent:
            screen = .setup
        case .email:
            if path == .byok,
               input.legacyBYOKPathActive,
               input.legacyBYOKSetupStep >= 1 {
                screen = .keys
            } else {
                screen = .setup
            }
        case .permissions:
            screen = .permissions
        case .devMode, .allSet:
            screen = .complete
        }

        return OnboardingRoute(path: path, screen: screen)
    }

    private static func legacyPath(from input: Input) -> OnboardingPath {
        input.legacyBYOKPathActive || input.legacyBYOKSelected ? .byok : .free
    }
}
