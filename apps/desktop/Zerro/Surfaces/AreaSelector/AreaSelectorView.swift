//
//  AreaSelectorView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  SwiftUI surface for the drag-to-select crosshair overlay that
//  runs before recording begins. Phase 6 Checkpoint 2 drives every
//  geometry from `AreaSelectorState` — the rectangle, the handles,
//  the dimensions readout — and renders nothing selection-related
//  until a drag begins. Mouse events arrive via the NSView event
//  layer in AreaSelectorWindowController and mutate the same state;
//  this view is read-only and never claims hit-testing (the root
//  wrapper in the controller disables it for the entire tree, so
//  events pass through to the AppKit layer underneath).
//
//  Visual-state branches:
//    • No selection (`state.selectionRect == nil`)
//        Dim overlay + instruction pill. The user hasn't pressed
//        mouseDown yet, or just opened the overlay.
//    • Active drag (`state.isDragging == true`)
//        Dim overlay with cutout + selection border + 4 corner
//        handles + live dimensions readout + instruction pill.
//    • Settled (Checkpoint 3 — not yet wired)
//        Same as active drag but with 8 handles (4 corners + 4 edge
//        midpoints) and a confirm affordance.
//

import SwiftUI

struct AreaSelectorView: View {
    let state: AreaSelectorState
    /// Distance from the top of the overlay window's bounds to the top
    /// of the visible (menu-bar-excluded) area. Used to align the
    /// instruction pill with where the recording pill sits — both should
    /// hover 24pt below the menu bar, not 24pt from the top of the
    /// physical screen. Defaults to 0 so previews and any non-overlay
    /// usage render correctly.
    var topInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.size

