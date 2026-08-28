//
//  OnboardingRouteTests.swift
//  ZerroTests
//
//  Pins the route contract and the one-time migration from the previously
//  shipped six-step flow. These tests let the visual layer evolve without
//  changing resume behavior underneath it.
//

import XCTest
@testable import Zerro

@MainActor
final class OnboardingRouteTests: XCTestCase {
    private static let suiteName = "OnboardingRouteTests"
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

    // MARK: - Route contract

    func testTheOnePathIsSetupKeysPermissionsComplete() {
        XCTAssertEqual(OnboardingPath.allCases, [.byok])
        XCTAssertEqual(
            OnboardingPath.byok.screens,
            [.setup, .keys, .permissions, .complete]
        )
    }

    func testRouteNavigatesWithinThePath() {
        let setup = OnboardingRoute(path: .byok, screen: .setup)
        XCTAssertEqual(setup.progressIndex, 0)
        XCTAssertEqual(setup.nextScreen, .keys)
        XCTAssertNil(setup.previousScreen)

        let permissions = OnboardingRoute(path: .byok, screen: .permissions)
        XCTAssertEqual(permissions.progressIndex, 2)
        XCTAssertEqual(permissions.previousScreen, .keys)
        XCTAssertEqual(permissions.nextScreen, .complete)
    }

    func testLegacyTranscriptionRouteNormalizesToKeys() {
        let route = OnboardingRoute(path: .byok, screen: .transcription)
        XCTAssertEqual(route.screen, .keys)
        XCTAssertEqual(route.progressIndex, 1)
    }

    func testReconsentIsOutsideFirstRunProgress() {
        let route = OnboardingRoute(path: .byok, screen: .reconsent)
        XCTAssertNil(route.progressIndex)
        XCTAssertNil(route.nextScreen)
        XCTAssertNil(route.previousScreen)
    }

    // MARK: - Legacy migration

    func testLegacyStepsMapToRedesignedScreens() {
        let mappings: [(OnboardingStep, OnboardingScreen)] = [
            (.welcome, .setup),
            (.consent, .setup),
            (.email, .setup),
            (.permissions, .permissions),
            (.devMode, .complete),
            (.allSet, .complete),
        ]

        for (legacyStep, expectedScreen) in mappings {
            let route = OnboardingRouteMigration.resolve(
                input(legacyStep: legacyStep)
            )
            XCTAssertEqual(route.path, .byok)
            XCTAssertEqual(route.screen, expectedScreen, "legacy step: \(legacyStep)")
        }
    }

    func testNestedBYOKKeysResumeOnKeys() {
        let route = OnboardingRouteMigration.resolve(
            input(
                legacyStep: .email,
                legacyBYOKPathActive: true,
                legacyBYOKSetupStep: 1
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .keys))
    }

    func testNestedBYOKTranscriptionResumesOnKeys() {
        let route = OnboardingRouteMigration.resolve(
            input(
                legacyStep: .email,
                legacyBYOKPathActive: true,
                legacyBYOKSetupStep: 2
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .keys))
    }

    func testValidStableRouteWinsOverLegacyState() {
        let route = OnboardingRouteMigration.resolve(
            input(
                persistedSchemaVersion: OnboardingRouteMigration.currentSchemaVersion,
                persistedPath: OnboardingPath.byok.rawValue,
                persistedScreen: OnboardingScreen.complete.rawValue,
                legacyStep: .welcome
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .complete))
    }

    func testRetiredPersistedPathFallsBackToLegacyState() {
        // An install that persisted the retired hosted path resumes on the
        // one remaining path from its legacy step, never on a dead screen.
        let route = OnboardingRouteMigration.resolve(
            input(
                persistedSchemaVersion: OnboardingRouteMigration.currentSchemaVersion,
                persistedPath: "free",
                persistedScreen: "mode",
                legacyStep: .permissions
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .permissions))
    }

    func testCorruptStableRouteFallsBackToLegacyState() {
        let route = OnboardingRouteMigration.resolve(
            input(
                persistedSchemaVersion: OnboardingRouteMigration.currentSchemaVersion,
                persistedPath: "unknown-path",
                persistedScreen: "unknown-screen",
                legacyStep: .permissions
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .permissions))
    }

    func testUnknownRouteSchemaFallsBackToLegacyState() {
        let route = OnboardingRouteMigration.resolve(
            input(
                persistedSchemaVersion: 999,
                persistedPath: OnboardingPath.byok.rawValue,
                persistedScreen: OnboardingScreen.complete.rawValue,
                legacyStep: .permissions
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .permissions))
    }

    func testCompletedUserWithStaleTermsRoutesToFocusedReconsent() {
        let route = OnboardingRouteMigration.resolve(
            input(
                legacyStep: .permissions,
                hasCompletedOnboarding: true,
                needsConsent: true
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .reconsent))
    }

    // MARK: - State compatibility bridge

    func testStateMigratesNestedBYOKTranscriptionAndWritesStableKeys() {
        defaults.set(OnboardingStep.email.rawValue, forKey: OnboardingPersistenceKeys.legacyStep)
        defaults.set(true, forKey: OnboardingPersistenceKeys.legacyBYOKPathActive)
        defaults.set(2, forKey: OnboardingPersistenceKeys.legacyBYOKSetupStep)

        let state = OnboardingState(defaults: defaults)

        XCTAssertEqual(state.onboardingPath, .byok)
        XCTAssertEqual(state.currentScreen, .keys)
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.path), "byok")
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.screen), "keys")
        XCTAssertEqual(
            defaults.integer(forKey: OnboardingPersistenceKeys.routeSchemaVersion),
            OnboardingRouteMigration.currentSchemaVersion
        )
    }

    func testStableNavigationPersists() {
        let state = OnboardingState(defaults: defaults)
        XCTAssertEqual(state.progressScreens.count, 4)
        XCTAssertEqual(state.currentScreen, .setup)
        XCTAssertEqual(state.progressIndex, 0)

        state.advanceScreen()
        XCTAssertEqual(state.currentScreen, .keys)
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.screen), "keys")

        state.moveBack()
        XCTAssertEqual(state.currentScreen, .setup)

        state.advanceScreen()
        state.advanceScreen()
        XCTAssertEqual(state.currentScreen, .permissions)
    }

    func testLegacyMainStepNavigationKeepsStableRouteSynchronized() {
        let state = OnboardingState(defaults: defaults)

        state.jump(to: .permissions)
        XCTAssertEqual(state.currentScreen, .permissions)
        XCTAssertEqual(state.onboardingPath, .byok)

        state.jump(to: .allSet)
        XCTAssertEqual(state.currentScreen, .complete)
    }

    private func input(
        persistedSchemaVersion: Int? = nil,
        persistedPath: String? = nil,
        persistedScreen: String? = nil,
        legacyStep: OnboardingStep,
        legacyBYOKPathActive: Bool = false,
        legacyBYOKSetupStep: Int = 0,
        hasCompletedOnboarding: Bool = false,
        needsConsent: Bool = false
    ) -> OnboardingRouteMigration.Input {
        .init(
            persistedSchemaVersion: persistedSchemaVersion,
            persistedPath: persistedPath,
            persistedScreen: persistedScreen,
            legacyStepRawValue: legacyStep.rawValue,
            legacyBYOKPathActive: legacyBYOKPathActive,
            legacyBYOKSetupStep: legacyBYOKSetupStep,
            hasCompletedOnboarding: hasCompletedOnboarding,
            needsConsent: needsConsent
        )
    }
}
