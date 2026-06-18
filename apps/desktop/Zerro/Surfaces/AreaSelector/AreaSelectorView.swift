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

import AppKit
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
                // Keep the dynamic model-button width current with the selected
                // model BEFORE any frame helper reads it this pass (the model
                // button carries the model name). Plain static, not observed
                // state — covers previews too, where no controller runs.
                let _ = (Self.modelButtonWidth = Self.measuredModelButtonWidth(forName: state.selectedModelName))
                switch state.mode {
                case .area:
                    areaModeContent(bounds: bounds)
                case .fullScreen:
                    fullScreenModeContent(bounds: bounds)
                }
                instructionPill(in: bounds)
                floatingToolbar(in: bounds)
                modelMenu(in: bounds)
                micMenu(in: bounds)
                devSettingsMenu(in: bounds)
                devValidationBanner(in: bounds)
                toolbarTooltip(in: bounds)
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
            .strokeBorder(state.isDevMode ? Color.vfDevAccent : Color.vfBrandAccent, lineWidth: 1.5)
            .frame(width: bounds.width, height: bounds.height)
            .devBreathingPulse(state.isDevMode)
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
            .stroke(state.isDevMode ? Color.vfDevAccent : Color.vfBrandAccent, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .devBreathingPulse(state.isDevMode)
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

    @ViewBuilder
    private func selectionHandles(at rect: CGRect) -> some View {
        if state.isDevMode {
            devViewfinderHandles(at: rect)
        } else {
            let positions: [CGPoint] = state.isDragging
                ? cornerHandlePositions(at: rect)
                : cornerHandlePositions(at: rect) + edgeMidpointHandlePositions(at: rect)

            ForEach(positions.indices, id: \.self) { i in
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().strokeBorder(Color.vfOnBrand, lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .position(positions[i])
            }
        }
    }

    /// Dev-Mode corner handles: L-shaped viewfinder brackets (two strokes per
    /// corner) in the accent green, replacing the filled white squares for the
    /// "camera viewfinder / inspector" read. Drawn as one stroked `Path` of
    /// eight short arms (cheaper than eight positioned shapes, and the absolute
    /// coordinates align to the full overlay bounds exactly like `dimCutout`).
    /// Edge-midpoint handles (settled state only) stay as small green squares so
    /// the 8-handle "selection is live" signal survives.
    private func devViewfinderHandles(at rect: CGRect) -> some View {
        let arm: CGFloat = 14
        let midpoints = state.isDragging ? [] : edgeMidpointHandlePositions(at: rect)
        return ZStack {
            Path { p in
                // (corner, end of horizontal arm, end of vertical arm) — arms
                // always point inward from each corner.
                let brackets: [(CGPoint, CGPoint, CGPoint)] = [
                    (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + arm, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY + arm)),
                    (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX - arm, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + arm)),
                    (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - arm, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY - arm)),
                    (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX + arm, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - arm))
                ]
                for (corner, hEnd, vEnd) in brackets {
                    p.move(to: hEnd)
                    p.addLine(to: corner)
                    p.addLine(to: vEnd)
                }
            }
            .stroke(Color.vfDevAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(midpoints.indices, id: \.self) { i in
                Rectangle()
                    .fill(Color.vfDevAccent)
                    .frame(width: 6, height: 6)
                    .position(midpoints[i])
            }
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
            .foregroundStyle(state.isDevMode ? Color.vfOnBrand : Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state.isDevMode ? Color.vfDevAccent : Color.black.opacity(0.6))
            )
            .fixedSize()
            .position(x: rect.maxX - 36, y: rect.maxY - 16)
    }

    // MARK: - Top instruction pill
    //
    // Sized and positioned to match the recording pill (PillView.capsuleWidth/
    // capsuleHeight = 440 × 50, top edge 24pt below the menu bar) so that
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
        .background(Color.vfPillBackground, in: Capsule())
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
    static let recordButtonWidth: CGFloat = 118

    // MARK: Compact icon-toolbar metrics
    //
    // The whole toolbar is now ONE rounded container (replacing the old
    // two-container chip layout): a two-segment mode switch (Artifact | Dev), a
    // vertical hairline divider, the model/mic/(dev-settings) icon buttons, then
    // the Record pill. Icons are far narrower than the old labeled chips, which
    // also resolves the narrow-selection overflow we'd deferred.
    static let modeSegmentWidth: CGFloat = 34         // each mode-switch segment
    static let modeSwitchWidth: CGFloat = modeSegmentWidth * 2   // 68
    static let iconButtonWidth: CGFloat = 46          // icon + chevron control
    // The MODEL control is NOT a bare icon button — it shows the selected model
    // name between the sparkles icon and the chevron, so its width is dynamic.
    static let modelLabelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let modelButtonHPad: CGFloat = 9   // each side of the button
    private static let modelLabelGap: CGFloat = 5     // icon→label and label→chevron
    private static let modelIconWidth: CGFloat = 14   // sparkles glyph
    private static let modelChevronWidth: CGFloat = 8 // chevron glyph
    /// Fixed chrome around the model label (pads + icon + two gaps + chevron);
    /// the measured label width is added to this to size the model button.
    private static let modelButtonChromeWidth: CGFloat =
        modelButtonHPad * 2 + modelIconWidth + modelLabelGap * 2 + modelChevronWidth
    private static let containerHPad: CGFloat = 6     // container edge → first control
    private static let dividerGap: CGFloat = 8        // breathing room each side of the divider
    private static let dividerWidth: CGFloat = 1
    private static let controlGap: CGFloat = 4        // gap between adjacent icon buttons
    private static let recordGap: CGFloat = 8         // gap before the Record pill
    private static let toolbarGap: CGFloat = 14       // vertical gap, selection → toolbar
    private static let toolbarMargin: CGFloat = 8
    /// Comfort margin used to decide whether the toolbar fits centered inside an
    /// area selection (each side), and the breathing room the full-screen toolbar
    /// floats above the Dock.
    private static let areaCenterPad: CGFloat = 24
    static let fullScreenDockGap: CGFloat = 12

    /// Bottom Dock inset (points) of the screen the overlay is presenting on,
    /// stashed by `AreaSelectorWindowController` at present() so the full-screen
    /// toolbar floats clear of the Dock. The frame helpers are static (shared by
    /// the view render AND the controller hit-test), so this single source keeps
    /// the two in sync without threading the value through every helper. Safe as
    /// a static: exactly one overlay exists at a time (double-present is guarded);
    /// if multi-display lands (deferred), move this onto the per-overlay state.
    nonisolated(unsafe) static var fullScreenBottomInset: CGFloat = 0

    /// Current width of the model button (icon + selected-model name + chevron),
    /// stashed by `AreaSelectorWindowController` whenever the model list/selection
    /// changes. Same single-source-of-truth pattern as `fullScreenBottomInset`:
    /// the geometry helpers are static (shared by render + hit-test), so the
    /// controller updates this once per model change and both sides reflow in
    /// lockstep. Defaults to a bare icon button until the model name is known.
    nonisolated(unsafe) static var modelButtonWidth: CGFloat = iconButtonWidth

    /// Compute the model button's width for `name`: fixed chrome + the measured
    /// label width, capped so a very long name can't blow out the toolbar (it
    /// truncates instead). Floored at a bare icon button for an empty name.
    static func measuredModelButtonWidth(forName name: String) -> CGFloat {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return iconButtonWidth }
        let labelW = (trimmed as NSString)
            .size(withAttributes: [.font: modelLabelFont]).width
        let capped = min(labelW.rounded(.up), modelLabelMaxWidth)
        return modelButtonChromeWidth + capped
    }

    /// Hard cap on the rendered model label so an unexpectedly long name
    /// truncates rather than growing the toolbar past the overlay.
    private static let modelLabelMaxWidth: CGFloat = 150

    /// X-offsets (relative to the container's leading edge) of every control in
    /// the compact toolbar, computed once so the frame helpers and the renderer
    /// share one source of truth. Dev-settings exists only in Dev Mode; in
    /// Artifact mode `devSettingsX` is unused and Record slides left into its
    /// place.
    struct CompactLayout {
        let modeSwitchX: CGFloat
        let dividerX: CGFloat        // x of the 1pt divider line
        let modelX: CGFloat
        let micX: CGFloat
        let devSettingsX: CGFloat    // valid only when devMode == true
        let recordX: CGFloat
        let totalWidth: CGFloat
    }

    static func compactLayout(devMode: Bool) -> CompactLayout {
        let modeSwitchX = containerHPad
        let afterMode = modeSwitchX + modeSwitchWidth
        let dividerX = afterMode + dividerGap
        let modelX = dividerX + dividerWidth + dividerGap
        // The model control is wider than a bare icon button (it carries the
        // model name), so mic + everything after it shift by its dynamic width.
        let micX = modelX + modelButtonWidth + controlGap
        let devSettingsX = micX + iconButtonWidth + controlGap
        let afterControls = devMode
            ? devSettingsX + iconButtonWidth
            : micX + iconButtonWidth
        let recordX = afterControls + recordGap
        let totalWidth = recordX + recordButtonWidth + containerHPad
        return CompactLayout(
            modeSwitchX: modeSwitchX, dividerX: dividerX, modelX: modelX,
            micX: micX, devSettingsX: devSettingsX, recordX: recordX,
            totalWidth: totalWidth
        )
    }

    /// Total width of the one-piece compact toolbar container. Grows by exactly
    /// one icon button (the dev-settings icon) in Dev Mode.
    static func toolbarClusterWidth(devMode: Bool = false) -> CGFloat {
        compactLayout(devMode: devMode).totalWidth
    }

    /// View-local frame (top-left origin) of the whole floating toolbar.
    ///
    /// In `.area` mode (`fullScreen == false`): if the toolbar fits COMFORTABLY
    /// inside the selection (≥ `areaCenterPad` on every side) it is centered ON
    /// the region — covering content is fine since the overlay is dismissed
    /// before recording. Otherwise it falls back to hanging `toolbarGap` below
    /// the selection, flipping above if there isn't room, and clamping inside the
    /// overlay. In `.fullScreen` mode the selection IS the whole display, so the
    /// toolbar is pinned bottom-center, clear of the Dock (see
    /// `fullScreenToolbarFrame`).
    static func toolbarFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        if fullScreen {
            return fullScreenToolbarFrame(in: bounds, devMode: devMode, bottomInset: fullScreenBottomInset)
        }

        let size = CGSize(width: toolbarClusterWidth(devMode: devMode), height: toolbarHeight)

        // Center inside the region when it fits comfortably (a margin on every
        // side). The centered toolbar is wholly inside the selection, which is
        // inside the overlay, so no clamping is needed here.
        if rect.width >= size.width + 2 * areaCenterPad,
           rect.height >= size.height + 2 * areaCenterPad {
            let originX = rect.midX - size.width / 2
            let originY = rect.midY - size.height / 2
            return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
        }

        // Region too small to center it: hang below, flip above if needed, clamp.
        var originY = rect.maxY + toolbarGap
        if originY + size.height + toolbarMargin > bounds.height {
            originY = rect.minY - toolbarGap - size.height
        }
        if originY < toolbarMargin {
            originY = max(toolbarMargin, bounds.height - size.height - toolbarMargin)
        }

        var originX = rect.midX - size.width / 2
        originX = min(max(originX, toolbarMargin), bounds.width - size.width - toolbarMargin)

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// Full-screen toolbar: pinned bottom-center of the overlay, floating
    /// `fullScreenDockGap` above the Dock. `bottomInset` is the presenting
    /// screen's bottom Dock inset (0 when the Dock is hidden or on a side) — a
    /// `toolbarMargin` floor keeps it off the very bottom edge even then.
    /// Production sources `bottomInset` from `fullScreenBottomInset`; the param
    /// keeps this directly testable.
    static func fullScreenToolbarFrame(in bounds: CGSize, devMode: Bool = false, bottomInset: CGFloat = 0) -> CGRect {
        let size = CGSize(width: toolbarClusterWidth(devMode: devMode), height: toolbarHeight)
        let originX = (bounds.width - size.width) / 2
        let bottomGap = max(bottomInset + fullScreenDockGap, toolbarMargin)
        let originY = bounds.height - size.height - bottomGap
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// The mode switch as a whole (both segments): the leading control inside
    /// the container. Kept under the historical `devToggleFrame` name so the
    /// controller's existing hit-test still resolves; Part 5 splits it into the
    /// two per-segment frames below for precise mode mapping.
    static func devToggleFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let L = compactLayout(devMode: devMode)
        return CGRect(x: t.minX + L.modeSwitchX, y: t.minY, width: modeSwitchWidth, height: t.height)
    }

    /// Artifact segment (left half of the mode switch). Clicking sets Dev OFF.
    static func modeArtifactSegmentFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let s = devToggleFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        return CGRect(x: s.minX, y: s.minY, width: modeSegmentWidth, height: s.height)
    }

    /// Dev segment (right half of the mode switch). Clicking sets Dev ON.
    static func modeDevSegmentFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let s = devToggleFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        return CGRect(x: s.minX + modeSegmentWidth, y: s.minY, width: modeSegmentWidth, height: s.height)
    }

    /// Model-picker button: sparkles + the selected model name + chevron, opens
    /// the model dropdown. Width is dynamic (`modelButtonWidth`). Kept under the
    /// historical `modelChipFrame` name for the controller's hit-test.
    static func modelChipFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let L = compactLayout(devMode: devMode)
        return CGRect(x: t.minX + L.modelX, y: t.minY, width: modelButtonWidth, height: t.height)
    }

    /// Mic-picker icon button: mic + chevron, opens the device dropdown.
    static func micChipFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let L = compactLayout(devMode: devMode)
        return CGRect(x: t.minX + L.micX, y: t.minY, width: iconButtonWidth, height: t.height)
    }

    /// Dev-settings icon button (Dev Mode only): terminal + chevron + readiness
    /// dot, opens the consolidated agent/project menu.
    static func devSettingsIconFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: true)
        let L = compactLayout(devMode: true)
        return CGRect(x: t.minX + L.devSettingsX, y: t.minY, width: iconButtonWidth, height: t.height)
    }

    /// Record button: the trailing pill of the toolbar.
    static func recordButtonFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let t = toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let L = compactLayout(devMode: devMode)
        return CGRect(x: t.minX + L.recordX, y: t.minY, width: recordButtonWidth, height: t.height)
    }

    // MARK: - Dropdown geometry (CleanShot-style menus)
    //
    // The model/mic/dev-settings dropdowns share one shape: a dark rounded
    // panel anchored UNDER its icon button (caret pointing up at the icon),
    // flipped above if there isn't room, clamped inside the overlay. Each opens
    // with a small gray section header above its rows. Frames + per-row
    // hit-tests live in static helpers so the controller's mouse monitor and
    // this view agree on the exact rects (the SwiftUI tree is hit-test-disabled).

    static let micMenuRowHeight: CGFloat = 34
    static let modelMenuRowHeight: CGFloat = 34
    static let modelMenuWidth: CGFloat = 286
    static let micMenuWidth: CGFloat = 220
    /// Height reserved above the rows for a section header ("Model" / etc.).
    static let menuSectionHeaderHeight: CGFloat = 26
    /// Top/bottom inset inside the menu panel.
    static let menuVPad: CGFloat = 6
    /// Gap between the icon button and the menu panel (room for the caret).
    static let menuGap: CGFloat = 8

    /// Anchor a `width`×`height` menu under `icon`, flipping above when it would
    /// fall off the bottom, centering it on the icon and clamping horizontally.
    private static func anchoredMenuFrame(under icon: CGRect, width: CGFloat, height: CGFloat, in bounds: CGSize) -> CGRect {
        var originY = icon.maxY + menuGap
        if originY + height + toolbarMargin > bounds.height {
            originY = icon.minY - menuGap - height
        }
        if originY < toolbarMargin { originY = toolbarMargin }

        var originX = icon.midX - width / 2
        originX = min(max(originX, toolbarMargin), bounds.width - width - toolbarMargin)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// True when the menu sits below its icon (caret points up); false when it
    /// flipped above (caret points down).
    static func menuOpensDownward(menuFrame: CGRect, iconFrame: CGRect) -> Bool {
        menuFrame.minY >= iconFrame.maxY
    }

    static func micMenuFrame(forSelection rect: CGRect, in bounds: CGSize, itemCount: Int, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let icon = micChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let height = menuSectionHeaderHeight + CGFloat(itemCount) * micMenuRowHeight + menuVPad * 2
        return anchoredMenuFrame(under: icon, width: micMenuWidth, height: height, in: bounds)
    }

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
        let localY = point.y - frame.minY - menuVPad - menuSectionHeaderHeight
        guard localY >= 0 else { return nil }
        let idx = Int(localY / micMenuRowHeight)
        guard idx >= 0, idx < itemCount else { return nil }
        return idx
    }

    static func modelMenuFrame(forSelection rect: CGRect, in bounds: CGSize, itemCount: Int, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let icon = modelChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let height = menuSectionHeaderHeight + CGFloat(itemCount) * modelMenuRowHeight + menuVPad * 2
        return anchoredMenuFrame(under: icon, width: modelMenuWidth, height: height, in: bounds)
    }

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
        let localY = point.y - frame.minY - menuVPad - menuSectionHeaderHeight
        guard localY >= 0 else { return nil }
        let idx = Int(localY / modelMenuRowHeight)
        guard idx >= 0, idx < itemCount else { return nil }
        return idx
    }

    // MARK: - Dev-settings menu geometry
    //
    // The consolidated agent + model + project menu (Dev Mode only). Sections
    // stack vertically: Agent header → agent rows → divider → Model header →
    // model rows → divider → Project header → project row → divider →
    // git-reassurance line. The per-section heights are fixed so the controller
    // can map a click to an agent row, a model row, or the project ("Change…")
    // row by the same y-band math the renderer lays out with.

    static let devMenuRowHeight: CGFloat = 38
    static let devMenuWidth: CGFloat = 300
    /// A section divider + its surrounding breathing room.
    static let devMenuDividerBand: CGFloat = 13
    /// The wrapped two-line git-reassurance line at the menu's foot.
    static let devMenuGitLineHeight: CGFloat = 48

    static func devSettingsMenuFrame(forSelection rect: CGRect, in bounds: CGSize, agentCount: Int, modelCount: Int, fullScreen: Bool = false) -> CGRect {
        let icon = devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)
        let height = menuVPad
            + menuSectionHeaderHeight + CGFloat(agentCount) * devMenuRowHeight   // Agent section
            + devMenuDividerBand
            + menuSectionHeaderHeight + CGFloat(modelCount) * devMenuRowHeight   // Model section
            + devMenuDividerBand
            + menuSectionHeaderHeight + devMenuRowHeight                          // Project section
            + devMenuDividerBand
            + devMenuGitLineHeight
            + menuVPad
        return anchoredMenuFrame(under: icon, width: devMenuWidth, height: height, in: bounds)
    }

    /// Index of the Agent row under `point`, or nil if `point` is outside the
    /// Agent section.
    static func devSettingsAgentRowIndex(
        at point: CGPoint,
        forSelection rect: CGRect,
        in bounds: CGSize,
        agentCount: Int,
        modelCount: Int,
        fullScreen: Bool = false
    ) -> Int? {
        let frame = devSettingsMenuFrame(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen)
        guard frame.contains(point) else { return nil }
        let localY = point.y - frame.minY - menuVPad - menuSectionHeaderHeight
        guard localY >= 0 else { return nil }
        let idx = Int(localY / devMenuRowHeight)
        guard idx >= 0, idx < agentCount else { return nil }
        return idx
    }

    /// Index of the Model row under `point`, or nil if `point` is outside the
    /// Model section. Skips the Agent header + rows + divider + the Model header.
    static func devSettingsModelRowIndex(
        at point: CGPoint,
        forSelection rect: CGRect,
        in bounds: CGSize,
        agentCount: Int,
        modelCount: Int,
        fullScreen: Bool = false
    ) -> Int? {
        let frame = devSettingsMenuFrame(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen)
        guard frame.contains(point) else { return nil }
        let localY = point.y - frame.minY - menuVPad
            - menuSectionHeaderHeight - CGFloat(agentCount) * devMenuRowHeight   // skip Agent header + rows
            - devMenuDividerBand                                                 // skip divider
            - menuSectionHeaderHeight                                            // skip Model header
        guard localY >= 0 else { return nil }
        let idx = Int(localY / devMenuRowHeight)
        guard idx >= 0, idx < modelCount else { return nil }
        return idx
    }

    /// Frame of the Project ("Change…") row — clicking it opens the folder
    /// picker. nil-free: always returns the row's rect within the menu. Shifted
    /// down by the Model section (header + `modelCount` rows + divider).
    static func devSettingsProjectRowFrame(
        forSelection rect: CGRect,
        in bounds: CGSize,
        agentCount: Int,
        modelCount: Int,
        fullScreen: Bool = false
    ) -> CGRect {
        let frame = devSettingsMenuFrame(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, fullScreen: fullScreen)
        let y = frame.minY + menuVPad
            + menuSectionHeaderHeight + CGFloat(agentCount) * devMenuRowHeight   // Agent
            + devMenuDividerBand
            + menuSectionHeaderHeight + CGFloat(modelCount) * devMenuRowHeight   // Model
            + devMenuDividerBand
            + menuSectionHeaderHeight                                            // Project header
        return CGRect(x: frame.minX, y: y, width: frame.width, height: devMenuRowHeight)
    }

    // MARK: - CleanShot-style dropdown chrome
    //
    // The model/mic/dev-settings menus share one look: a dark rounded panel
    // (`menuFill`), a hairline, a soft shadow, a caret pointing at the anchor
    // icon, and a small gray section header above the rows. Each menu function
    // emits the panel + caret as siblings positioned at the static frames the
    // controller hit-tests against.

    /// Solid dark panel fill for the dropdowns (CleanShot reads as solid, not
    /// translucent — and a solid color also snapshots faithfully).
    static let menuFill = Color(red: 0.15, green: 0.15, blue: 0.17)
    private static let menuCornerRadius: CGFloat = 12

    /// Wrap menu content in the shared panel chrome, sized + positioned to
    /// `frame`. Content is laid out top-leading so the section header + rows
    /// stack from the top edge.
    private func menuPanel<Content: View>(frame: CGRect, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Self.menuCornerRadius, style: .continuous).fill(Self.menuFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.menuCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .position(x: frame.midX, y: frame.midY)
    }

    /// Small triangular caret bridging the gap between the anchor icon and the
    /// menu. `edgeY` is the menu edge it grows from; `pointingUp` true → menu is
    /// below the icon (caret points up toward it). `centerX` is the icon center,
    /// clamped into `panel` so the caret stays on the panel when the panel is
    /// horizontally clamped at a screen edge (icon center can fall outside it).
    private func menuCaret(centerX: CGFloat, edgeY: CGFloat, pointingUp: Bool, panel: CGRect) -> some View {
        let w: CGFloat = 14, h: CGFloat = 7
        let inset = w / 2 + Self.menuCornerRadius
        let x = min(max(centerX, panel.minX + inset), panel.maxX - inset)
        return Path { p in
            if pointingUp {
                p.move(to: CGPoint(x: w / 2, y: 0))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
            } else {
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w / 2, y: h))
            }
            p.closeSubpath()
        }
        .fill(Self.menuFill)
        .frame(width: w, height: h)
        // Overlap the edge by ~0.5pt so the caret reads as part of the panel.
        .position(x: x, y: pointingUp ? edgeY - h / 2 + 0.5 : edgeY + h / 2 - 0.5)
    }

    /// Gray section header ("Model" / "Microphone" / "Agent" / "Project").
    /// The bottom inset is applied BEFORE the fixed-height frame so the header's
    /// total height stays exactly `menuSectionHeaderHeight` (the row hit-test
    /// math depends on it).
    private func menuSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.vfTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .frame(height: Self.menuSectionHeaderHeight, alignment: .bottom)
    }

    /// Shared row highlight (hover or persistent selection), inset from the
    /// panel edges so it reads as a pill within the menu.
    private func menuRowHighlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(on ? Color.white.opacity(0.08) : .clear)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private func modelMenu(in bounds: CGSize) -> some View {
        if state.isModelMenuOpen, let rect = state.confirmableSelectionRect {
            let items = state.models
            let icon = Self.modelChipFrame(forSelection: rect, in: bounds, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            let frame = Self.modelMenuFrame(forSelection: rect, in: bounds, itemCount: items.count, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            let down = Self.menuOpensDownward(menuFrame: frame, iconFrame: icon)

            menuPanel(frame: frame) {
                VStack(spacing: 0) {
                    menuSectionHeader("Model")
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let selected = item.id == state.selectedModelID
                        let highlighted = (state.highlightedModelIndex == index && !item.gated) || selected
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.vfTextPrimary)   // neutral white check
                                .opacity(selected ? 1 : 0)
                                .frame(width: 14)
                            Text(item.name)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.vfTextPrimary : Color.vfTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if item.recommended {
                                Text("Recommended")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.vfTextSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.white.opacity(0.10)))
                                    .fixedSize()
                            }
                            Spacer(minLength: 6)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.vfTextSecondary)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: Self.modelMenuRowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(menuRowHighlight(highlighted))
                        .opacity(item.gated ? 0.45 : 1)
                    }
                }
                .padding(.vertical, Self.menuVPad)
            }

            menuCaret(centerX: icon.midX, edgeY: down ? frame.minY : frame.maxY, pointingUp: down, panel: frame)
        }
    }

    @ViewBuilder
    private func micMenu(in bounds: CGSize) -> some View {
        if state.isMicMenuOpen, let rect = state.confirmableSelectionRect {
            let items = state.micMenuItems
            let icon = Self.micChipFrame(forSelection: rect, in: bounds, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            let frame = Self.micMenuFrame(forSelection: rect, in: bounds, itemCount: items.count, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            let down = Self.menuOpensDownward(menuFrame: frame, iconFrame: icon)

            menuPanel(frame: frame) {
                VStack(spacing: 0) {
                    menuSectionHeader("Microphone")
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let selected = item.id == state.selectedMicrophoneID
                        let highlighted = state.highlightedMicIndex == index || selected
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.vfTextPrimary)
                                .opacity(selected ? 1 : 0)
                                .frame(width: 14)
                            Text(item.name)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.vfTextPrimary : Color.vfTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: Self.micMenuRowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(menuRowHighlight(highlighted))
                    }
                }
                .padding(.vertical, Self.menuVPad)
            }

            menuCaret(centerX: icon.midX, edgeY: down ? frame.minY : frame.maxY, pointingUp: down, panel: frame)
        }
    }

    // MARK: - Dev-settings menu (agent + project, Dev Mode only)

    @ViewBuilder
    private func devSettingsMenu(in bounds: CGSize) -> some View {
        if state.isDevSettingsMenuOpen, state.isDevMode, let rect = state.confirmableSelectionRect {
            let agents = state.devAgentMenuItems
            let models = state.devModelMenuItems
            let icon = Self.devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: state.mode == .fullScreen)
            let frame = Self.devSettingsMenuFrame(forSelection: rect, in: bounds, agentCount: agents.count, modelCount: models.count, fullScreen: state.mode == .fullScreen)
            let down = Self.menuOpensDownward(menuFrame: frame, iconFrame: icon)

            menuPanel(frame: frame) {
                VStack(spacing: 0) {
                    // Agent section.
                    menuSectionHeader("Agent")
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, item in
                        devAgentRow(item, highlighted: state.highlightedDevAgentIndex == index || item.id == state.selectedAgentID)
                    }

                    devMenuDivider

                    // Model section (Phase 2) — the selected agent's models,
                    // newest-first, checkmark on the current pick.
                    menuSectionHeader("Model")
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, item in
                        devModelRow(item, highlighted: state.highlightedDevModelIndex == index || item.id == state.selectedDevModelID)
                    }

                    devMenuDivider

                    // Project section.
                    menuSectionHeader("Project")
                    devProjectRow

                    devMenuDivider

                    // Git reassurance.
                    devGitReassuranceRow
                }
                .padding(.vertical, Self.menuVPad)
            }

            menuCaret(centerX: icon.midX, edgeY: down ? frame.minY : frame.maxY, pointingUp: down, panel: frame)
        }
    }

    /// One Model-section row: green checkmark on the current pick, a model icon,
    /// the display name. Mirrors `devAgentRow` (CleanShot style).
    private func devModelRow(_ item: AreaSelectorState.DevModelMenuItem, highlighted: Bool) -> some View {
        let active = item.id == state.selectedDevModelID
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfDevAccent)
                .opacity(active ? 1 : 0)
                .frame(width: 16)
            Image(systemName: "cpu")
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextSecondary)
            Text(item.name)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.vfTextPrimary : Color.vfTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(menuRowHighlight(highlighted))
    }

    private func devAgentRow(_ item: AreaSelectorState.DevAgentMenuItem, highlighted: Bool) -> some View {
        let active = item.id == state.selectedAgentID
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfDevAccent)   // green check on the active agent
                .opacity(active ? 1 : 0)
                .frame(width: 16)
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .foregroundStyle(item.installed ? Color.vfTextSecondary : Color.vfTextTertiary)
            Text(item.name)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(item.installed ? (active ? Color.vfTextPrimary : Color.vfTextSecondary) : Color.vfTextTertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if item.installed {
                Text("Detected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.vfDevAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.vfDevAccent.opacity(0.15)))
                    .fixedSize()
            } else {
                Text("Install")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(menuRowHighlight(highlighted))
    }

    private var devProjectRow: some View {
        // Amber attention when the folder is unset or not a git repo; neutral
        // once a valid repo is chosen.
        let attention = state.projectURL == nil || state.isProjectNotGitRepo
        let pathLabel = state.projectURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Select folder"
        return HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(attention ? Color.vfWarningAmber : Color.vfTextSecondary)
            Text(pathLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(attention ? Color.vfWarningAmber : Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("Change…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.vfAccentBlue)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var devGitReassuranceRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 13))
                .foregroundStyle(Color.vfDevAccent)
            Text("Snapshots with git before each change — undo anything.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuGitLineHeight, alignment: .center)
    }

    private var devMenuDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .frame(height: Self.devMenuDividerBand)
    }

    /// The compact icon toolbar: one rounded container holding the mode switch,
    /// a divider, the model/mic/(dev-settings) icon buttons, and the Record pill.
    /// Each control is positioned at the exact static frame the controller
    /// hit-tests against (the SwiftUI tree is hit-test-disabled).
    @ViewBuilder
    private func floatingToolbar(in bounds: CGSize) -> some View {
        if let rect = state.confirmableSelectionRect {
            let fullScreen = state.mode == .fullScreen
            let devMode = state.isDevMode
            let container = Self.toolbarFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let switchFrame = Self.devToggleFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let modelFrame = Self.modelChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let micFrame = Self.micChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let recFrame = Self.recordButtonFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let layout = Self.compactLayout(devMode: devMode)
            let dividerLineX = container.minX + layout.dividerX

            // One shared container wearing the recording-pill chrome.
            toolbarContainerChrome
                .frame(width: container.width, height: container.height)
                .position(x: container.midX, y: container.midY)

            // Mode switch (Artifact | Dev) — the leading control.
            modeSwitchControl
                .frame(width: switchFrame.width, height: switchFrame.height)
                .position(x: switchFrame.midX, y: switchFrame.midY)

            // Vertical hairline separating the switch from the controls — inset
            // to the same vertical band as the well + icon buttons (4pt top/
            // bottom) so nothing spans the full container height.
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: container.height - 8)
                .position(x: dividerLineX, y: container.midY)

            // Model button (sparkles + model name + chevron) + mic icon button.
            // Tooltips are drawn by `toolbarTooltip` (controller-driven hover)
            // rather than `.help`, which can't fire through the overlay's
            // hit-test-disabled SwiftUI tree.
            modelButton
                .frame(width: modelFrame.width, height: modelFrame.height)
                .position(x: modelFrame.midX, y: modelFrame.midY)

            iconButton(system: "mic", menuOpen: state.isMicMenuOpen, hovered: state.isMicChipHovered)
                .frame(width: micFrame.width, height: micFrame.height)
                .position(x: micFrame.midX, y: micFrame.midY)

            // Dev-settings icon (Dev Mode only).
            if devMode {
                let devFrame = Self.devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)
                devSettingsIconButton
                    .frame(width: devFrame.width, height: devFrame.height)
                    .position(x: devFrame.midX, y: devFrame.midY)
            }

            // Record pill — always red.
            recordPill
                .frame(width: recFrame.width, height: recFrame.height)
                .position(x: recFrame.midX, y: recFrame.midY)
        }
    }

    // MARK: - Hover tooltip
    //
    // The overlay's SwiftUI tree is hit-test-disabled, so `.help` tooltips never
    // fire — the controller's mouse monitor owns hover. It sets the per-control
    // hover flags; this reads them to draw a small bubble (with a downward caret)
    // above the hovered control. Suppressed while any dropdown is open so the
    // bubble never collides with a menu.

    @ViewBuilder
    private func toolbarTooltip(in bounds: CGSize) -> some View {
        if let rect = state.confirmableSelectionRect,
           !state.isModelMenuOpen, !state.isMicMenuOpen, !state.isDevSettingsMenuOpen,
           let info = tooltipInfo(forSelection: rect, in: bounds) {
            let bubbleH: CGFloat = 24
            let caretH: CGFloat = 5
            let gap: CGFloat = 7
            let total = bubbleH + caretH
            VStack(spacing: 0) {
                Text(info.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: bubbleH)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.menuFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 12, y: 0))
                    p.addLine(to: CGPoint(x: 6, y: caretH))
                    p.closeSubpath()
                }
                .fill(Self.menuFill)
                .frame(width: 12, height: caretH)
            }
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .position(x: info.anchor.midX, y: info.anchor.minY - gap - total / 2)
        }
    }

    /// Text + anchor frame for the currently-hovered control, or nil when none is
    /// hovered (or when the hovered control — Record — carries its own label).
    private func tooltipInfo(forSelection rect: CGRect, in bounds: CGSize) -> (text: String, anchor: CGRect)? {
        let fs = state.mode == .fullScreen
        let dev = state.isDevMode
        if state.isModeArtifactHovered {
            return ("Artifact", Self.modeArtifactSegmentFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev))
        }
        if state.isModeDevHovered {
            return ("Dev Mode", Self.modeDevSegmentFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev))
        }
        if state.isModelChipHovered {
            // The model name is shown in the button itself, so the tooltip is
            // just the control's purpose.
            return ("Model", Self.modelChipFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev))
        }
        if state.isMicChipHovered {
            return ("Microphone: \(state.selectedMicrophoneName)", Self.micChipFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev))
        }
        if dev, state.isDevSettingsHovered {
            return ("Agent & project", Self.devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: fs))
        }
        return nil
    }

    // MARK: - Compact toolbar chrome
    //
    // One rounded container holds every control. Its background matches the
    // instruction pill (solid `vfPillBackground` + `vfHairline` 0.5 strokeBorder)
    // so the overlay chrome reads as one cohesive family. Green (`vfDevAccent`)
    // appears ONLY on the active Dev segment, the dev-settings readiness dot, and
    // inside the dev-settings menu; everything else is neutral and Record red.

    /// Shared opaque chrome for the toolbar container — same treatment as the
    /// instruction pill, with a soft drop shadow for legibility over arbitrary
    /// captured content.
    private var toolbarContainerChrome: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.vfPillBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    // MARK: Mode switch

    /// The two-segment mode switch: Artifact (wand) | Dev (`</>`), inside a
    /// recessed well. The active segment is highlighted — Artifact → neutral
    /// white fill, Dev → green `vfDevAccent` tint + green icon — and the inactive
    /// segment's icon is dimmed. Clicking maps to the mode (Part 5 hit-tests the
    /// two halves separately).
    private var modeSwitchControl: some View {
        HStack(spacing: 2) {
            modeSegment(
                system: "wand.and.stars",
                active: !state.isDevMode, isDev: false,
                hovered: state.isModeArtifactHovered
            )
            modeSegment(
                system: "chevron.left.forwardslash.chevron.right",
                active: state.isDevMode, isDev: true,
                hovered: state.isModeDevHovered
            )
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        // Match the icon buttons' vertical inset so the recessed well doesn't
        // touch the container's top/bottom — equal breathing room on every
        // component. The hit-test frame stays full-height (rendering only).
        .padding(.vertical, 4)
    }

    private func modeSegment(system: String, active: Bool, isDev: Bool, hovered: Bool) -> some View {
        let fill: Color = active
            ? (isDev ? Color.vfDevAccent.opacity(0.22) : Color.white.opacity(0.12))
            : (hovered ? Color.white.opacity(0.06) : .clear)
        let iconColor: Color = active
            ? (isDev ? Color.vfDevAccent : Color.vfTextPrimary)
            : Color.vfTextTertiary
        // With the well inset, each segment reads as a rounded square (~30×26).
        return Image(systemName: system)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            )
    }

    // MARK: Icon buttons

    /// A neutral icon + chevron button (model / mic). The chevron flips when its
    /// dropdown is open; a subtle rounded fill brightens on hover/open.
    private func iconButton(system: String, menuOpen: Bool, hovered: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.vfTextTertiary)
                .rotationEffect(.degrees(menuOpen ? 180 : 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(iconButtonFill(active: menuOpen, hovered: hovered))
    }

    /// The model picker: sparkles + the selected model NAME + chevron (the name
    /// reads in the toolbar, so the hover tooltip just says "Model"). The button
    /// width tracks the name via `Self.modelButtonWidth` (kept current by the
    /// controller), so the SwiftUI label here never needs to negotiate width —
    /// it sits in the frame the geometry already reserved.
    private var modelButton: some View {
        HStack(spacing: Self.modelLabelGap) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
            Text(state.selectedModelName)
                .font(Font(Self.modelLabelFont))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.vfTextTertiary)
                .rotationEffect(.degrees(state.isModelMenuOpen ? 180 : 0))
        }
        .padding(.horizontal, Self.modelButtonHPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(iconButtonFill(active: state.isModelMenuOpen, hovered: state.isModelChipHovered))
    }

    /// Dev-settings icon (Dev Mode only): terminal + chevron with a readiness
    /// dot at the corner — green when an agent + folder are set, amber otherwise.
    private var devSettingsIconButton: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.vfTextTertiary)
                    .rotationEffect(.degrees(state.isDevSettingsMenuOpen ? 180 : 0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(iconButtonFill(active: state.isDevSettingsMenuOpen, hovered: state.isDevSettingsHovered))

            Circle()
                .fill(state.isDevReady ? Color.vfDevAccent : Color.vfWarningAmber)
                .frame(width: 7, height: 7)
                // Ring in the container color punches a gap so the dot reads as
                // separate from the now-opaque bar.
                .overlay(Circle().stroke(Color.vfPillBackground, lineWidth: 1.5))
                .padding(.top, 5)
                .padding(.trailing, 3)
        }
    }

    private func iconButtonFill(active: Bool, hovered: Bool) -> some View {
        // Slightly stronger than on the old solid fill — the frosted material is
        // lighter, so a white tint needs a touch more to register as a button.
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(active ? 0.14 : (hovered ? 0.10 : 0.06)))
            .padding(.vertical, 4)
            .padding(.horizontal, 1)
    }

    // MARK: Record pill

    /// The labeled Record button — a fully-rounded red capsule, inset slightly
    /// within the container. Always `vfRecordingRed`, never green; a subtle white
    /// tint on hover.
    private var recordPill: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.vfRecordingRed)
            Capsule(style: .continuous).fill(Color.white.opacity(state.isRecordButtonHovered ? 0.12 : 0))
            HStack(spacing: VFSpacing.sm) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                Text("Record")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 3)
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
            .background(Color.vfPillBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.vfWarningAmber.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
            .position(x: toolbar.midX, y: toolbar.minY - 18)
        }
    }
}

