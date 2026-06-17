//
//  AreaSelectorDevModeTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 1) — the toolbar's mode switch, the
//  agent/folder chips it grows, and the record-time validation gate. Like
//  the rest of the toolbar, none of this is a SwiftUI HStack: every control's
//  rect comes from static frame helpers the view renders with AND the
//  controller hit-tests against, so an arithmetic slip means overlapping
//  chrome or clicks on the wrong control. These tests pin:
//    • the cluster grows by exactly agent + folder (gap-separated) in Dev Mode;
//    • cluster order model → mic → agent → folder → record, all disjoint;
//    • the standalone mode switch floats to the cluster's left;
//    • normal-mode geometry is byte-identical to before (devMode defaults off);
//    • the state-level toggle + validation semantics.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorDevModeTests: XCTestCase {

    private let selection = CGRect(x: 300, y: 200, width: 700, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)

    // MARK: - Cluster width + order

    func testDevModeClusterAddsAgentAndFolder() {
        let normal = AreaSelectorView.toolbarClusterWidth(devMode: false)
        let dev = AreaSelectorView.toolbarClusterWidth(devMode: true)
        // The cluster grows by agent + folder plus their two leading gaps.
        XCTAssertGreaterThan(dev, normal)
        let added = dev - normal
        // Two new chips + two new gaps (gap == the existing 8pt item gap, which
        // we recover from the model→mic spacing in normal mode).
        let model = AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds)
        let mic = AreaSelectorView.micChipFrame(forSelection: selection, in: bounds)
        let gap = mic.minX - model.maxX
        XCTAssertEqual(added,
                       AreaSelectorView.agentChipWidth + AreaSelectorView.folderChipWidth + gap * 2,
                       accuracy: 0.001)
    }

    func testClusterOrderModelMicAgentFolderRecord() {
        let model = AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds, devMode: true)
        let mic = AreaSelectorView.micChipFrame(forSelection: selection, in: bounds, devMode: true)
        let agent = AreaSelectorView.agentChipFrame(forSelection: selection, in: bounds)
        let folder = AreaSelectorView.folderChipFrame(forSelection: selection, in: bounds)
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: true)
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: true)

        let gap = mic.minX - model.maxX
        XCTAssertEqual(model.minX, toolbar.minX, accuracy: 0.001)
        XCTAssertEqual(agent.minX, mic.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(folder.minX, agent.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(record.minX, folder.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(record.maxX, toolbar.maxX, accuracy: 0.001)

        // Every segment is disjoint and inside the toolbar.
        let frames = [model, mic, agent, folder, record]
        for (i, a) in frames.enumerated() {
            XCTAssertTrue(toolbar.contains(a), "segment \(i) escapes the toolbar")
            for (j, b) in frames.enumerated() where i < j {
                XCTAssertFalse(a.intersects(b), "segments \(i) and \(j) overlap")
            }
        }
    }

    func testDevToggleFloatsLeftOfClusterAndDisjoint() {
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: true)
        let toggle = AreaSelectorView.devToggleFrame(forSelection: selection, in: bounds, devMode: true)
        XCTAssertEqual(toggle.width, AreaSelectorView.devToggleWidth)
        XCTAssertLessThan(toggle.maxX, toolbar.minX, "mode switch must sit left of the cluster")
        XCTAssertFalse(toggle.intersects(toolbar))
        XCTAssertEqual(toggle.minY, toolbar.minY, accuracy: 0.001, "switch is vertically aligned with the cluster")
    }

    /// The mode switch exists in BOTH modes (it's how you enter Dev Mode), so
    /// its frame must resolve even when devMode is false.
    func testDevToggleResolvesInNormalMode() {
        let toggle = AreaSelectorView.devToggleFrame(forSelection: selection, in: bounds, devMode: false)
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: false)
        XCTAssertLessThan(toggle.maxX, toolbar.minX)
    }

    // MARK: - Normal-mode geometry is unchanged

    func testNormalModeToolbarUnchangedByDevModeParam() {
        // The default (devMode: false) must produce the exact same cluster the
        // pre-Dev-Mode helpers did — model + mic + record only.
        let model = AreaSelectorView.modelChipFrame(forSelection: selection, in: bounds)
        let mic = AreaSelectorView.micChipFrame(forSelection: selection, in: bounds)
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds)
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds)
        let gap = mic.minX - model.maxX
        XCTAssertEqual(toolbar.width,
                       model.width + gap + mic.width + gap + record.width,
                       accuracy: 0.001)
        XCTAssertEqual(record.maxX, toolbar.maxX, accuracy: 0.001)
    }

    // MARK: - State: toggle + validation

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
