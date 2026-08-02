//
//  AreaSelectorModelLockTests.swift
//  ZerroTests
//
//  Model-selection policy shared by the menu bar and recording start.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorModelLockTests: XCTestCase {
    private let premiumModel = ModelRegistry.all.first { $0.id == "claude-opus-4-7" }!

    func testTrialUsesFreeModelWithoutOverwritingPersistedChoice() {
        let persisted = premiumModel.id
        let effective = ModelSelectionPolicy.effectiveModelID(
            persistedModelID: persisted,
            entitlement: .trial(creditsRemaining: 15),
            availableProviders: []
        )

        XCTAssertEqual(effective, ModelRegistry.trialModelID)
        XCTAssertEqual(persisted, premiumModel.id)
        XCTAssertTrue(
            ModelSelectionPolicy.isTrialLocked(
                premiumModel,
                entitlement: .trial(creditsRemaining: 15)
            )
        )
    }

    func testManagedAndUnresolvedEntitlementsUsePersistedChoice() {
        let states: [EntitlementState?] = [
            .managed(creditsRemaining: 300, resetDate: Date()), nil,
        ]

        for entitlement in states {
            XCTAssertEqual(
                ModelSelectionPolicy.effectiveModelID(
                    persistedModelID: premiumModel.id,
                    entitlement: entitlement,
                    availableProviders: []
                ),
                premiumModel.id
            )
            XCTAssertFalse(
                ModelSelectionPolicy.isTrialLocked(
                    premiumModel,
                    entitlement: entitlement
                )
            )
        }
    }

    func testBYOKModesUsePersistedChoiceWhenProviderIsAvailable() {
        let states: [EntitlementState] = [
            .byok,
            .byokTrial(generationsRemaining: 9),
            .byokTrialExpired,
        ]

        for entitlement in states {
            XCTAssertEqual(
                ModelSelectionPolicy.effectiveModelID(
                    persistedModelID: premiumModel.id,
                    entitlement: entitlement,
                    availableProviders: [.anthropic]
                ),
                premiumModel.id
            )
        }
    }

    func testBYOKModesFallBackToAUsableProviderModel() {
        for entitlement in [
            EntitlementState.byok,
            .byokTrial(generationsRemaining: 9),
            .byokTrialExpired,
        ] {
            XCTAssertEqual(
                ModelSelectionPolicy.effectiveModelID(
                    persistedModelID: ModelRegistry.trialModelID,
                    entitlement: entitlement,
                    availableProviders: [.anthropic]
                ),
                "claude-sonnet-4-6"
            )
        }
    }

    func testBYOKGatesOnlyProvidersWithoutKeys() {
        XCTAssertTrue(
            ModelSelectionPolicy.isBYOKGated(
                premiumModel,
                entitlement: .byok,
                availableProviders: [.openai, .gemini]
            )
        )
        XCTAssertFalse(
            ModelSelectionPolicy.isBYOKGated(
                premiumModel,
                entitlement: .byok,
                availableProviders: [.anthropic]
            )
        )
        XCTAssertTrue(
            ModelSelectionPolicy.isBYOKGated(
                premiumModel,
                entitlement: .byokTrial(generationsRemaining: 9),
                availableProviders: [.openai, .gemini]
            )
        )
        XCTAssertTrue(
            ModelSelectionPolicy.isBYOKGated(
                premiumModel,
                entitlement: .byokTrialExpired,
                availableProviders: [.openai, .gemini]
            )
        )
        XCTAssertFalse(
            ModelSelectionPolicy.isBYOKGated(
                premiumModel,
                entitlement: .managed(creditsRemaining: 300, resetDate: Date()),
                availableProviders: []
            )
        )
    }
}