// MARK: - Dev Mode chrome modifiers
//
// `devBreathingPulse` keeps the Dev-Mode selection-border animation out of the
// normal path entirely: when `active` is false it returns the view UNCHANGED
// (`self`), so the non-Dev selection chrome is byte-identical to before this
// work. It's a standalone modifier because the breathing pulse needs `@State`
// to drive its animation, which the stateless border helper on
// `AreaSelectorView` can't hold.

/// Slow ease-in-out "breathing" for the Dev-Mode selection border — a ~2.4s
/// autoreversing opacity + green-glow loop. Tasteful, not a strobe.
private struct DevBreathingPulse: ViewModifier {
    @State private var breathing = false

    func body(content: Content) -> some View {
        content
            .opacity(breathing ? 1.0 : 0.6)
            .shadow(color: Color.vfDevAccent.opacity(breathing ? 0.65 : 0.15),
                    radius: breathing ? 7 : 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

private extension View {
    /// Applies the Dev-Mode breathing pulse only when `active`; otherwise the
    /// view is returned unchanged so normal mode stays byte-identical.
    @ViewBuilder
    func devBreathingPulse(_ active: Bool) -> some View {
        if active { modifier(DevBreathingPulse()) } else { self }
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

/// Dev Mode on: the Dev segment of the mode switch is active (green) and the
/// dev-settings icon appears with an amber readiness dot (folder unset).
#Preview("Dev Mode — folder unset") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.setDevState(isDevMode: true, agentID: "claude-code", agentName: "Claude Code", projectURL: nil)
            seedDevAgents(s)
            return s
        }())
    }
    .frame(width: 1200, height: 700)
}

/// Dev Mode with the dev-settings menu open (the Part 3 deliverable): Agent
/// section with the green-checked Claude Code + Detected badge, Project row with
/// the folder path + Change…, and the green git-shield reassurance line.
#Preview("Dev Mode — settings menu open") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.setDevState(
                isDevMode: true, agentID: "claude-code", agentName: "Claude Code",
                projectURL: URL(fileURLWithPath: "/Users/you/dev/my-site", isDirectory: true)
            )
            seedDevAgents(s)
            s.setProjectGitRepo(true)
            s.toggleDevSettingsMenu()
            return s
        }())
    }
    .frame(width: 1200, height: 760)
}

