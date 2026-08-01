//
//  OnboardingRouteTests.swift
//  ZerroTests
//
//  Pins the redesigned route contract and the one-time migration from the
//  currently-shipped six-step flow. These tests allow the visual refactor to
//  happen in later phases without changing resume behavior underneath it.
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

    func testManagedPathUsesSharedEmailThenModeSelection() {
        XCTAssertEqual(OnboardingPath.free.screens, [.setup, .mode, .permissions, .complete])
    }

    func testBYOKPathAddsKeysButNoTranscriptionChoice() {
        XCTAssertEqual(
            OnboardingPath.byok.screens,
            [.setup, .mode, .keys, .permissions, .complete]
        )
    }

    func testRouteNavigatesWithinItsSelectedPath() {
        let setup = OnboardingRoute(path: .byok, screen: .setup)
        XCTAssertEqual(setup.progressIndex, 0)
        XCTAssertEqual(setup.nextScreen, .mode)
        XCTAssertNil(setup.previousScreen)

        let permissions = OnboardingRoute(path: .byok, screen: .permissions)
        XCTAssertEqual(permissions.progressIndex, 3)
        XCTAssertEqual(permissions.previousScreen, .keys)
        XCTAssertEqual(permissions.nextScreen, .complete)
    }

    func testLegacyTranscriptionRouteNormalizesToBYOKKeys() {
        let byok = OnboardingRoute(path: .byok, screen: .transcription)
        XCTAssertEqual(byok.screen, .keys)

        let route = OnboardingRoute(path: .free, screen: .transcription)
        XCTAssertEqual(route.screen, .setup)
        XCTAssertEqual(route.progressIndex, 0)
    }

    func testReconsentIsOutsideFirstRunProgress() {
        let route = OnboardingRoute(path: .free, screen: .reconsent)
        XCTAssertNil(route.progressIndex)
        XCTAssertNil(route.nextScreen)
        XCTAssertNil(route.previousScreen)
    }

    // MARK: - Legacy migration

    func testLegacyFreeStepsMapToRedesignedScreens() {
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
            XCTAssertEqual(route.path, .free)
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

    func testPreviouslySelectedBYOKTrialRetainsPathAfterLegacyFlagWasCleared() {
        let route = OnboardingRouteMigration.resolve(
            input(legacyStep: .permissions, legacyBYOKSelected: true)
        )
        XCTAssertEqual(route, OnboardingRoute(path: .byok, screen: .permissions))
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

    func testCorruptStableRouteFallsBackToLegacyState() {
        let route = OnboardingRouteMigration.resolve(
            input(
                persistedSchemaVersion: OnboardingRouteMigration.currentSchemaVersion,
                persistedPath: "unknown-path",
                persistedScreen: "unknown-screen",
                legacyStep: .permissions
            )
        )
        XCTAssertEqual(route, OnboardingRoute(path: .free, screen: .permissions))
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
        XCTAssertEqual(route, OnboardingRoute(path: .free, screen: .permissions))
    }

    func testCompletedUserWithStaleTermsRoutesToFocusedReconsent() {
        let route = OnboardingRouteMigration.resolve(
            input(
                legacyStep: .permissions,
                legacyBYOKSelected: true,
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

    func testStableNavigationPersistsAndUsesDynamicPathOrder() {
        let state = OnboardingState(defaults: defaults)

        state.selectPath(.byok)
        XCTAssertEqual(state.progressScreens.count, 5)
        XCTAssertEqual(state.currentScreen, .mode)
        XCTAssertEqual(state.progressIndex, 1)

        state.advanceScreen()
        XCTAssertEqual(state.currentScreen, .keys)
        XCTAssertEqual(defaults.string(forKey: OnboardingPersistenceKeys.screen), "keys")

        state.moveBack()
        XCTAssertEqual(state.currentScreen, .mode)

        state.selectPath(.free)
        state.advanceScreen()
        XCTAssertEqual(state.currentScreen, .permissions)
        XCTAssertEqual(state.progressScreens.count, 4)
    }

    func testLegacyMainStepNavigationKeepsStableRouteSynchronized() {
        let state = OnboardingState(defaults: defaults)
        state.selectPath(.byok)

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
        legacyBYOKSelected: Bool = false,
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
            legacyBYOKSelected: legacyBYOKSelected,
            hasCompletedOnboarding: hasCompletedOnboarding,
            needsConsent: needsConsent
        )
    }
}
