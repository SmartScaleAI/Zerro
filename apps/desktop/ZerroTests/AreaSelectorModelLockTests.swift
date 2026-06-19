//
//  AreaSelectorModelLockTests.swift
//  ZerroTests
//
//  Trial model-lock — while a user is on the `.trial` entitlement the model
//  picker is locked to the free model (Gemini 3.5 Flash): the chip shows a lock
//  glyph and tapping it opens an upgrade popup instead of the premium model
//  list. `.byok`/`.managed` users keep the full picker. These tests pin:
//    • the lock flag derives from the real EntitlementState (trial only);
//    • the EFFECTIVE model id is forced to the free model while locked, but the
//      raw persisted pick is left untouched (restored on upgrade);
//    • the chip label always reads the free model while locked;
//    • the upgrade popup is mutually exclusive with the toolbar dropdowns;
//    • the popup's button hit-rect sits inside the panel, anchored under the chip.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorModelLockTests: XCTestCase {

    private let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)

    /// A two-model picker seeded with a PREMIUM pick (Claude), so a forced free
    /// model is observable as a change.
    private func makeState(selected: String = "claude-opus-4-7") -> AreaSelectorState {
        let state = AreaSelectorState()
        state.setModels(
            [
                .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", detail: nil, recommended: false, gated: false),
                .init(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash", detail: nil, recommended: true, gated: false),
            ],
            selectedID: selected
        )
        return state
    }

    // MARK: - Lock flag + effective model

    func testTrialLocksPickerToFreeModel() {
        let state = makeState()
        state.setEntitlements(.preview(.trial(creditsRemaining: 15)))

        XCTAssertTrue(state.isModelPickerLocked)
        // Generation runs the free model …
        XCTAssertEqual(state.effectiveModelID, AreaSelectorState.lockedModelID)
        XCTAssertEqual(state.effectiveModelID, "gemini-3.5-flash")
        // … the chip reads the free model …
        XCTAssertEqual(state.selectedModelName, "Gemini 3.5 Flash")
        // … but the raw persisted pick is untouched (restored on upgrade).
        XCTAssertEqual(state.selectedModelID, "claude-opus-4-7")
    }

    func testManagedAndByokAreUnlocked() {
        for entitlement in [EntitlementState.managed(creditsRemaining: 300, resetDate: Date()), .byok] {
            let state = makeState()
            state.setEntitlements(.preview(entitlement))
            XCTAssertFalse(state.isModelPickerLocked)
            XCTAssertEqual(state.effectiveModelID, "claude-opus-4-7")
            XCTAssertEqual(state.selectedModelName, "Claude Opus 4.7")
        }
    }

    func testNoEntitlementStoreIsUnlocked() {
        // Tests/previews construct the state without an entitlement store — it
        // must behave exactly as the pre-lock picker (full list, no lock).
        let state = makeState()
        XCTAssertFalse(state.isModelPickerLocked)
        XCTAssertEqual(state.effectiveModelID, "claude-opus-4-7")
    }

    func testUpgradeRestoresPriorPreference() {
        // A trial→managed conversion (the observable store mutating) flips the
        // lock off and restores the prior preference without re-seeding.
        let store = EntitlementStore.preview(.trial(creditsRemaining: 15))
        let state = makeState()
        state.setEntitlements(store)
        XCTAssertEqual(state.effectiveModelID, "gemini-3.5-flash")

        store.devSetState(.managed(creditsRemaining: 300, resetDate: Date()))
        XCTAssertFalse(state.isModelPickerLocked)
        XCTAssertEqual(state.effectiveModelID, "claude-opus-4-7")
    }

    // MARK: - Mutual exclusion

    func testUpgradePopupIsMutuallyExclusiveWithDropdowns() {
        let state = makeState()
        state.setEntitlements(.preview(.trial(creditsRemaining: 15)))

        state.toggleMicMenu()
        XCTAssertTrue(state.isMicMenuOpen)

        state.toggleUpgradePopup()
        XCTAssertTrue(state.isUpgradePopupOpen)
        XCTAssertFalse(state.isMicMenuOpen)

        // Opening the mic menu in turn dismisses the popup.
        state.toggleMicMenu()
        XCTAssertTrue(state.isMicMenuOpen)
        XCTAssertFalse(state.isUpgradePopupOpen)
    }

    // MARK: - Popup geometry

    func testUpgradePopupAnchorsUnderModelChip() {
        let panel = AreaSelectorView.upgradeMenuFrame(forSelection: selection, in: bounds)
        let model = AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds)
        // Centered under the chip in the un-clamped common case.
        XCTAssertEqual(panel.midX, model.midX, accuracy: 0.5)
        XCTAssertEqual(panel.width, AreaSelectorView.upgradeMenuWidth)
    }

    func testUpgradeButtonRectInsidePanelBottom() {
        let panel = AreaSelectorView.upgradeMenuFrame(forSelection: selection, in: bounds)
        let button = AreaSelectorView.upgradeButtonFrame(forSelection: selection, in: bounds)
        XCTAssertTrue(panel.contains(button))
        // Bottom-anchored, inset by the panel pad — the same place the view's
        // bottom-aligned button renders, so a click lands on it.
        XCTAssertEqual(button.maxY, panel.maxY - AreaSelectorView.upgradeMenuPad, accuracy: 0.5)
        XCTAssertEqual(button.height, AreaSelectorView.upgradeButtonHeight)
    }
}
