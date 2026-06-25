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
        let modelCount = 2
        let icon = AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertEqual(menu.midX, icon.midX, accuracy: 0.001)
        XCTAssertGreaterThan(menu.minY, icon.maxY)
        XCTAssertEqual(menu.width, AreaSelectorView.devMenuWidth)

        let rowsTop = menu.minY + AreaSelectorView.menuVPad + AreaSelectorView.menuSectionHeaderHeight
        let row0 = CGPoint(x: menu.midX, y: rowsTop + AreaSelectorView.devMenuRowHeight / 2)
        XCTAssertEqual(
            AreaSelectorView.devSettingsAgentRowIndex(at: row0, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            0
        )
        let rowLast = CGPoint(x: menu.midX, y: rowsTop + AreaSelectorView.devMenuRowHeight * (CGFloat(agentCount) - 0.5))
        XCTAssertEqual(
            AreaSelectorView.devSettingsAgentRowIndex(at: rowLast, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            agentCount - 1
        )
    }

    func testDevSettingsModelRowsAreBelowAgentSectionAndHitTestDisjoint() {
        let agentCount = 3
        let modelCount = 3
        // The first Model row sits after the Agent header + rows + divider + the
        // Model header.
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        let modelRowsTop = menu.minY + AreaSelectorView.menuVPad
            + AreaSelectorView.menuSectionHeaderHeight + CGFloat(agentCount) * AreaSelectorView.devMenuRowHeight
            + AreaSelectorView.devMenuDividerBand
            + AreaSelectorView.menuSectionHeaderHeight
        let model0 = CGPoint(x: menu.midX, y: modelRowsTop + AreaSelectorView.devMenuRowHeight / 2)
        XCTAssertEqual(
            AreaSelectorView.devSettingsModelRowIndex(at: model0, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            0
        )
        // A model row is NOT an agent row, and vice-versa (sections are disjoint).
        XCTAssertNil(
            AreaSelectorView.devSettingsAgentRowIndex(at: model0, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "a model row must not register as an agent row"
        )
        let agentRow0 = CGPoint(x: menu.midX,
            y: menu.minY + AreaSelectorView.menuVPad + AreaSelectorView.menuSectionHeaderHeight + AreaSelectorView.devMenuRowHeight / 2)
        XCTAssertNil(
            AreaSelectorView.devSettingsModelRowIndex(at: agentRow0, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "an agent row must not register as a model row"
        )
    }

    func testDevSettingsPermissionRowsSitBetweenModelAndProjectAndHitTestDisjoint() {
        let agentCount = 3
        let modelCount = 2
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        // The Permissions section sits after Agent + divider + Model + divider + its
        // own header — between Model and Project.
        let permTop = menu.minY + AreaSelectorView.menuVPad
            + AreaSelectorView.menuSectionHeaderHeight + CGFloat(agentCount) * AreaSelectorView.devMenuRowHeight
            + AreaSelectorView.devMenuDividerBand
            + AreaSelectorView.menuSectionHeaderHeight + CGFloat(modelCount) * AreaSelectorView.devMenuRowHeight
            + AreaSelectorView.devMenuDividerBand
            + AreaSelectorView.menuSectionHeaderHeight
        // Both rows hit-test to their index (0 = Ask Permission, 1 = Auto Approve).
        let row0 = CGPoint(x: menu.midX, y: permTop + AreaSelectorView.devMenuRowHeight / 2)
        let row1 = CGPoint(x: menu.midX, y: permTop + AreaSelectorView.devMenuRowHeight * 1.5)
        XCTAssertEqual(
            AreaSelectorView.devSettingsPermissionRowIndex(at: row0, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            0
        )
        XCTAssertEqual(
            AreaSelectorView.devSettingsPermissionRowIndex(at: row1, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            1
        )
        // A permission row is NOT an agent/model/project row (sections are disjoint).
        for p in [row0, row1] {
            XCTAssertNil(AreaSelectorView.devSettingsAgentRowIndex(at: p, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
                         "a permission row must not register as an agent row")
            XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: p, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
                         "a permission row must not register as a model row")
        }
        // The Project section's Auto-Detect row must sit BELOW the Permissions rows.
        let auto = AreaSelectorView.devSettingsAutoDetectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertGreaterThanOrEqual(auto.minY, permTop + CGFloat(AreaSelectorView.devPermissionRowCount) * AreaSelectorView.devMenuRowHeight)
        XCTAssertNil(AreaSelectorView.devSettingsPermissionRowIndex(at: CGPoint(x: auto.midX, y: auto.midY), forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
                     "the Auto-Detect row must not register as a permission row")
    }

    func testDevSettingsProjectRowIsBelowModelSectionAndDisjoint() {
        let agentCount = 3
        let modelCount = 2
        let projectRow = AreaSelectorView.devSettingsProjectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        // A click in the project row is NOT an agent row nor a model row.
        let mid = CGPoint(x: projectRow.midX, y: projectRow.midY)
        XCTAssertNil(
            AreaSelectorView.devSettingsAgentRowIndex(at: mid, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "the project row must not register as an agent row"
        )
        XCTAssertNil(
            AreaSelectorView.devSettingsModelRowIndex(at: mid, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "the project row must not register as a model row"
        )
        // And it sits below the whole agent + model section.
        let modelSectionBottom = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount).minY
            + AreaSelectorView.menuVPad + AreaSelectorView.menuSectionHeaderHeight
            + CGFloat(agentCount) * AreaSelectorView.devMenuRowHeight
            + AreaSelectorView.devMenuDividerBand
            + AreaSelectorView.menuSectionHeaderHeight
            + CGFloat(modelCount) * AreaSelectorView.devMenuRowHeight
        XCTAssertGreaterThanOrEqual(projectRow.minY, modelSectionBottom)
    }

    // MARK: - Auto-Detect Project toggle row (Project section)

    /// The Project section is two rows (Auto-Detect toggle + Change…), so the menu
    /// height must reserve `header + 2 * rowHeight` for it. The Project section is
    /// now the LAST section — the bottom git-reassurance line was removed (it moved
    /// to a per-row trailing shield icon), so the height ends right after Project.
    /// Pins the reconstructed height in lockstep with `devSettingsMenuFrame`.
    func testDevSettingsMenuAccountsForProjectToggleRow() {
        let agentCount = 3, modelCount = 2
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        let v = AreaSelectorView.self
        let expected = v.menuVPad
            + v.menuSectionHeaderHeight + CGFloat(agentCount) * v.devMenuRowHeight             // Agent
            + v.devMenuDividerBand
            + v.menuSectionHeaderHeight + CGFloat(modelCount) * v.devMenuRowHeight              // Model (≤ cap)
            + v.devMenuDividerBand
            + v.menuSectionHeaderHeight + CGFloat(v.devPermissionRowCount) * v.devMenuRowHeight // Permissions
            + v.devMenuDividerBand
            + v.menuSectionHeaderHeight + 2 * v.devMenuRowHeight                               // Project: toggle + Change… (last section)
            + v.menuVPad
        XCTAssertEqual(menu.height, expected, accuracy: 0.001)
    }

    /// The toggle row leads the Project section; the Change… row sits directly
    /// below it; neither registers as an agent/model row; both fit in the menu.
    func testDevSettingsAutoDetectRowSitsAboveChangeRowAndDisjoint() {
        let agentCount = 3, modelCount = 2
        let auto = AreaSelectorView.devSettingsAutoDetectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        let project = AreaSelectorView.devSettingsProjectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertEqual(project.minY, auto.maxY, accuracy: 0.001, "Change… is directly below the toggle row")
        XCTAssertEqual(auto.height, AreaSelectorView.devMenuRowHeight, accuracy: 0.001)
        XCTAssertEqual(auto.width, project.width, accuracy: 0.001)

        let mid = CGPoint(x: auto.midX, y: auto.midY)
        XCTAssertNil(
            AreaSelectorView.devSettingsAgentRowIndex(at: mid, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "the toggle row must not register as an agent row"
        )
        XCTAssertNil(
            AreaSelectorView.devSettingsModelRowIndex(at: mid, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "the toggle row must not register as a model row"
        )

        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertGreaterThanOrEqual(auto.minY, menu.minY)
        XCTAssertLessThanOrEqual(project.maxY, menu.maxY, "both Project rows fit within the bounded menu")
    }

    /// The info-icon hover sub-rect sits inside the toggle row, immediately after
    /// the reserved label width, vertically centered.
    func testDevSettingsAutoDetectInfoIconWithinRowAfterLabel() {
        let agentCount = 3, modelCount = 2
        let row = AreaSelectorView.devSettingsAutoDetectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        let icon = AreaSelectorView.devSettingsAutoDetectInfoIconRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertTrue(row.contains(icon), "the info-icon sub-rect must sit within the toggle row")
        XCTAssertEqual(icon.minX, row.minX + AreaSelectorView.devMenuRowHPad + AreaSelectorView.autoDetectLabelWidth + AreaSelectorView.autoDetectInfoGap, accuracy: 0.001)
        XCTAssertEqual(icon.midY, row.midY, accuracy: 0.001)
        XCTAssertEqual(icon.width, AreaSelectorView.autoDetectInfoIconSize, accuracy: 0.001)
    }

    /// Hovering the info icon while the dev-settings menu is open resolves the
    /// explanation copy anchored to the icon (the multi-line variant); not hovering
    /// resolves nothing.
    func testAutoDetectInfoTooltipResolvesWhenHoveredInOpenMenu() {
        let state = AreaSelectorState()
        state.setDevMode(true)
        state.toggleDevSettingsMenu()
        XCTAssertTrue(state.isDevSettingsMenuOpen)
        state.setAutoDetectInfoHovered(true)

        let view = AreaSelectorView(state: state)
        let info = view.tooltipInfo(forSelection: selection, in: bounds)
        XCTAssertEqual(info?.text, AreaSelectorView.autoDetectInfoTooltip)
        XCTAssertNotNil(info?.maxWidth, "the info tooltip uses the multi-line variant")
        let expectedAnchor = AreaSelectorView.devSettingsAutoDetectInfoIconRect(
            forSelection: selection, in: bounds,
            agentCount: state.devAgentMenuItems.count, modelCount: state.devModelMenuItems.count
        )
        XCTAssertEqual(info?.anchor, expectedAnchor)

        state.setAutoDetectInfoHovered(false)
        XCTAssertNil(view.tooltipInfo(forSelection: selection, in: bounds)?.text,
                     "no tooltip while the menu is open and the icon isn't hovered")
    }

    /// The Permissions info-icon hover sub-rect sits inside the Permissions header
    /// band (between the Model section and the first permission row), immediately
    /// after the reserved label width.
    func testDevSettingsPermissionInfoIconWithinHeaderAfterLabel() {
        let agentCount = 3, modelCount = 2
        let v = AreaSelectorView.self
        let frame = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        let visibleModelRows = min(modelCount, v.maxVisibleModelRows)
        let headerTop = frame.minY + v.menuVPad
            + v.menuSectionHeaderHeight + CGFloat(agentCount) * v.devMenuRowHeight
            + v.devMenuDividerBand
            + v.menuSectionHeaderHeight + CGFloat(visibleModelRows) * v.devMenuRowHeight
            + v.devMenuDividerBand
        let icon = v.devSettingsPermissionInfoIconRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertEqual(icon.minX, frame.minX + v.devMenuRowHPad + v.permissionsHeaderLabelWidth + v.autoDetectInfoGap, accuracy: 0.001)
        XCTAssertEqual(icon.width, v.autoDetectInfoIconSize, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(icon.minY, headerTop, "the icon sits within the header band")
        XCTAssertLessThanOrEqual(icon.maxY, headerTop + v.menuSectionHeaderHeight, "…and not into the first permission row")
        // It must NOT register as a permission row (the header is above the rows).
        XCTAssertNil(
            v.devSettingsPermissionRowIndex(at: CGPoint(x: icon.midX, y: icon.midY), forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount),
            "the header info icon must not hit-test as a permission row"
        )
    }

    /// Hovering the Permissions info icon while the menu is open resolves the
    /// both-modes explanation anchored to the icon (multi-line variant); not
    /// hovering resolves nothing.
    func testPermissionInfoTooltipResolvesWhenHoveredInOpenMenu() {
        let state = AreaSelectorState()
        state.setDevMode(true)
        state.toggleDevSettingsMenu()
        XCTAssertTrue(state.isDevSettingsMenuOpen)
        state.setPermissionInfoHovered(true)

        let view = AreaSelectorView(state: state)
        let info = view.tooltipInfo(forSelection: selection, in: bounds)
        XCTAssertEqual(info?.text, AreaSelectorView.permissionInfoTooltip)
        XCTAssertNotNil(info?.maxWidth, "the info tooltip uses the multi-line variant")
        let expectedAnchor = AreaSelectorView.devSettingsPermissionInfoIconRect(
            forSelection: selection, in: bounds,
            agentCount: state.devAgentMenuItems.count, modelCount: state.devModelMenuItems.count
        )
        XCTAssertEqual(info?.anchor, expectedAnchor)

        state.setPermissionInfoHovered(false)
        XCTAssertNil(view.tooltipInfo(forSelection: selection, in: bounds)?.text,
                     "no tooltip while the menu is open and the icon isn't hovered")
    }

    // MARK: - Permission row trailing indicators (git-shield / ⚠)

    /// Each permission row's trailing-icon hover sub-rect sits at the row's right
    /// inset edge, vertically centered, the configured size — and still hit-tests as
    /// that permission row (so clicking the icon selects the tier).
    func testPermissionTrailingIconRectsAlignToRowsAndStaySelectable() {
        let agentCount = 3, modelCount = 2
        let v = AreaSelectorView.self
        let frame = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        for row in 0..<v.devPermissionRowCount {
            let icon = v.devSettingsPermissionTrailingIconRect(
                forSelection: selection, in: bounds,
                agentCount: agentCount, modelCount: modelCount, rowIndex: row)
            XCTAssertEqual(icon.width, v.permissionTrailingIconSize, accuracy: 0.001)
            XCTAssertEqual(icon.height, v.permissionTrailingIconSize, accuracy: 0.001)
            // Right inset edge: maxX == row right edge (frame.maxX - hPad).
            XCTAssertEqual(icon.maxX, frame.maxX - v.devMenuRowHPad, accuracy: 0.001)
            // Vertically centered on its row (the row that hit-tests the icon center).
            let hit = v.devSettingsPermissionRowIndex(
                at: CGPoint(x: icon.midX, y: icon.midY),
                forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
            XCTAssertEqual(hit, row, "clicking the trailing icon must still select its tier (row \(row))")
        }
    }

    /// Hovering a fenced tier's trailing icon resolves the git-snapshot copy;
    /// hovering Unrestricted's resolves the can't-undo warning; both anchor to the
    /// icon (multi-line variant). Not hovering resolves nothing.
    func testPermissionTrailingTooltipResolvesPerTier() {
        let state = AreaSelectorState()
        state.setDevMode(true)
        state.toggleDevSettingsMenu()
        let view = AreaSelectorView(state: state)
        let v = AreaSelectorView.self
        let aCount = state.devAgentMenuItems.count, mCount = state.devModelMenuItems.count

        // Row 0 (Ask Permission) + Row 1 (Auto-Approve) → git-snapshot copy.
        for fenced in [0, 1] {
            state.setHoveredPermissionTrailingIndex(fenced)
            let info = view.tooltipInfo(forSelection: selection, in: bounds)
            XCTAssertEqual(info?.text, v.permissionGitSnapshotTooltip)
            XCTAssertNotNil(info?.maxWidth, "trailing tooltip uses the multi-line variant")
            XCTAssertEqual(info?.anchor, v.devSettingsPermissionTrailingIconRect(
                forSelection: selection, in: bounds, agentCount: aCount, modelCount: mCount, rowIndex: fenced))
        }

        // Row 2 (Unrestricted) → the warning copy.
        state.setHoveredPermissionTrailingIndex(2)
        let warn = view.tooltipInfo(forSelection: selection, in: bounds)
        XCTAssertEqual(warn?.text, v.permissionUnrestrictedTooltip)
        XCTAssertNotEqual(warn?.text, v.permissionGitSnapshotTooltip)

        // Not hovering → nothing (menu open, no icon under the cursor).
        state.setHoveredPermissionTrailingIndex(nil)
        XCTAssertNil(view.tooltipInfo(forSelection: selection, in: bounds)?.text)
    }

    /// The bottom git-reassurance copy now lives ONLY as the fenced rows' trailing
    /// tooltip — verbatim the old line — so the wording didn't silently change.
    func testGitSnapshotCopyPreservedVerbatim() {
        XCTAssertEqual(AreaSelectorView.permissionGitSnapshotTooltip,
                       "Snapshots with git before each change — undo anything.")
    }

    // MARK: - Scrollable Model section (long lists, e.g. Cursor)

    private func devModels(_ n: Int) -> [AreaSelectorState.DevModelMenuItem] {
        (0..<n).map { .init(id: "m\($0)", name: "Model \($0)") }
    }

    func testDevSettingsMenuHeightIsBoundedForLongModelList() {
        let agentCount = 3
        let cap = AreaSelectorView.maxVisibleModelRows
        let atCap = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: cap)
        let huge = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: cap + 50)
        // Beyond the cap the Model section stops growing — the panel height is bounded.
        XCTAssertEqual(atCap.height, huge.height, accuracy: 0.001)
        // Which is the whole point: it fits on screen.
        XCTAssertGreaterThanOrEqual(huge.minY, 0)
        XCTAssertLessThanOrEqual(huge.maxY, bounds.height)
    }

    func testDevSettingsModelRowHitTestFoldsInScrollOffset() {
        let agentCount = 3, modelCount = 20
        let cap = AreaSelectorView.maxVisibleModelRows
        let rowH = AreaSelectorView.devMenuRowHeight
        let viewport = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertEqual(viewport.height, CGFloat(cap) * rowH, accuracy: 0.001, "viewport is capped at maxVisibleModelRows")

        let top = CGPoint(x: viewport.midX, y: viewport.minY + rowH / 2)
        // The SAME screen position maps to offset+0 as the list scrolls under it.
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: top, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: 0), 0)
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: top, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: 5), 5)
        // Last visible row at max offset → the last model (in-bounds, clamped).
        let maxOffset = modelCount - cap
        let last = CGPoint(x: viewport.midX, y: viewport.minY + rowH * (CGFloat(cap) - 0.5))
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: last, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: maxOffset), modelCount - 1)
    }

    func testDevSettingsModelHitTestRejectsBelowViewport() {
        let agentCount = 3, modelCount = 20
        let viewport = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        // A point just below the capped viewport is Project/git territory now.
        let below = CGPoint(x: viewport.midX, y: viewport.maxY + 1)
        XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: below, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: 0))
        // And the Project row sits at/below the capped viewport, not below all 20 rows.
        let project = AreaSelectorView.devSettingsProjectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertGreaterThanOrEqual(project.minY, viewport.maxY)
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertLessThanOrEqual(project.maxY, menu.maxY, "the project row is reachable within the bounded menu")
    }

    func testDevSettingsShortModelListBehavesAsBefore() {
        // ≤ cap: viewport is exactly modelCount rows, offset 0, hit-test unchanged.
        let agentCount = 3, modelCount = 3
        let rowH = AreaSelectorView.devMenuRowHeight
        let viewport = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount)
        XCTAssertEqual(viewport.height, CGFloat(modelCount) * rowH, accuracy: 0.001)
        let row2 = CGPoint(x: viewport.midX, y: viewport.minY + rowH * 2.5)
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: row2, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount), 2)
        let past = CGPoint(x: viewport.midX, y: viewport.minY + rowH * CGFloat(modelCount) + 1)
        XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: past, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount))
    }

    func testDevModelScrollOffsetClampsToRange() {
        let state = AreaSelectorState()
        let cap = AreaSelectorView.maxVisibleModelRows
        state.setDevModelMenuItems(devModels(cap + 5), selectedID: "m0")   // reveals m0 → offset 0
        XCTAssertEqual(state.devModelScrollOffset, 0)
        state.setDevModelScrollOffset(100)
        XCTAssertEqual(state.devModelScrollOffset, 5, "offset pins to modelCount - cap")
        state.setDevModelScrollOffset(-3)
        XCTAssertEqual(state.devModelScrollOffset, 0)
    }

    func testDevModelScrollOffsetReclampsWhenListShrinks() {
        let state = AreaSelectorState()
        let cap = AreaSelectorView.maxVisibleModelRows
        state.setDevModelMenuItems(devModels(cap + 10), selectedID: "m0")
        state.setDevModelScrollOffset(8)
        XCTAssertEqual(state.devModelScrollOffset, 8)
        // The list swaps to a short one (agent change) → can't scroll → resets.
        state.setDevModelMenuItems(devModels(2), selectedID: "m0")
        XCTAssertEqual(state.devModelScrollOffset, 0)
    }

    func testDevModelScrollRevealsSelectionOnOpen() {
        let state = AreaSelectorState()
        let cap = AreaSelectorView.maxVisibleModelRows
        let count = cap + 10
        // A pick deep in the list is revealed when the list is set…
        state.setDevModelMenuItems(devModels(count), selectedID: "m\(count - 1)")
        XCTAssertEqual(state.devModelScrollOffset, count - cap)
        // …and again whenever the menu (re)opens, even after scrolling away.
        state.setDevModelScrollOffset(0)
        state.toggleDevSettingsMenu()
        XCTAssertTrue(state.isDevSettingsMenuOpen)
        XCTAssertEqual(state.devModelScrollOffset, count - cap, "reopening reveals the selected model")
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
