//
//  AreaSelectorDevModeTests.swift
//  ZerroTests
//
//  Dev Mode — the compact toolbar's Dev affordances: the single dev-settings
//  icon it grows (folding the old agent +
//  folder chips into one menu), the consolidated agent/project menu geometry,
//  and the state semantics (explicit set-mode, the dev-settings menu, the
//  auto-open guard, readiness, and the record-time validation gate). Like the
//  rest of the toolbar, none of the geometry is a SwiftUI HStack: every rect
//  comes from static frame helpers the view renders with AND the controller
//  hit-tests against. These tests pin:
//    • the cluster grows by exactly ONE icon button (dev-settings) in Dev Mode;
//    • cluster order dev-settings → record, both disjoint;
//    • the dev-settings menu's agent rows + project row hit-test back;
//    • normal-mode geometry is byte-identical to Ask mode;
//    • the state-level set-mode / menu / auto-open / validation semantics.
//

import XCTest
@testable import Zerro

@MainActor
final class AreaSelectorDevModeTests: XCTestCase {

    private let selection = CGRect(x: 300, y: 200, width: 700, height: 400)
    private let bounds = CGSize(width: 1728, height: 1080)

    private func enableDev(_ state: AreaSelectorState) {
        state.setDevState(
            isDevMode: true,
            agentID: state.selectedAgentID,
            agentName: state.selectedAgentName,
            projectURL: state.projectURL
        )
    }

    // MARK: - Cluster width + order

