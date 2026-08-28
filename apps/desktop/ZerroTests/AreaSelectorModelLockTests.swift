//
//  AreaSelectorModelLockTests.swift
//  ZerroTests
//
//  Model-selection policy shared by the menu bar and recording start: the
//  persisted choice is honored whenever its provider key is on file, and
//  falls back to a usable provider's model otherwise. Every entitlement
//  state runs on the user's own keys, so the gating is identical across
//  the trial and the license.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorModelLockTests: XCTestCase {
    private let premiumModel = ModelRegistry.all.first { $0.id == "claude-opus-4-7" }!

    private let allStates: [EntitlementState] = [
        .localTrial(daysRemaining: 9),
        .localTrialExpired,
        .byok,
    ]

    func testUnresolvedEntitlementUsesPersistedChoice() {
        XCTAssertEqual(
            ModelSelectionPolicy.effectiveModelID(
                persistedModelID: premiumModel.id,
                entitlement: nil,
                availableProviders: []
            ),
            premiumModel.id
        )
        XCTAssertFalse(
            ModelSelectionPolicy.isBYOKGated(premiumModel, entitlement: nil, availableProviders: [])
        )
    }

    func testEveryStateUsesPersistedChoiceWhenProviderIsAvailable() {
        for entitlement in allStates {
            XCTAssertEqual(
                ModelSelectionPolicy.effectiveModelID(
                    persistedModelID: premiumModel.id,
                    entitlement: entitlement,
                    availableProviders: [.anthropic]
                ),
                premiumModel.id,
                "\(entitlement)"
            )
        }
    }

    func testEveryStateFallsBackToAUsableProviderModel() {
        for entitlement in allStates {
            XCTAssertEqual(
                ModelSelectionPolicy.effectiveModelID(
                    persistedModelID: "gemini-3.5-flash",
                    entitlement: entitlement,
                    availableProviders: [.anthropic]
                ),
                "claude-sonnet-4-6",
                "\(entitlement)"
            )
        }
    }

    func testGatesOnlyProvidersWithoutKeys() {
        for entitlement in allStates {
            XCTAssertTrue(
                ModelSelectionPolicy.isBYOKGated(
                    premiumModel,
                    entitlement: entitlement,
                    availableProviders: [.openai, .gemini]
                ),
                "\(entitlement)"
            )
            XCTAssertFalse(
                ModelSelectionPolicy.isBYOKGated(
                    premiumModel,
                    entitlement: entitlement,
                    availableProviders: [.anthropic]
                ),
                "\(entitlement)"
            )
        }
    }
}