/// Dev Mode on with a folder chosen + a validation message showing — the
/// record-time block state. Readiness dot green (agent + folder set).
#Preview("Dev Mode — folder set + blocked") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.setDevState(
                isDevMode: true, agentID: "claude-code", agentName: "Claude Code",
                projectURL: URL(fileURLWithPath: "/Users/you/Developer/acme-web", isDirectory: true)
            )
            seedDevAgents(s)
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
    // Production rows carry no per-model credit detail (detail is nil unless
    // BYOK key-gated), so the preview mirrors that for a faithful menu snapshot.
    s.setModels(
        [
            .init(id: "gpt-5.4-mini", name: "GPT-5.4 mini", detail: nil, recommended: false, gated: false),
            .init(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash", detail: nil, recommended: true, gated: false),
            .init(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", detail: nil, recommended: false, gated: false),
            .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", detail: nil, recommended: false, gated: false),
            .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", detail: nil, recommended: false, gated: false),
            .init(id: "gpt-5.5", name: "GPT-5.5", detail: nil, recommended: false, gated: false),
        ],
        selectedID: "gemini-3.5-flash"
    )
    return s
}

/// The detected-agent rows for the dev-settings menu previews. Claude Code is
/// the installed (Detected) agent; Codex / Cursor are shown not-installed to
/// match the design mockup (live, these come from `DevAgentDetection`). The
/// Model section is seeded with Claude Code's (anthropic) models — live these
/// come from `AgentModelManifestStore`.
@MainActor
private func seedDevAgents(_ s: AreaSelectorState) {
    s.setDevAgentMenuItems([
        .init(id: "claude-code", name: "Claude Code", installed: true),
        .init(id: "codex", name: "Codex", installed: false),
        .init(id: "cursor", name: "Cursor", installed: false),
    ])
    s.setDevModelMenuItems([
        .init(id: "claude-opus-4-8", name: "Claude Opus 4.8"),
        .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6"),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
    ], selectedID: "claude-opus-4-8")
}