    func testDevModeClusterAddsExactlyOneIconButton() {
        let normal = AreaSelectorView.toolbarClusterWidth(devMode: false)
        let dev = AreaSelectorView.toolbarClusterWidth(devMode: true)
        XCTAssertGreaterThan(dev, normal)
        let added = dev - normal
        // One new icon button + the gap before Record.
        let devSettings = AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: true)
        let gap = record.minX - devSettings.maxX
        XCTAssertEqual(added, AreaSelectorView.iconButtonWidth + gap, accuracy: 0.001)
    }

    func testClusterOrderDevSettingsRecord() {
        let devSettings = AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: true)
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: true)

        XCTAssertLessThan(devSettings.maxX, record.minX, "record sits after dev-settings")
        XCTAssertEqual(record.maxX, toolbar.maxX - (devSettings.minX - toolbar.minX), accuracy: 0.001,
                       "Record and Dev settings have symmetric outer insets")

        // Every control is disjoint and inside the toolbar.
        let frames = [devSettings, record]
        for (i, a) in frames.enumerated() {
            XCTAssertTrue(toolbar.contains(a), "control \(i) escapes the toolbar")
            for (j, b) in frames.enumerated() where i < j {
                XCTAssertFalse(a.intersects(b), "controls \(i) and \(j) overlap")
            }
        }
    }

    func testAskModeContainsOnlyRecord() {
        let record = AreaSelectorView.recordButtonFrame(forSelection: selection, in: bounds, devMode: false)
        let toolbar = AreaSelectorView.toolbarFrame(forSelection: selection, in: bounds, devMode: false)
        XCTAssertEqual(record.midX, toolbar.midX, accuracy: 0.001)
        XCTAssertEqual(record.midY, toolbar.midY, accuracy: 0.001)
    }

    // MARK: - Dev-settings accordion geometry (compact summary rows)

    /// Collapsed by default: centers under the icon; the three summary rows
    /// (Agent / Model / Permissions) stack above the Project section; NO option row
    /// is hit-testable until its section is expanded.
    func testDevMenuCollapsedSummaryRowsAndNoOptions() {
        let a = 3, m = 2
        let icon = AreaSelectorView.devSettingsIconFrame(forSelection: selection, in: bounds)
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m)
        XCTAssertEqual(menu.midX, icon.midX, accuracy: 0.001)
        XCTAssertGreaterThan(menu.minY, icon.maxY)

        let agent = AreaSelectorView.devSettingsSummaryRowFrame(.agent, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil)
        let model = AreaSelectorView.devSettingsSummaryRowFrame(.model, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil)
        let perms = AreaSelectorView.devSettingsSummaryRowFrame(.permissions, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil)
        // Agent leads directly under the top inset (no section header now).
        XCTAssertEqual(agent.minY, menu.minY + AreaSelectorView.menuVPad, accuracy: 0.001)
        for s in [agent, model, perms] {
            XCTAssertEqual(s.height, AreaSelectorView.devMenuRowHeight, accuracy: 0.001)
            XCTAssertEqual(s.width, menu.width, accuracy: 0.001)
        }
        // One rowHeight + divider apart, in order.
        XCTAssertEqual(model.minY, agent.maxY + AreaSelectorView.devMenuDividerBand, accuracy: 0.001)
        XCTAssertEqual(perms.minY, model.maxY + AreaSelectorView.devMenuDividerBand, accuracy: 0.001)
        // Collapsed → no option rows are hit-testable.
        for s in [agent, model, perms] {
            let p = CGPoint(x: s.midX, y: s.midY)
            XCTAssertNil(AreaSelectorView.devSettingsAgentRowIndex(at: p, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil))
            XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: p, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil))
            XCTAssertNil(AreaSelectorView.devSettingsPermissionRowIndex(at: p, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil))
        }
    }

    /// Collapsed height = vPad + 3 summary rows + 3 dividers + Project (header + 2
    /// rows) + vPad — and independent of agent/model counts (sections collapsed).
    func testDevMenuCollapsedHeightIsCompactAndCountIndependent() {
        let v = AreaSelectorView.self
        let menu = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: 3, modelCount: 2)
        let expected = v.menuVPad
            + v.devMenuRowHeight + v.devMenuDividerBand           // Agent summary
            + v.devMenuRowHeight + v.devMenuDividerBand           // Model summary
            + v.devMenuRowHeight + v.devMenuDividerBand           // Permissions summary
            + v.menuSectionHeaderHeight + 2 * v.devMenuRowHeight  // Project
            + v.menuVPad
        XCTAssertEqual(menu.height, expected, accuracy: 0.001)
        let bigger = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: 9, modelCount: 40)
        XCTAssertEqual(menu.height, bigger.height, accuracy: 0.001, "collapsed menu doesn't grow with more agents/models")
    }

    /// Expanding Agent reveals agentCount option rows under the Agent summary; the
    /// Model summary shifts down; options are disjoint from the model section.
    func testDevMenuExpandedAgentHitTestsOptions() {
        let a = 3, m = 2
        let exp = AreaSelectorState.DevMenuSection.agent
        let agentSummary = AreaSelectorView.devSettingsSummaryRowFrame(.agent, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)
        for i in 0..<a {
            let p = CGPoint(x: agentSummary.midX, y: agentSummary.maxY + (CGFloat(i) + 0.5) * AreaSelectorView.devMenuRowHeight)
            XCTAssertEqual(AreaSelectorView.devSettingsAgentRowIndex(at: p, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp), i)
            XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: p, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp))
        }
        let model = AreaSelectorView.devSettingsSummaryRowFrame(.model, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)
        XCTAssertGreaterThanOrEqual(model.minY, agentSummary.maxY + CGFloat(a) * AreaSelectorView.devMenuRowHeight)
        // The summary row itself is not an option row.
        XCTAssertNil(AreaSelectorView.devSettingsAgentRowIndex(at: CGPoint(x: agentSummary.midX, y: agentSummary.midY), forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp))
    }

    /// Expanding Permissions reveals the 3 tier rows under the Permissions summary;
    /// each hit-tests to its tier index; disjoint from the summary + Project.
    func testDevMenuExpandedPermissionsHitTestsTiers() {
        let a = 3, m = 2
        let exp = AreaSelectorState.DevMenuSection.permissions
        let summary = AreaSelectorView.devSettingsSummaryRowFrame(.permissions, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)
        for i in 0..<AreaSelectorView.devPermissionRowCount {
            let p = CGPoint(x: summary.midX, y: summary.maxY + (CGFloat(i) + 0.5) * AreaSelectorView.devMenuRowHeight)
            XCTAssertEqual(AreaSelectorView.devSettingsPermissionRowIndex(at: p, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp), i)
        }
        XCTAssertNil(AreaSelectorView.devSettingsPermissionRowIndex(at: CGPoint(x: summary.midX, y: summary.midY), forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp))
        let auto = AreaSelectorView.devSettingsAutoDetectRowFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)
        XCTAssertGreaterThanOrEqual(auto.minY, summary.maxY + CGFloat(AreaSelectorView.devPermissionRowCount) * AreaSelectorView.devMenuRowHeight)
    }

    /// Only the expanded section grows the menu (by its option count); the others
    /// stay one summary row.
    func testDevMenuOnlyExpandedSectionGrows() {
        let v = AreaSelectorView.self
        let a = 3, m = 2
        let collapsed = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil).height
        let agentOpen = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: .agent).height
        let permsOpen = v.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: .permissions).height
        XCTAssertEqual(agentOpen - collapsed, CGFloat(a) * v.devMenuRowHeight, accuracy: 0.001)
        XCTAssertEqual(permsOpen - collapsed, CGFloat(v.devPermissionRowCount) * v.devMenuRowHeight, accuracy: 0.001)
    }

    // MARK: - Permissions summary safety icon (git-shield / ⚠)

    /// The safety icon sits on the Permissions SUMMARY row, to the LEFT of the
    /// disclosure chevron, vertically centered — present collapsed AND expanded,
    /// and never registers as a tier option (it's hover-only).
    func testDevMenuPermissionSafetyIconOnSummaryRow() {
        let v = AreaSelectorView.self
        let a = 3, m = 2
        for exp in [nil, AreaSelectorState.DevMenuSection.permissions] {
            let summary = v.devSettingsSummaryRowFrame(.permissions, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)
            let icon = v.devSettingsPermissionSafetyIconRect(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)
            XCTAssertEqual(icon.width, v.permissionTrailingIconSize, accuracy: 0.001)
            XCTAssertTrue(summary.contains(icon), "safety icon within the summary row")
            // Right edge == chevron-left (one chevron + gap inside the right inset).
            XCTAssertEqual(icon.maxX, summary.maxX - v.devMenuRowHPad - v.devSummaryChevronWidth - v.devSummaryTrailingGap, accuracy: 0.001)
            XCTAssertEqual(icon.midY, summary.midY, accuracy: 0.001)
            XCTAssertNil(v.devSettingsPermissionRowIndex(at: CGPoint(x: icon.midX, y: icon.midY), forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp))
        }
    }

    /// Hovering the safety icon resolves the current tier's copy: git-snapshot for
    /// the fenced tiers, the can't-undo warning for Unrestricted; anchored to the
    /// icon (multi-line). Not hovering → nothing.
    func testDevMenuPermissionSafetyTooltipPerTier() {
        let state = AreaSelectorState()
        enableDev(state)
        state.toggleDevSettingsMenu()
        let view = AreaSelectorView(state: state)
        let v = AreaSelectorView.self
        let a = state.devAgentMenuItems.count, m = state.devModelMenuItems.count

        for tier in [DevPermissionTier.askPermission, .autoApprove] {
            state.setDevPermissionTier(tier)
            state.setPermissionSafetyHovered(true)
            let info = view.tooltipInfo(forSelection: selection, in: bounds)
            XCTAssertEqual(info?.text, v.permissionGitSnapshotTooltip)
            XCTAssertNotNil(info?.maxWidth, "safety tooltip uses the multi-line variant")
            XCTAssertEqual(info?.anchor, v.devSettingsPermissionSafetyIconRect(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: state.expandedDevSection))
        }
        state.setDevPermissionTier(.unrestricted)
        XCTAssertEqual(view.tooltipInfo(forSelection: selection, in: bounds)?.text, v.permissionUnrestrictedTooltip)

        state.setPermissionSafetyHovered(false)
        XCTAssertNil(view.tooltipInfo(forSelection: selection, in: bounds)?.text)
    }

    /// When Permissions is expanded, EACH option row's safety icon (a) column-aligns
    /// with the summary safety icon and (b) resolves ITS OWN tier's tooltip on hover.
    func testDevMenuExpandedOptionSafetyIconsAlignAndTooltip() {
        let state = AreaSelectorState()
        enableDev(state)
        state.toggleDevSettingsMenu()
        state.toggleDevSection(.permissions)
        let view = AreaSelectorView(state: state)
        let v = AreaSelectorView.self
        let a = state.devAgentMenuItems.count, m = state.devModelMenuItems.count
        let exp = AreaSelectorState.DevMenuSection.permissions
        let summaryIcon = v.devSettingsPermissionSafetyIconRect(forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp)

        for row in 0..<v.devPermissionRowCount {
            let icon = v.devSettingsPermissionOptionSafetyIconRect(forSelection: selection, in: bounds, agentCount: a, modelCount: m, rowIndex: row, expanded: exp)
            // Same column as the summary icon; one rowHeight apart down the list.
            XCTAssertEqual(icon.minX, summaryIcon.minX, accuracy: 0.001, "option icon shares the summary icon's column")
            XCTAssertEqual(icon.width, v.permissionTrailingIconSize, accuracy: 0.001)
            // Hovering it resolves THAT tier's copy, anchored to the icon.
            state.setHoveredPermissionOptionSafety(row)
            let info = view.tooltipInfo(forSelection: selection, in: bounds)
            let expected = DevPermissionTier.allCases[row] == .unrestricted ? v.permissionUnrestrictedTooltip : v.permissionGitSnapshotTooltip
            XCTAssertEqual(info?.text, expected, "row \(row) tooltip copy")
            XCTAssertEqual(info?.anchor, icon)
            XCTAssertNotNil(info?.maxWidth)
            // The hover icon is non-interactive: its center still hit-tests as the
            // tier option (clicking it selects the tier).
            XCTAssertEqual(v.devSettingsPermissionRowIndex(at: CGPoint(x: icon.midX, y: icon.midY), forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: exp), row)
        }
        state.setHoveredPermissionOptionSafety(nil)
        XCTAssertNil(view.tooltipInfo(forSelection: selection, in: bounds)?.text)
    }

    /// The bottom git-reassurance copy now lives ONLY as the Permissions safety
    /// tooltip — pinned verbatim so the wording can't silently change.
    func testGitSnapshotCopyPreservedVerbatim() {
        XCTAssertEqual(AreaSelectorView.permissionGitSnapshotTooltip,
                       "Snapshots with git before each change, so you can undo anything.")
    }

    // MARK: - Accordion behavior (state)

    /// Toggling a section expands it (collapsing any other); toggling again — or
    /// collapseDevSections() — resets to summary rows. Opening the menu starts
    /// collapsed.
    func testDevMenuAccordionTogglesOneSectionAtATime() {
        let state = AreaSelectorState()
        enableDev(state)
        state.toggleDevSettingsMenu()
        XCTAssertNil(state.expandedDevSection, "menu opens collapsed")
        state.toggleDevSection(.agent)
        XCTAssertEqual(state.expandedDevSection, .agent)
        state.toggleDevSection(.permissions)
        XCTAssertEqual(state.expandedDevSection, .permissions, "expanding one collapses the other")
        state.toggleDevSection(.permissions)
        XCTAssertNil(state.expandedDevSection, "toggling the open section collapses it")
        state.toggleDevSection(.model)
        state.collapseDevSections()
        XCTAssertNil(state.expandedDevSection)
    }

    // MARK: - Auto-Detect / Project rows (Project section, unchanged)

    /// Auto-Detect leads the Project section (below the 3 summary rows); Change…
    /// sits directly below; the info icon lands after the label, centered.
    func testDevMenuProjectRowsBelowSummariesWithInfoIcon() {
        let a = 3, m = 2
        let auto = AreaSelectorView.devSettingsAutoDetectRowFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m)
        let project = AreaSelectorView.devSettingsProjectRowFrame(forSelection: selection, in: bounds, agentCount: a, modelCount: m)
        XCTAssertEqual(project.minY, auto.maxY, accuracy: 0.001, "Change… directly below Auto-Detect")
        XCTAssertEqual(auto.height, AreaSelectorView.devMenuRowHeight, accuracy: 0.001)
        let perms = AreaSelectorView.devSettingsSummaryRowFrame(.permissions, forSelection: selection, in: bounds, agentCount: a, modelCount: m, expanded: nil)
        XCTAssertGreaterThan(auto.minY, perms.maxY)
        let icon = AreaSelectorView.devSettingsAutoDetectInfoIconRect(forSelection: selection, in: bounds, agentCount: a, modelCount: m)
        XCTAssertTrue(auto.contains(icon))
        XCTAssertEqual(icon.minX, auto.minX + AreaSelectorView.devMenuRowHPad + AreaSelectorView.autoDetectLabelWidth + AreaSelectorView.autoDetectInfoGap, accuracy: 0.001)
        XCTAssertEqual(icon.midY, auto.midY, accuracy: 0.001)
    }

    /// Hovering the Auto-Detect info icon resolves its copy anchored to the icon.
    func testAutoDetectInfoTooltipResolvesWhenHoveredInOpenMenu() {
        let state = AreaSelectorState()
        enableDev(state)
        state.toggleDevSettingsMenu()
        state.setAutoDetectInfoHovered(true)
        let view = AreaSelectorView(state: state)
        let info = view.tooltipInfo(forSelection: selection, in: bounds)
        XCTAssertEqual(info?.text, AreaSelectorView.autoDetectInfoTooltip)
        XCTAssertNotNil(info?.maxWidth)
        XCTAssertEqual(info?.anchor, AreaSelectorView.devSettingsAutoDetectInfoIconRect(
            forSelection: selection, in: bounds,
            agentCount: state.devAgentMenuItems.count, modelCount: state.devModelMenuItems.count,
            expanded: state.expandedDevSection))
        state.setAutoDetectInfoHovered(false)
        XCTAssertNil(view.tooltipInfo(forSelection: selection, in: bounds)?.text)
    }


    // MARK: - Scrollable Model section (long lists, e.g. Cursor)

    private func devModels(_ n: Int) -> [AreaSelectorState.DevModelMenuItem] {
        (0..<n).map { .init(id: "m\($0)", name: "Model \($0)") }
    }

    /// When the Model section is EXPANDED, its option list caps at
    /// `maxVisibleModelRows` (scrolls beyond), so a long list can't push the panel
    /// off-screen.
    func testDevSettingsExpandedModelHeightIsBoundedForLongList() {
        let agentCount = 3
        let cap = AreaSelectorView.maxVisibleModelRows
        let atCap = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: cap, expanded: .model)
        let huge = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: cap + 50, expanded: .model)
        XCTAssertEqual(atCap.height, huge.height, accuracy: 0.001, "the expanded Model list stops growing at the cap")
        XCTAssertGreaterThanOrEqual(huge.minY, 0)
        XCTAssertLessThanOrEqual(huge.maxY, bounds.height)
    }

    func testDevSettingsModelRowHitTestFoldsInScrollOffset() {
        let agentCount = 3, modelCount = 20
        let cap = AreaSelectorView.maxVisibleModelRows
        let rowH = AreaSelectorView.devMenuRowHeight
        let viewport = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model)
        XCTAssertEqual(viewport.height, CGFloat(cap) * rowH, accuracy: 0.001, "viewport is capped at maxVisibleModelRows")

        let top = CGPoint(x: viewport.midX, y: viewport.minY + rowH / 2)
        // The SAME screen position maps to offset+0 as the list scrolls under it.
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: top, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: 0, expanded: .model), 0)
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: top, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: 5, expanded: .model), 5)
        // Last visible row at max offset → the last model (in-bounds, clamped).
        let maxOffset = modelCount - cap
        let last = CGPoint(x: viewport.midX, y: viewport.minY + rowH * (CGFloat(cap) - 0.5))
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: last, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: maxOffset, expanded: .model), modelCount - 1)
    }

    func testDevSettingsModelHitTestRejectsBelowViewport() {
        let agentCount = 3, modelCount = 20
        let viewport = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model)
        // A point just below the capped viewport is Permissions/Project territory.
        let below = CGPoint(x: viewport.midX, y: viewport.maxY + 1)
        XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: below, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, scrollOffset: 0, expanded: .model))
        // The Project row sits below the capped viewport, not below all 20 rows.
        let project = AreaSelectorView.devSettingsProjectRowFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model)
        XCTAssertGreaterThanOrEqual(project.minY, viewport.maxY)
        let menu = AreaSelectorView.devSettingsMenuFrame(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model)
        XCTAssertLessThanOrEqual(project.maxY, menu.maxY, "the project row is reachable within the bounded menu")
    }

    func testDevSettingsShortModelListShowsAllRowsWhenExpanded() {
        // ≤ cap: the expanded viewport is exactly modelCount rows, offset 0.
        let agentCount = 3, modelCount = 3
        let rowH = AreaSelectorView.devMenuRowHeight
        let viewport = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model)
        XCTAssertEqual(viewport.height, CGFloat(modelCount) * rowH, accuracy: 0.001)
        let row2 = CGPoint(x: viewport.midX, y: viewport.minY + rowH * 2.5)
        XCTAssertEqual(AreaSelectorView.devSettingsModelRowIndex(at: row2, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model), 2)
        let past = CGPoint(x: viewport.midX, y: viewport.minY + rowH * CGFloat(modelCount) + 1)
        XCTAssertNil(AreaSelectorView.devSettingsModelRowIndex(at: past, forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: .model))
        // Collapsed → the viewport is empty (no model options shown).
        let collapsed = AreaSelectorView.devSettingsModelViewportRect(forSelection: selection, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: nil)
        XCTAssertEqual(collapsed.height, 0, accuracy: 0.001)
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

    // MARK: - State: dev-settings menu + auto-open

    func testDevSettingsMenuToggles() {
        let state = AreaSelectorState()
        state.toggleDevSettingsMenu()
        XCTAssertTrue(state.isDevSettingsMenuOpen)
        state.toggleDevSettingsMenu()
        XCTAssertFalse(state.isDevSettingsMenuOpen)
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