            ZStack(alignment: .topLeading) {
                switch state.mode {
                case .area:
                    areaModeContent(bounds: bounds)
                case .fullScreen:
                    fullScreenModeContent(bounds: bounds)
                }
                instructionPill(in: bounds)
                recordButton(in: bounds)
                modelMenu(in: bounds)
                micMenu(in: bounds)
                devValidationBanner(in: bounds)
            }
            .frame(width: bounds.width, height: bounds.height)
        }
    }

    @ViewBuilder
    private func areaModeContent(bounds: CGSize) -> some View {
        let selection = state.selectionRect
        dimCutout(bounds: bounds, selection: selection)
        if let selection {
            selectionBorder(at: selection)
            selectionHandles(at: selection)
            dimensionsLabel(at: selection)
        }
    }

    /// Full-screen mode: the whole display is the selection. No dimming —
    /// the entire screen reads as "selected" — with a 1.5pt brand-accent
    /// border tracing the display edge as the only chrome. The floating
    /// toolbar (pinned bottom-center) carries the Record affordance.
    @ViewBuilder
    private func fullScreenModeContent(bounds: CGSize) -> some View {
        Rectangle()
            .strokeBorder(Color.vfBrandAccent, lineWidth: 1.5)
            .frame(width: bounds.width, height: bounds.height)
    }

    // MARK: - Dim cutout
    //
    // Single `Path` with the outer bounds and (optionally) the inner
    // selection, filled with `.eoFill` so the selection stays clear
    // of the dim color. One path is cheaper than four positioned
    // rectangles and avoids subpixel seams along the cutout edges.
    // No `.allowsHitTesting(false)` here — superseded by the root
    // wrapper in AreaSelectorWindowController, which disables it
    // for the entire tree.

    private func dimCutout(bounds: CGSize, selection: CGRect?) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: bounds))
            if let selection {
                path.addRect(selection)
            }
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
    }

    // MARK: - Selection border

    private func selectionBorder(at rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.vfBrandAccent, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Handles
    //
    // Native macOS convention: 4 corners while a drag is in flight, 8
    // (corners + edge midpoints) once the selection is settled. The
    // edge midpoints aren't actionable yet — confirm/cancel is the only
    // exit in C3 — but rendering them is the visual signal that the
    // rectangle is "live" and would be the resize affordance when
    // resize lands. Branching on `state.isDragging` keeps the visual
    // language consistent with macOS Screenshot's behavior.

    private func selectionHandles(at rect: CGRect) -> some View {
        let positions: [CGPoint] = state.isDragging
            ? cornerHandlePositions(at: rect)
            : cornerHandlePositions(at: rect) + edgeMidpointHandlePositions(at: rect)

        return ForEach(positions.indices, id: \.self) { i in
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().strokeBorder(Color.vfOnBrand, lineWidth: 1))
                .frame(width: 8, height: 8)
                .position(positions[i])
        }
    }

    private func cornerHandlePositions(at rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), // top-left
            CGPoint(x: rect.maxX, y: rect.minY), // top-right
            CGPoint(x: rect.maxX, y: rect.maxY), // bottom-right
            CGPoint(x: rect.minX, y: rect.maxY)  // bottom-left
        ]
    }

    private func edgeMidpointHandlePositions(at rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.midX, y: rect.minY), // top
            CGPoint(x: rect.maxX, y: rect.midY), // right
            CGPoint(x: rect.midX, y: rect.maxY), // bottom
            CGPoint(x: rect.minX, y: rect.midY)  // left
        ]
    }

    // MARK: - Dimensions label
    //
    // Reported in points (not backing-store pixels) for consistency
    // with what the user perceives as the selected region — the
    // selection rect is in view-local points, NSScreen.frame is in
    // points, and ScreenCaptureKit's content filters operate in
    // points too. Retina backing-scale conversion belongs to the
    // capture layer, not the readout.

    private func dimensionsLabel(at rect: CGRect) -> some View {
        Text("\(Int(rect.width)) \u{00D7} \(Int(rect.height))")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
            .fixedSize()
            .position(x: rect.maxX - 36, y: rect.maxY - 16)
    }

    // MARK: - Top instruction pill
    //
    // Sized and positioned to match the recording pill (PillView.capsuleWidth/
    // capsuleHeight = 392 × 50, top edge 24pt below the menu bar) so that
    // the area selector and the recording session feel like a continuous
    // surface across the two phases. `topInset` is the menu-bar height in
    // points, supplied by AreaSelectorWindowController — without it we'd
    // be measuring 24pt down from the physical screen top, behind the
    // menu bar.

    private static let pillHeight: CGFloat = 50
    private static let pillTopGap: CGFloat = 24

    private func instructionPill(in bounds: CGSize) -> some View {
        HStack(spacing: VFSpacing.sm) {
            Circle()
                .stroke(Color.vfTextSecondary, lineWidth: 1.2)
                .frame(width: 8, height: 8)
            Text(instructionText)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()
            // Space is a one-way hint shown only in area mode: press it to
            // jump to full screen. Once in full-screen mode there's no
            // toggle back, so the hint is hidden (only esc/cancel remains).
            if state.mode == .area {
                Text("\u{00B7}")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextTertiary)
                KeyCapView(label: "space")
                Text("full screen")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .fixedSize()
            }
            Text("\u{00B7}")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextTertiary)
            KeyCapView(label: "esc")
            Text("cancel")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
        }
        .frame(height: Self.pillHeight)
        .padding(.horizontal, VFSpacing.lg)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 0.5))
        .fixedSize()
        .position(
            x: bounds.width / 2,
            y: topInset + Self.pillTopGap + Self.pillHeight / 2
        )
    }

    private var instructionText: String {
        switch state.mode {
        case .area:
            return "Drag to select an area to narrate"
        case .fullScreen:
            return "Full screen selected \u{00B7} press return to record"
        }
    }

    // MARK: - Floating action toolbar
    //
    // CleanShot-style toolbar anchored just below the settled selection
    // so the user has an obvious click target to start recording (Enter
    // still works, but isn't discoverable) plus a mic picker to choose
    // the input device without opening Settings. Rendered only when
    // `state.confirmableSelectionRect` is non-nil — i.e. a finished area
    // drag meeting the minimum size, or a settled window.
    //
    // The frame geometry lives in static helpers so the controller's
    // mouse monitor can hit-test the exact same rects for clicks and
    // hover (the SwiftUI tree is hit-test-disabled).

    static let toolbarHeight: CGFloat = 40
    static let recordButtonWidth: CGFloat = 116
    static let micChipWidth: CGFloat = 168
    /// Multi-model: the per-recording model dropdown chip, leftmost in the
    /// cluster since the typed-artifact refactor removed the mode toggle.
    static let modelChipWidth: CGFloat = 168
    /// Dev Mode (Phase 1): the agent + folder chips inserted between the mic
    /// chip and Record when the mode switch is on, plus the standalone mode
    /// switch that sits to the cluster's left.
    static let agentChipWidth: CGFloat = 150
    static let folderChipWidth: CGFloat = 168
    static let devToggleWidth: CGFloat = 128
    /// Gap between the standalone Dev Mode switch and the settings cluster —
    /// wider than `toolbarItemGap` so the switch reads as separate, not part
    /// of the cluster.
    private static let devToggleGap: CGFloat = 14
    private static let toolbarItemGap: CGFloat = 8
    private static let toolbarGap: CGFloat = 14
    private static let toolbarMargin: CGFloat = 8

    /// Total settings-cluster width. In Dev Mode the agent + folder chips are
    /// inserted between the mic chip and Record. The standalone mode switch is
    /// NOT part of this width (it floats to the cluster's left); keeping the
    /// cluster's centering identical in normal mode preserves existing layout.
    static func toolbarClusterWidth(devMode: Bool = false) -> CGFloat {
        var width = modelChipWidth + toolbarItemGap + micChipWidth + toolbarItemGap + recordButtonWidth
        if devMode {
            width += agentChipWidth + toolbarItemGap + folderChipWidth + toolbarItemGap
        }
        return width
    }

    /// View-local frame (top-left origin) of the whole floating toolbar.
    ///
    /// In `.area` mode (`fullScreen == false`) it hangs `toolbarGap` below
    /// the selection, flips above if there isn't room, and clamps inside
    /// the overlay bounds. In `.fullScreen` mode the selection IS the whole
    /// display, so anchoring under it would flip awkwardly — instead the
    /// toolbar is pinned bottom-center of the overlay (see
    /// `fullScreenToolbarFrame`). Cluster order, left → right: model chip,
    /// mic chip, Record button.
    static func toolbarFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        if fullScreen { return fullScreenToolbarFrame(in: bounds, devMode: devMode) }

        let size = CGSize(width: toolbarClusterWidth(devMode: devMode), height: toolbarHeight)

        var originY = rect.maxY + toolbarGap
        // Flip above the selection if the toolbar would fall off the
        // bottom of the overlay.
        if originY + size.height + toolbarMargin > bounds.height {
            originY = rect.minY - toolbarGap - size.height
        }
        // As a last resort (selection fills the screen vertically), pin
        // inside the bottom margin.
        if originY < toolbarMargin {
            originY = max(toolbarMargin, bounds.height - size.height - toolbarMargin)
        }

        var originX = rect.midX - size.width / 2
        originX = min(max(originX, toolbarMargin), bounds.width - size.width - toolbarMargin)

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// Full-screen toolbar: pinned bottom-center of the overlay, floating
    /// above the bottom edge by the standard `toolbarMargin`.
    static func fullScreenToolbarFrame(in bounds: CGSize, devMode: Bool = false) -> CGRect {
        let size = CGSize(width: toolbarClusterWidth(devMode: devMode), height: toolbarHeight)
        let originX = (bounds.width - size.width) / 2
        let originY = bounds.height - size.height - toolbarMargin
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// Model-picker chip: leftmost segment of the toolbar (multi-model
    /// per-recording override).
    static func modelChipFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        return CGRect(x: t.minX, y: t.minY, width: modelChipWidth, height: t.height)
    }

    /// Mic-picker chip: second segment of the toolbar, after the model
    /// chip.
    static func micChipFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let x = t.minX + modelChipWidth + toolbarItemGap
        return CGRect(x: x, y: t.minY, width: micChipWidth, height: t.height)
    }

    /// Agent chip: Dev-Mode-only, inserted after the mic chip. The chip is a
    /// confirmation of the auto-detected agent in Phase 1, not a picker.
    static func agentChipFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false) -> CGRect {
        let mic = micChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: true)
        let x = mic.maxX + toolbarItemGap
        return CGRect(x: x, y: mic.minY, width: agentChipWidth, height: mic.height)
    }

    /// Folder chip: Dev-Mode-only, inserted after the agent chip. Shows the
    /// project name or the "Select folder" attention state when unset.
    static func folderChipFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false) -> CGRect {
        let agent = agentChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)
        let x = agent.maxX + toolbarItemGap
        return CGRect(x: x, y: agent.minY, width: folderChipWidth, height: agent.height)
    }

    /// Record button: the right segment of the toolbar.
    static func recordButtonFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        return CGRect(x: t.maxX - recordButtonWidth, y: t.minY, width: recordButtonWidth, height: t.height)
    }

    /// Standalone Dev Mode mode-switch pill. Floats to the cluster's left
    /// (separated by `devToggleGap`), clamped inside the overlay's left
    /// margin. Present in both modes — it's how the user enters/leaves Dev
    /// Mode — so it does not depend on `devMode`.
    ///
    /// KNOWN LIMITATION (Phase 4 — toolbar overflow): on a selection pushed
    /// hard against the left screen edge the margin clamp can park the switch
    /// over the cluster's leading chip. Folds into the icon-compact overflow
    /// work; acceptable for Phase 1's common centered-selection case.
    static func devToggleFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let x = max(toolbarMargin, t.minX - devToggleGap - devToggleWidth)
        return CGRect(x: x, y: t.minY, width: devToggleWidth, height: t.height)
    }

    // MARK: - Mic dropdown geometry
    //
    // The dropdown hangs off the mic chip. Its frame + per-row hit-test
    // live in static helpers so the controller's mouse monitor can map a
    // click to a device row (the SwiftUI tree is hit-test-disabled).

    static let micMenuRowHeight: CGFloat = 30
    private static let micMenuPadding: CGFloat = 6
    private static let micMenuGap: CGFloat = 6

    /// View-local frame of the open dropdown panel, anchored under the
    /// mic chip (flipped above if there isn't room below).
    static func micMenuFrame(forSelection rect: CGRect, in bounds: CGSize, itemCount: Int, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let chip = micChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let height = CGFloat(itemCount) * micMenuRowHeight + micMenuPadding * 2
        let width = micChipWidth

        var originY = chip.maxY + micMenuGap
        if originY + height + toolbarMargin > bounds.height {
            originY = chip.minY - micMenuGap - height
        }
        if originY < toolbarMargin { originY = toolbarMargin }

        return CGRect(x: chip.minX, y: originY, width: width, height: height)
    }

    /// Index of the dropdown row under `point`, or nil if `point` is
    /// outside the panel (or in its vertical padding).
    static func micMenuRowIndex(
        at point: CGPoint,
        forSelection rect: CGRect,
        in bounds: CGSize,
        itemCount: Int,
        fullScreen: Bool = false,
        devMode: Bool = false
    ) -> Int? {
        let frame = micMenuFrame(forSelection: rect, in: bounds, itemCount: itemCount, fullScreen: fullScreen, devMode: devMode)
        guard frame.contains(point) else { return nil }
        let localY = point.y - frame.minY - micMenuPadding
        guard localY >= 0 else { return nil }
        let idx = Int(localY / micMenuRowHeight)
        guard idx >= 0, idx < itemCount else { return nil }
        return idx
    }

    // MARK: - Model dropdown geometry
    //
    // Mirrors the mic dropdown: frame + per-row hit-test in static
    // helpers so the controller's monitor and this view share the exact
    // same rects. Wider than its chip so the per-row credit detail
    // ("4 cr · ~62 left") fits without truncating model names.

    static let modelMenuRowHeight: CGFloat = 30
    static let modelMenuWidth: CGFloat = 248
    private static let modelMenuPadding: CGFloat = 6
    private static let modelMenuGap: CGFloat = 6

    /// View-local frame of the open model dropdown, anchored at the model
    /// chip's leading edge (flipped above if there isn't room below,
    /// clamped inside the overlay horizontally).
    static func modelMenuFrame(forSelection rect: CGRect, in bounds: CGSize, itemCount: Int, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let chip = modelChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let height = CGFloat(itemCount) * modelMenuRowHeight + modelMenuPadding * 2
        let width = modelMenuWidth

        var originY = chip.maxY + modelMenuGap
        if originY + height + toolbarMargin > bounds.height {
            originY = chip.minY - modelMenuGap - height
        }
        if originY < toolbarMargin { originY = toolbarMargin }

        var originX = chip.minX
        originX = min(max(originX, toolbarMargin), bounds.width - width - toolbarMargin)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Index of the model row under `point`, or nil outside the panel.
    static func modelMenuRowIndex(
        at point: CGPoint,
        forSelection rect: CGRect,
        in bounds: CGSize,
        itemCount: Int,
        fullScreen: Bool = false,
        devMode: Bool = false
    ) -> Int? {
        let frame = modelMenuFrame(forSelection: rect, in: bounds, itemCount: itemCount, fullScreen: fullScreen, devMode: devMode)
        guard frame.contains(point) else { return nil }
        let localY = point.y - frame.minY - modelMenuPadding
        guard localY >= 0 else { return nil }
        let idx = Int(localY / modelMenuRowHeight)
        guard idx >= 0, idx < itemCount else { return nil }
        return idx
    }

    @ViewBuilder
    private func modelMenu(in bounds: CGSize) -> some View {
        if state.isModelMenuOpen, let rect = state.confirmableSelectionRect {
            let items = state.models
            let frame = Self.modelMenuFrame(forSelection: rect, in: bounds, itemCount: items.count, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: VFSpacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.vfTextPrimary)
                            .opacity(item.id == state.selectedModelID ? 1 : 0)
                            .frame(width: 12)
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if item.recommended {
                            // "Recommended" capsule badge (the row is tight,
                            // so the badge stays small — 9pt semibold on a
                            // tinted capsule, matching the brand accent).
                            Text("Recommended")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.vfBrandAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule().fill(Color.vfBrandAccent.opacity(0.15))
                                )
                                .fixedSize()
                        }
                        Spacer(minLength: VFSpacing.xs)
                        // `detail` is now only the BYOK "add key" hint (no
                        // per-model cost) — nil otherwise, leaving a clean row.
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.vfTextSecondary)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, VFSpacing.sm)
                    .frame(height: Self.modelMenuRowHeight)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(state.highlightedModelIndex == index && !item.gated
                                  ? Color.primary.opacity(0.12)
                                  : Color.clear)
                    )
                    .opacity(item.gated ? 0.45 : 1)
                }
            }
            .padding(.vertical, Self.modelMenuPadding)
            .frame(width: frame.width, height: frame.height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .position(x: frame.midX, y: frame.midY)
        }
    }

    @ViewBuilder
    private func micMenu(in bounds: CGSize) -> some View {
        if state.isMicMenuOpen, let rect = state.confirmableSelectionRect {
            let items = state.micMenuItems
            let frame = Self.micMenuFrame(forSelection: rect, in: bounds, itemCount: items.count, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: VFSpacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.vfTextPrimary)
                            .opacity(item.id == state.selectedMicrophoneID ? 1 : 0)
                            .frame(width: 12)
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VFSpacing.sm)
                    .frame(height: Self.micMenuRowHeight)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(state.highlightedMicIndex == index
                                  ? Color.primary.opacity(0.12)
                                  : Color.clear)
                    )
                }
            }
            .padding(.vertical, Self.micMenuPadding)
            .frame(width: frame.width, height: frame.height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .position(x: frame.midX, y: frame.midY)
        }
    }

    @ViewBuilder
    private func recordButton(in bounds: CGSize) -> some View {
        if let rect = state.confirmableSelectionRect {
            let fullScreen = state.mode == .fullScreen
            let devMode = state.isDevMode
            let toggleFrame = Self.devToggleFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let modelFrame = Self.modelChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let micFrame = Self.micChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let recFrame = Self.recordButtonFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)

            // Standalone mode switch — always present so the user can enter/
            // leave Dev Mode; floats to the cluster's left.
            devToggleChip
                .frame(width: toggleFrame.width, height: toggleFrame.height)
                .position(x: toggleFrame.midX, y: toggleFrame.midY)

            modelChip
                .frame(width: modelFrame.width, height: modelFrame.height)
                .position(x: modelFrame.midX, y: modelFrame.midY)

            micChip
                .frame(width: micFrame.width, height: micFrame.height)
                .position(x: micFrame.midX, y: micFrame.midY)

            // Dev Mode chips: agent (confirmation) + folder (attention state
            // until set), inserted between the mic chip and Record.
            if devMode {
                let agentFrame = Self.agentChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)
                let folderFrame = Self.folderChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)

                agentChip
                    .frame(width: agentFrame.width, height: agentFrame.height)
                    .position(x: agentFrame.midX, y: agentFrame.midY)

                folderChip
                    .frame(width: folderFrame.width, height: folderFrame.height)
                    .position(x: folderFrame.midX, y: folderFrame.midY)
            }

            recordCapsule
                .frame(width: recFrame.width, height: recFrame.height)
                .position(x: recFrame.midX, y: recFrame.midY)
        }
    }

    // MARK: - Dev Mode toolbar chrome
    //
    // The mode switch + agent/folder chips reuse the mic/model chip chrome so
    // the toolbar reads as one row. Frames come from the same static helpers
    // the controller hit-tests against.

    /// Standalone Dev Mode switch. A leading "wand" glyph + label + an on/off
    /// pip that fills brand-accent when engaged.
    private var devToggleChip: some View {
        HStack(spacing: VFSpacing.xs) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12))
                .foregroundStyle(state.isDevMode ? Color.vfBrandAccent : Color.vfTextSecondary)
            Text("Dev Mode")
                .font(.system(size: 12, weight: state.isDevMode ? .semibold : .regular))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // On/off pip: filled when engaged, hollow when off.
            Circle()
                .fill(state.isDevMode ? Color.vfBrandAccent : Color.clear)
                .overlay(Circle().strokeBorder(Color.vfTextTertiary, lineWidth: state.isDevMode ? 0 : 1))
                .frame(width: 9, height: 9)
        }
        .padding(.horizontal, VFSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule().fill(.ultraThickMaterial)
        )
        .overlay(
            Capsule().strokeBorder(
                state.isDevMode
                    ? Color.vfBrandAccent.opacity(0.6)
                    : (state.isDevToggleHovered ? Color.vfTextSecondary : Color.white.opacity(0.12)),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    /// Agent chip — confirmation of the agent this recording dispatches to.
    /// Phase 1 ships a single agent, so there's no dropdown chevron. When the
    /// agent isn't installed it's an amber attention state ("· install"), and
    /// clicking opens the install docs.
    private var agentChip: some View {
        let missing = state.isAgentMissing
        let detecting = state.isDetectingAgent
        return HStack(spacing: VFSpacing.xs) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(missing ? Color.vfWarningAmber : Color.vfTextSecondary)
            Text(state.selectedAgentName)
                .font(.system(size: 12))
                .foregroundStyle(missing ? Color.vfWarningAmber : Color.vfTextPrimary)
                .opacity(detecting ? 0.6 : 1)
                .lineLimit(1)
                .truncationMode(.tail)
            if detecting {
                Text("· checking")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    .fixedSize()
            } else if missing {
                Text("· install")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfWarningAmber)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule().fill(.ultraThickMaterial)
        )
        .overlay(
            Capsule().strokeBorder(
                missing
                    ? Color.vfWarningAmber.opacity(0.7)
                    : (state.isAgentChipHovered ? Color.vfTextSecondary : Color.white.opacity(0.12)),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    /// Folder chip — the project the agent edits. When unset it's an
    /// amber/dashed attention state ("Select folder"); once set it shows the
    /// project directory name. A SET folder that isn't a git repo (Milestone 7)
    /// also shows an amber attention state with a "· not a git repo" note, since
    /// Dev Mode needs a repo for its checkpoint/revert safety net. Clicking opens
    /// the folder picker.
    private var folderChip: some View {
        let isSet = state.projectDisplayName != nil
        let notRepo = state.isProjectNotGitRepo
        // Amber whenever the folder needs the user's attention: unset, or set
        // but not a git repo.
        let attention = !isSet || notRepo
        return HStack(spacing: VFSpacing.xs) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(attention ? Color.vfWarningAmber : Color.vfTextSecondary)
            Text(state.projectDisplayName ?? "Select folder")
                .font(.system(size: 12))
                .foregroundStyle(attention ? Color.vfWarningAmber : Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if notRepo {
                Text("· not a git repo")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfWarningAmber)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VFSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule().fill(.ultraThickMaterial)
        )
        .overlay(
            Capsule().strokeBorder(
                // Keep the dashed "needs picking" stroke only when unset; a set
                // non-repo folder uses a solid amber stroke (it IS a choice, just
                // a flagged one).
                style: StrokeStyle(lineWidth: 1, dash: isSet ? [] : [4, 3])
            )
            .foregroundStyle(
                attention
                    ? Color.vfWarningAmber.opacity(0.8)
                    : (state.isFolderChipHovered ? Color.vfTextSecondary : Color.white.opacity(0.12))
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    /// Inline record-time validation message (e.g. "Pick a folder…"),
    /// centered just above the toolbar cluster. Dev-Mode-only.
    @ViewBuilder
    private func devValidationBanner(in bounds: CGSize) -> some View {
        if let message = state.devValidationMessage, let rect = state.confirmableSelectionRect {
            let toolbar = Self.toolbarFrame(
                forSelection: rect, in: bounds,
                fullScreen: state.mode == .fullScreen, devMode: state.isDevMode
            )
            HStack(spacing: VFSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfWarningAmber)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize()
            }
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.vfWarningAmber.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
            .position(x: toolbar.midX, y: toolbar.minY - 18)
        }
    }

    /// Model-picker chip — same chrome as the mic chip so the toolbar
    /// reads as one row of controls. Shows the model THIS recording will
    /// use; clicking opens the in-tree dropdown (see modelMenu).
    private var modelChip: some View {
        HStack(spacing: VFSpacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Text(state.selectedModelName)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.vfTextTertiary)
                .rotationEffect(.degrees(state.isModelMenuOpen ? 180 : 0))
        }
        .padding(.horizontal, VFSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule().fill(.ultraThickMaterial)
        )
        .overlay(
            Capsule().strokeBorder(
                state.isModelChipHovered ? Color.vfTextSecondary : Color.white.opacity(0.12),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private var micChip: some View {
        HStack(spacing: VFSpacing.xs) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Text(state.selectedMicrophoneName)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.vfTextTertiary)
                .rotationEffect(.degrees(state.isMicMenuOpen ? 180 : 0))
        }
        .padding(.horizontal, VFSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule().fill(.ultraThickMaterial)
        )
        .overlay(
            Capsule().strokeBorder(
                state.isMicChipHovered ? Color.vfTextSecondary : Color.white.opacity(0.12),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private var recordCapsule: some View {
        HStack(spacing: VFSpacing.sm) {
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
            Text("Record")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Fully opaque so content never bleeds through; the hover
            // affordance is a subtle white tint on top of the solid red
            // rather than an opacity change.
            Capsule()
                .fill(Color.vfRecordingRed)
                .overlay(Capsule().fill(Color.white.opacity(state.isRecordButtonHovered ? 0.12 : 0)))
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

// MARK: - Preview backdrop
//
// SwiftUI-rendered fake macOS app window (Pulse login mockup) used
// only by `#Preview`. Trade-off: a real bundled screenshot in
// `Assets.xcassets` would test the dim/selection contrast against
// truly arbitrary content; this SwiftUI mock is busy enough to
// exercise the same question without requiring a binary asset.
// To swap: drop a PNG into Assets, then replace `PulseLoginBackdrop()`
// below with `Image("areaSelectorPreviewBackdrop").resizable()...`.

private struct PulseLoginBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.10),
                    Color(red: 0.12, green: 0.10, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                trafficLightBar
                formBody
            }
            .frame(width: 420)
            .background(Color(red: 0.13, green: 0.13, blue: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }
    }

    private var trafficLightBar: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(red: 1.00, green: 0.36, blue: 0.36)).frame(width: 10, height: 10)
            Circle().fill(Color(red: 1.00, green: 0.78, blue: 0.20)).frame(width: 10, height: 10)
            Circle().fill(Color(red: 0.30, green: 0.78, blue: 0.40)).frame(width: 10, height: 10)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.18, green: 0.18, blue: 0.22))
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Pulse")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Welcome back. Continue with your work email.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))

            field(label: "EMAIL", value: "you@company.com")
            field(label: "PASSWORD", value: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")

            Text("Must be at least 8 characters with one number and one letter.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
            Text("Forgot password?")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfBrandAccent)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.vfBrandAccent)
                .frame(height: 34)
                .overlay(
                    Text("Sign in")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vfOnBrand)
                )

            HStack(spacing: 6) {
                oauthChip("Google")
                oauthChip("Microsoft")
                oauthChip("SSO")
            }
        }
        .padding(20)
    }

    private func field(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.leading, 10),
                    alignment: .leading
                )
                .frame(height: 30)
        }
    }

    private func oauthChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

// MARK: - Preview
//
// Seeds the preview state with synthetic mouseDown + mouseUp points
// that reproduce the original Phase 2.5 centered 480×240 rectangle.
// Without this seed the preview would render an empty overlay,
// which is correct runtime behavior but uninformative as a design
// snapshot. The 4-handle variant is what renders here (Checkpoint 2);
// the 8-handle settled variant is the Checkpoint 3 reference.

#Preview("Area Selector") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: makePreviewState())
    }
    .frame(width: 640, height: 480)
}

