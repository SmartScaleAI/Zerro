//
//  AreaSelectorDevModeTests.swift
//  ZerroTests
//
//  Dev Mode — the compact toolbar's Dev affordances: the mode switch's Dev
//  segment, the single dev-settings icon it grows (folding the old agent +
//  folder chips into one menu), the consolidated agent/project menu geometry,
//  and the state semantics (explicit set-mode, the dev-settings menu, the
//  auto-open guard, readiness, and the record-time validation gate). Like the
//  rest of the toolbar, none of the geometry is a SwiftUI HStack: every rect
//  comes from static frame helpers the view renders with AND the controller
//  hit-tests against. These tests pin:
//    • the cluster grows by exactly ONE icon button (dev-settings) in Dev Mode;
//    • cluster order model → mic → dev-settings → record, all disjoint;
//    • the dev-settings menu's agent rows + project row hit-test back;
//    • normal-mode geometry is byte-identical to Artifact mode;
//    • the state-level set-mode / menu / auto-open / validation semantics.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorDevModeTests: XCTestCase {

    private let selection = CGRect(x: 300, y: 200, width: 700, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)

    // MARK: - Cluster width + order

    func testDevModeClusterAddsExactlyOneIconButton() {
        let normal = AreaSelectorView.toolbarClusterWidth(devMode: false)
        let dev = AreaSelectorView.toolbarClusterWidth(devMode: true)
        XCTAssertGreaterThan(dev, normal)
        let added = dev - normal
        // One new icon button + its leading gap (== the model→mic gap).
        let model = AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds)
        let mic = AreaSelectorView.micChipFrame(forSelection: selection, in: bounds)
        let gap = mic.minX - model.maxX
        XCTAssertEqual(added, AreaSelectorView.iconButtonWidth + gap, accuracy: 0.001)
    }

    func testClusterOrderModelMicDevSettingsRecord() {
        let model = AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds, devMode: true)
        let mic = AreaSelectorView.micChipFrame(forSelection: selection, in: bounds, devMode: true)
        let devSettings = AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: true)
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: true)
        let modeSwitch = AreaSelectorView.devToggleFrame(forSelection: selection, in: bounds, devMode: true)

        let gap = mic.minX - model.maxX
        XCTAssertLessThan(modeSwitch.maxX, model.minX, "the mode switch leads the cluster")
        XCTAssertEqual(devSettings.minX, mic.maxX + gap, accuracy: 0.001)
        XCTAssertLessThan(devSettings.maxX, record.minX, "record sits after dev-settings")
        XCTAssertEqual(record.maxX, toolbar.maxX - (modeSwitch.minX - toolbar.minX), accuracy: 0.001,
                       "Record is inset from the trailing edge by the same margin the switch is from the leading edge")

        // Every control is disjoint and inside the toolbar.
        let frames = [modeSwitch, model, mic, devSettings, record]
        for (i, a) in frames.enumerated() {
            XCTAssertTrue(toolbar.contains(a), "control \(i) escapes the toolbar")
            for (j, b) in frames.enumerated() where i < j {
                XCTAssertFalse(a.intersects(b), "controls \(i) and \(j) overlap")
            }
        }
    }

    func testModeSwitchSitsInsideToolbarInBothModes() {
        // The mode switch is now an in-container control (not floating left); it
        // must resolve inside the toolbar in both modes since it's how you enter
        // and leave Dev Mode.
        for devMode in [false, true] {
            let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: devMode)
            let modeSwitch = AreaSelectorView.devToggleFrame(forSelection: selection, in: bounds, devMode: devMode)
            XCTAssertTrue(toolbar.contains(modeSwitch), "mode switch must sit inside the toolbar (devMode: \(devMode))")
            XCTAssertEqual(modeSwitch.width, AreaSelectorView.modeSwitchWidth)
        }
    }

    // MARK: - Normal-mode geometry is unchanged by the devMode param

    func testArtifactModeHasNoDevSettingsBetweenMicAndRecord() {
        let mic = AreaSelectorView.micChipFrame(forSelection: selection, in: bounds, devMode: false)
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: false)
        // In Artifact mode Record butts up right after mic (one gap), with no
        // dev-settings icon between them.
        let gap = record.minX - mic.maxX
        XCTAssertGreaterThan(gap, 0)
        XCTAssertLessThan(gap, AreaSelectorView.iconButtonWidth,
                          "no icon-button-sized control sits between mic and Record in Artifact mode")
    }

    // MARK: - Dev-settings menu geometry

    func testDevSettingsMenuCentersUnderIconAndHitTestsAgentRows() {
        let agentCount = 3
        let icon = AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount)
        XCTAssertEqual(menu.midX, icon.midX, accuracy: 0.001)
        XCTAssertGreaterThan(menu.minY, icon.maxY)
        XCTAssertEqual(menu.width, AreaSelectorView.devMenuWidth)

        let rowsTop = menu.minY + AreaSelectorView.menuVPad + AreaSelectorView.menuSectionHeaderHeight
        let row0 = CGPoint(x: menu.midX, y: rowsTop + AreaSelectorView.devMenuRowHeight / 2)
        XCTAssertEqual(
            AreaSelectorView.devSettingsAgentRowIndex(at: row0, forSelection: selection, in: bounds, agentCount: agentCount),
            0
        )
        let rowLast = CGPoint(x: menu.midX, y: rowsTop + AreaSelectorView.devMenuRowHeight * (CGFloat(agentCount) - 0.5))
        XCTAssertEqual(
            AreaSelectorView.devSettingsAgentRowIndex(at: rowLast, forSelection: selection, in: bounds, agentCount: agentCount),
            agentCount - 1
        )
    }

    func testDevSettingsProjectRowIsBelowAgentSectionAndDisjoint() {
        let agentCount = 3
        let projectRow = AreaSelectorView.devSettingsProjectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount)
        // A click in the project row is NOT an agent row.
        let mid = CGPoint(x: projectRow.midX, y: projectRow.midY)
        XCTAssertNil(
            AreaSelectorView.devSettingsAgentRowIndex(at: mid, forSelection: selection, in: bounds, agentCount: agentCount),
            "the project row must not register as an agent row"
        )
        // And it sits below the whole agent section.
        let lastAgentBottom = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount).minY
            + AreaSelectorView.menuVPad + AreaSelectorView.menuSectionHeaderHeight
            + CGFloat(agentCount) * AreaSelectorView.devMenuRowHeight
        XCTAssertGreaterThanOrEqual(projectRow.minY, lastAgentBottom)
    }

    // MARK: - State: explicit set-mode

    func testSetDevModeMapsSegmentsToModeAndClearsOnOff() {
        let state = AreaSelectorState()
        XCTAssertFalse(state.isDevMode)

        state.setDevMode(true)
        XCTAssertTrue(state.isDevMode)
        state.setDevMode(true) // re-clicking the active segment is a no-op
        XCTAssertTrue(state.isDevMode)

        state.setDevValidationMessage("blocked")
        state.toggleDevSettingsMenu()
        XCTAssertTrue(state.isDevSettingsMenuOpen)

        state.setDevMode(false)
        XCTAssertFalse(state.isDevMode)
        XCTAssertNil(state.devValidationMessage, "turning Dev off clears the validation message")
        XCTAssertFalse(state.isDevSettingsMenuOpen, "turning Dev off closes the dev-settings menu")
    }

    func testToggleDevModeFlipsAndClearsMessageWhenOff() {
        let state = AreaSelectorState()
        XCTAssertFalse(state.isDevMode)
        state.setDevValidationMessage("blocked")

        state.toggleDevMode() // on — keeps any message (Dev Mode is now active)
        XCTAssertTrue(state.isDevMode)

        state.setDevValidationMessage("blocked again")
        state.toggleDevMode() // off — message is irrelevant, cleared
        XCTAssertFalse(state.isDevMode)
        XCTAssertNil(state.devValidationMessage)
    }

    // MARK: - State: dev-settings menu + auto-open

    func testDevSettingsMenuIsOneOfAtMostOneOpenDropdown() {
        let state = AreaSelectorState()
        state.toggleModelMenu()
        XCTAssertTrue(state.isModelMenuOpen)
        state.toggleDevSettingsMenu()
        XCTAssertTrue(state.isDevSettingsMenuOpen)
        XCTAssertFalse(state.isModelMenuOpen, "opening dev-settings closes the model menu")

        state.toggleMicMenu()
        XCTAssertTrue(state.isMicMenuOpen)
        XCTAssertFalse(state.isDevSettingsMenuOpen, "opening the mic menu closes dev-settings")
    }

    func testDevSettingsAutoOpensFirstEntryOrWhenFolderUnset() {
        // Folder SET: opens on the first entry, stays closed on the next.
        let withFolder = AreaSelectorState()
        withFolder.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code",
                               projectURL: URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        withFolder.handleDevModeEntered()
        XCTAssertTrue(withFolder.isDevSettingsMenuOpen, "first Dev entry auto-opens the menu")
        withFolder.closeDevSettingsMenu()
        withFolder.handleDevModeEntered()
        XCTAssertFalse(withFolder.isDevSettingsMenuOpen, "a later entry with a folder set stays closed")

        // Folder UNSET: opens every entry until the folder is chosen.
        let noFolder = AreaSelectorState()
        noFolder.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code", projectURL: nil)
        noFolder.handleDevModeEntered()
        XCTAssertTrue(noFolder.isDevSettingsMenuOpen)
        noFolder.closeDevSettingsMenu()
        noFolder.handleDevModeEntered()
        XCTAssertTrue(noFolder.isDevSettingsMenuOpen, "an unset folder re-opens the menu each entry")
    }

    func testDevReadyReflectsAgentAndFolder() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: nil, agentName: "Claude Code", projectURL: nil)
        XCTAssertFalse(state.isDevReady, "no agent + no folder → not ready")

        state.setSelectedAgent(id: "claude-code", name: "Claude Code")
        XCTAssertFalse(state.isDevReady, "agent only → not ready")

        state.setProjectURL(URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        XCTAssertTrue(state.isDevReady, "agent + folder → ready")
    }

    func testDevAgentMenuItemsAreSettable() {
        let state = AreaSelectorState()
        XCTAssertTrue(state.devAgentMenuItems.isEmpty)
        state.setDevAgentMenuItems([
            .init(id: "claude-code", name: "Claude Code", installed: true),
            .init(id: "codex", name: "Codex", installed: false),
        ])
        XCTAssertEqual(state.devAgentMenuItems.count, 2)
        XCTAssertEqual(state.devAgentMenuItems.first?.id, "claude-code")
        XCTAssertTrue(state.devAgentMenuItems.first?.installed == true)
    }

    // MARK: - State: validation gate

    func testDevRequirementsGate() {
        let state = AreaSelectorState()
        // Normal mode never gates.
        XCTAssertTrue(state.devRequirementsMet)

        state.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code", projectURL: nil)
        XCTAssertFalse(state.devRequirementsMet, "no folder → blocked")

        state.setProjectURL(URL(fileURLWithPath: "/tmp/project", isDirectory: true))
        XCTAssertTrue(state.devRequirementsMet, "agent + folder → allowed")

        state.setSelectedAgent(id: nil, name: "Claude Code")
        XCTAssertFalse(state.devRequirementsMet, "no agent → blocked")
    }

    func testSetProjectURLClearsValidationMessage() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code", projectURL: nil)
        state.setDevValidationMessage("Pick a folder to work in before recording.")
        XCTAssertNotNil(state.devValidationMessage)
        state.setProjectURL(URL(fileURLWithPath: "/tmp/project", isDirectory: true))
        XCTAssertNil(state.devValidationMessage)
        XCTAssertEqual(state.projectDisplayName, "project")
    }

    // MARK: - Folder git-repo attention (Milestone 7)

    func testGitRepoAttentionIsNonBlockingAndStateful() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code", projectURL: nil)
        state.setProjectURL(URL(fileURLWithPath: "/tmp/project", isDirectory: true))

        // Unknown (probe not yet landed): no attention, and requirements ARE met
        // — the git check is non-blocking (the dispatch's checkpoint is the hard
        // gate, not the chip).
        XCTAssertNil(state.projectIsGitRepo)
        XCTAssertFalse(state.isProjectNotGitRepo)
        XCTAssertTrue(state.devRequirementsMet)

        // Probe lands "not a repo" → attention shows, but recording is STILL
        // allowed (non-blocking warning).
        state.setProjectGitRepo(false)
        XCTAssertTrue(state.isProjectNotGitRepo)
        XCTAssertFalse(state.isCheckingGitRepo)
        XCTAssertTrue(state.devRequirementsMet)

        // A real repo clears the attention.
        state.setProjectGitRepo(true)
        XCTAssertFalse(state.isProjectNotGitRepo)
    }

    func testPickingNewFolderResetsGitRepoVerdict() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code",
                          projectURL: URL(fileURLWithPath: "/tmp/a", isDirectory: true))
        state.setProjectGitRepo(false)
        XCTAssertTrue(state.isProjectNotGitRepo)

        // Picking a different folder invalidates the prior verdict until the new
        // probe lands (so a stale "not a repo" can't linger on the new folder).
        state.setProjectURL(URL(fileURLWithPath: "/tmp/b", isDirectory: true))
        XCTAssertNil(state.projectIsGitRepo)
        XCTAssertFalse(state.isProjectNotGitRepo)
    }

    func testGitRepoAttentionInertInNormalMode() {
        let state = AreaSelectorState()
        // Not in Dev Mode → never an attention state, whatever the verdict.
        state.setProjectGitRepo(false)
        XCTAssertFalse(state.isProjectNotGitRepo)
    }
}