/// Settled-selection variant: the drag has ENDED, so the full floating
/// toolbar renders — model chip, mic chip, Record — the state to eyeball
/// after any frame-math change (the controls must not overlap and the
/// cluster must stay centered under the selection).
#Preview("Settled — toolbar") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: makeSettledPreviewState())
    }
    .frame(width: 1000, height: 640)
}

/// Settled + the model dropdown open.
#Preview("Settled — model menu open") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.toggleModelMenu()
            return s
        }())
    }
    .frame(width: 1000, height: 640)
}

/// Full-screen variant: Space-selected, the whole display reads as
/// selected (brand-accent edge, no dim) with the toolbar pinned
/// bottom-center.
#Preview("Full screen") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.enterFullScreenMode(overlaySize: CGSize(width: 1000, height: 640))
            return s
        }())
    }
    .frame(width: 1000, height: 640)
}

/// Dev Mode on: the cluster grows to model · mic · agent · folder · record
/// with the standalone mode switch floating to its left. Folder unset, so the
/// folder chip shows the amber/dashed "Select folder" attention state.
#Preview("Dev Mode — folder unset") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code", projectURL: nil)
            return s
        }())
    }
    .frame(width: 1200, height: 700)
}

/// Dev Mode on with a folder chosen + a validation message showing — the
/// record-time block state.
#Preview("Dev Mode — folder set + blocked") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.setDevState(
                isDevMode: true, agentID: "claude-code", agentName: "Claude Code",
                projectURL: URL(fileURLWithPath: "/Users/you/Developer/acme-web", isDirectory: true)
            )
            s.setDevValidationMessage("Pick a folder to work in before recording.")
            return s
        }())
    }
    .frame(width: 1200, height: 700)
}

@MainActor
private func makePreviewState() -> AreaSelectorState {
    let s = AreaSelectorState()
    s.beginDrag(at: CGPoint(x: 80, y: 130))
    s.updateDrag(to: CGPoint(x: 560, y: 370))
    return s
}

@MainActor
private func makeSettledPreviewState() -> AreaSelectorState {
    let s = AreaSelectorState()
    s.beginDrag(at: CGPoint(x: 160, y: 110))
    s.updateDrag(to: CGPoint(x: 840, y: 420))
    s.endDrag(at: CGPoint(x: 840, y: 420))
    s.setMicrophones(
        [.init(id: "mic-1", name: "MacBook Pro Microphone")],
        selectedID: "mic-1"
    )
    s.setModels(
        [
            .init(id: "gpt-5.4-mini", name: "GPT-5.4 mini", detail: "2 cr \u{00B7} ~124 left", recommended: false, gated: false),
            .init(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash", detail: "4 cr \u{00B7} ~62 left", recommended: true, gated: false),
            .init(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", detail: "5 cr \u{00B7} ~49 left", recommended: false, gated: false),
            .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", detail: "7 cr \u{00B7} ~35 left", recommended: false, gated: false),
            .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", detail: "10 cr \u{00B7} ~24 left", recommended: false, gated: false),
            .init(id: "gpt-5.5", name: "GPT-5.5", detail: "11 cr \u{00B7} ~22 left", recommended: false, gated: false),
        ],
        selectedID: "gemini-3.5-flash"
    )
    return s
}
