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
//        Dim overlay + the large screen-centered resting instruction
//        pill. The user hasn't pressed mouseDown yet, or just opened
//        the overlay.
//    • Active drag (`state.isDragging == true`)
//        Dim overlay with cutout + selection border + 4 corner
//        handles + live dimensions readout. The resting pill is gone —
//        it hides the instant a drag begins (`selectionRect` non-nil).
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
                // Hidden while the walkthrough runs — the tour's scrim +
                // callout own the overlay's attention; the pill would just be
                // dimmed clutter behind them. In area mode the resting pill
                // also hides the instant a drag begins (no transition — an
                // instant cut, CleanShot-style); full-screen keeps its small
                // top prompt throughout.
                if state.showsRestingInstructionPill {
                    restingInstructionPill(in: bounds)
                } else if state.mode == .fullScreen, state.toolbarWalkthroughStep == nil {
                    instructionPill(in: bounds)
                }
                floatingToolbar(in: bounds)
                modelMenu(in: bounds)
                upgradeMenu(in: bounds)
                micMenu(in: bounds)
                devSettingsMenu(in: bounds)
                devValidationBanner(in: bounds)
                devLocalhostNoticeBanner(in: bounds)
                tooSmallMessage(in: bounds)
                toolbarTooltip(in: bounds)
                // First-run toolbar walkthrough: the dim + spotlight sit
                // ABOVE the toolbar (cutting the active control through);
                // the callout is the topmost layer.
                walkthroughScrim(in: bounds)
                walkthroughCallout(in: bounds)
            }
            .frame(width: bounds.width, height: bounds.height)
            // Staging-only: amber edge border + "STAGING" badge so the capture
            // overlay can never be confused with production. Periphery-only and
            // click-through, so it never obstructs the selection. Absent from
            // the production binary (the modifier only exists under #if STAGING).
            #if STAGING
            .stagingOverlayMarker(topInset: topInset)
            #endif
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
        // Error wins over BOTH mode accents: a settled undersized selection
        // strokes red whether in Ask or Dev mode (the flag stays quiet
        // mid-drag — see `isSelectionTooSmall`).
        let strokeColor: Color = state.isSelectionTooSmall
            ? .vfRecordingRed
            : (state.isDevMode ? .vfDevAccent : .vfBrandAccent)
        return Rectangle()
            .stroke(strokeColor, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .devBreathingPulse(state.isDevMode)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Handles
    //
    // The handles are the resize affordance: the controller's mouse monitor
    // hit-tests them via `handleHitTest` below and routes the drag into
    // `AreaSelectorState.updateResize`. Visibility follows the gesture:
    // hidden entirely while DRAWING a new rect (`interaction == .creating` —
    // the border + readout are the live drag feedback), corners-only while a
    // resize/move is in flight (the `isDragging` midpoint collapse; the
    // grabbed bracket must not vanish mid-resize), all 8 once settled AT A
    // CONFIRMABLE SIZE. An undersized settle shows no handles: the
    // controller's edit hit-test gates on `confirmableSelectionRect`, so
    // they wouldn't be grabbable — the red border + message own that state
    // and the user redraws instead.

    // Handle metrics — ONE geometry for both modes (they differ only in
    // tint). Purely visual: the grab area is `handleHitSlop`, which must
    // stay ≥ half the largest dimension here (edgeHandleLength 26 → 13 ≤ 22)
    // so the hit target always covers the drawn handle.
    static let cornerBracketArm: CGFloat = 20
    static let cornerBracketLineWidth: CGFloat = 4
    static let edgeHandleLength: CGFloat = 26
    static let edgeHandleThickness: CGFloat = 7

    @ViewBuilder
    private func selectionHandles(at rect: CGRect) -> some View {
        // No handles while drawing a new rect, and none on a settled-but-
        // undersized selection (not editable — see the MARK note). Resize/
        // move edits keep them (the user is holding one, and the resize pin
        // keeps the rect at or above the minimum).
        if state.interaction != .creating, !state.isSelectionTooSmall {
            if state.isDevMode {
                // Dev keeps its bare accent treatment (the breathing border
                // already supplies the glow).
                handleChrome(at: rect, tint: .vfDevAccent, contrastChrome: false)
            } else {
                // White needs help over light content: hairline vfOnBrand outline
                // on the pills + a soft shadow on everything.
                handleChrome(at: rect, tint: .white, contrastChrome: true)
            }
        }
    }

    /// CleanShot-style handle chrome, shared by both modes: L-shaped brackets
    /// at the corners (arms pointing inward, one stroked `Path` of eight arms
    /// — cheaper than eight positioned shapes, and the absolute coordinates
    /// align to the full overlay bounds exactly like `dimCutout`) plus, once
    /// the selection settles, a capsule bar on each edge midpoint with its
    /// long axis ALONG the edge (horizontal on top/bottom, vertical on
    /// left/right). `contrastChrome` adds the hairline outline + soft shadow
    /// that keep the white variant legible over light content.
    @ViewBuilder
    private func handleChrome(at rect: CGRect, tint: Color, contrastChrome: Bool) -> some View {
        let midpoints = state.isDragging ? [] : edgeMidpointHandlePositions(at: rect)

        cornerBracketPath(at: rect)
            .stroke(tint, style: StrokeStyle(lineWidth: Self.cornerBracketLineWidth, lineCap: .round, lineJoin: .round))
            .shadow(color: .black.opacity(contrastChrome ? 0.4 : 0), radius: 1.5, y: 0.5)

        ForEach(midpoints.indices, id: \.self) { i in
            let point = midpoints[i]
            // Long axis parallel to the edge: top/bottom midpoints share the
            // rect's horizontal edge lines (exact same y — both values come
            // from `edgeMidpointHandlePositions`), left/right the vertical.
            let horizontal = point.y == rect.minY || point.y == rect.maxY
            let radius = Self.edgeHandleThickness / 2
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(contrastChrome ? Color.vfOnBrand : .clear, lineWidth: 1)
                )
                .shadow(color: .black.opacity(contrastChrome ? 0.4 : 0), radius: 1.5, y: 0.5)
                .frame(
                    width: horizontal ? Self.edgeHandleLength : Self.edgeHandleThickness,
                    height: horizontal ? Self.edgeHandleThickness : Self.edgeHandleLength
                )
                .position(point)
        }
    }

    /// The four corner L-brackets as one path — (corner, end of horizontal
    /// arm, end of vertical arm), arms always pointing inward from the corner.
    private func cornerBracketPath(at rect: CGRect) -> Path {
        let arm = Self.cornerBracketArm
        return Path { p in
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

    // MARK: - Handle hit-testing (resize / move)
    //
    // Static like the toolbar frame helpers, so the controller's mouse
    // monitor hit-tests the same geometry the view renders. The handles
    // draw at 8×8pt — far too small to grab — so each is grabbable within
    // `handleHitSlop` of its center, and the edges are grabbable anywhere
    // ALONG the edge (the midpoint dot is a hint, not the only target),
    // matching CleanShot. All coordinates are view-local, top-left.

    /// Hit slop around each handle's center — the grabbable band extends well
    /// past the drawn handle. ~22pt matches the comfort of CleanShot's
    /// targets, and stays clear of overlap at the minimum selection size
    /// (opposing edge bands sit 2×22 = 44pt apart < the 150pt minimum;
    /// corner zones span 44 < 150).
    static let handleHitSlop: CGFloat = 22

    /// Which handle (if any) is under `point`, given the settled selection
    /// rect. Corners win ties over edges (checked first), so a press in the
    /// overlap zone resizes both axes.
    static func handleHitTest(at point: CGPoint, selection rect: CGRect) -> AreaSelectorState.Handle? {
        let slop = handleHitSlop
        let corners: [(AreaSelectorState.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY))
        ]
        for (handle, center) in corners {
            if abs(point.x - center.x) <= slop, abs(point.y - center.y) <= slop {
                return handle
            }
        }
        // Edge bands: within slop of the edge line, along the edge's span.
        // Corner zones already won above, so the full span is safe here.
        let alongX = point.x >= rect.minX && point.x <= rect.maxX
        let alongY = point.y >= rect.minY && point.y <= rect.maxY
        if alongX, abs(point.y - rect.minY) <= slop { return .top }
        if alongX, abs(point.y - rect.maxY) <= slop { return .bottom }
        if alongY, abs(point.x - rect.minX) <= slop { return .left }
        if alongY, abs(point.x - rect.maxX) <= slop { return .right }
        return nil
    }

    /// True when `point` is inside the selection but clear of every handle
    /// band — the drag-to-move region. The inset by `handleHitSlop` is what
    /// keeps the edge bands (handle territory) out of the move region, so
    /// handles win even if callers check this first.
    static func isInteriorHit(_ point: CGPoint, selection rect: CGRect) -> Bool {
        rect.insetBy(dx: handleHitSlop, dy: handleHitSlop).contains(point)
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
        // Undersized selection: the readout goes red too, so the numbers
        // themselves read as the problem (they're what's below the minimum).
        let fill: Color = state.isSelectionTooSmall
            ? .vfRecordingRed
            : (state.isDevMode ? .vfDevAccent : Color.black.opacity(0.6))
        let textColor: Color = state.isSelectionTooSmall
            ? .white
            : (state.isDevMode ? Color.vfOnBrand : Color.white)
        return Text("\(Int(rect.width)) \u{00D7} \(Int(rect.height))")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill)
            )
            .fixedSize()
            .position(x: rect.maxX - 36, y: rect.maxY - 16)
    }

    // MARK: - Instruction pill (two placements, one content)
    //
    // Area mode's resting state gets the LARGE pill dead-center of the
    // overlay (CleanShot's start-screen treatment); full-screen mode keeps
    // the original small pill top-center. Both render the same dot + text +
    // keycap row via `instructionPillContent`, parameterized only by sizing.
    //
    // The small variant is sized and positioned to match the recording pill
    // (PillView.capsuleWidth/capsuleHeight = 440 × 50, top edge 24pt below
    // the menu bar) so that the area selector and the recording session feel
    // like a continuous surface across the two phases. `topInset` is the
    // menu-bar height in points, supplied by AreaSelectorWindowController —
    // without it we'd be measuring 24pt down from the physical screen top,
    // behind the menu bar. The centered variant doesn't need `topInset`.

    private static let pillHeight: CGFloat = 50
    private static let pillTopGap: CGFloat = 24
    // Resting-pill metrics: CleanShot's proportions relative to the small
    // pill (roughly a 4/3 zoom, with roomier padding).
    private static let restingPillHeight: CGFloat = 68
    private static let restingPillTextSize: CGFloat = 16
    private static let restingPillKeyCapScale: CGFloat = 16 / 12

    /// Full-screen mode's prompt: small, top-center (the original pill).
    private func instructionPill(in bounds: CGSize) -> some View {
        HStack(spacing: VFSpacing.sm) {
            instructionPillContent(textSize: 12, dotSize: 8, dotLineWidth: 1.2, keyCapScale: 1)
        }
        .frame(height: Self.pillHeight)
        .padding(.horizontal, VFSpacing.lg)
        .background(Color.vfPillBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.vfOverlayBorder, lineWidth: 1))
        .fixedSize()
        .position(
            x: bounds.width / 2,
            y: topInset + Self.pillTopGap + Self.pillHeight / 2
        )
    }

    /// Area mode's initial resting prompt: the same pill enlarged and placed
    /// dead-center of the overlay. Rendered only while
    /// `state.showsRestingInstructionPill` — it vanishes (no transition) the
    /// moment a drag begins.
    private func restingInstructionPill(in bounds: CGSize) -> some View {
        HStack(spacing: VFSpacing.md) {
            instructionPillContent(
                textSize: Self.restingPillTextSize,
                dotSize: 11,
                dotLineWidth: 1.5,
                keyCapScale: Self.restingPillKeyCapScale
            )
        }
        .frame(height: Self.restingPillHeight)
        .padding(.horizontal, VFSpacing.xxl)
        .background(Color.vfPillBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.vfOverlayBorder, lineWidth: 1))
        .fixedSize()
        .position(x: bounds.width / 2, y: bounds.height / 2)
    }

    /// The pill's row content — leading dot, instruction text, and the keycap
    /// hints — shared by both variants so the copy can never drift between
    /// them; only the metrics differ.
    @ViewBuilder
    private func instructionPillContent(
        textSize: CGFloat, dotSize: CGFloat, dotLineWidth: CGFloat, keyCapScale: CGFloat
    ) -> some View {
        Circle()
            .stroke(Color.vfTextSecondary, lineWidth: dotLineWidth)
            .frame(width: dotSize, height: dotSize)
        Text(instructionText)
            .font(.system(size: textSize))
            .foregroundStyle(Color.vfTextPrimary)
            .fixedSize()
        // Space is a one-way hint shown only in area mode: press it to
        // jump to full screen. Once in full-screen mode there's no
        // toggle back, so the hint is hidden (only esc/cancel remains).
        if state.mode == .area {
            Text("\u{00B7}")
                .font(.system(size: textSize))
                .foregroundStyle(Color.vfTextTertiary)
            KeyCapView(label: "space", scale: keyCapScale)
            Text("full screen")
                .font(.system(size: textSize))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
        }
        Text("\u{00B7}")
            .font(.system(size: textSize))
            .foregroundStyle(Color.vfTextTertiary)
        KeyCapView(label: "esc", scale: keyCapScale)
        Text("cancel")
            .font(.system(size: textSize))
            .foregroundStyle(Color.vfTextSecondary)
            .fixedSize()
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

    /// Single knob for the whole capture toolbar's size. The toolbar is a
    /// custom-laid-out cluster (not a SwiftUI HStack): every metric below is
    /// `base * toolbarScale`, and every inline font/radius/padding in the
    /// control bodies is routed through `scaled(_:)`. Both the SwiftUI render
    /// AND the AppKit hit-test read these same statics, so bumping this factor
    /// uniformly zooms render and hit-test together. Tune here only.
    static let toolbarScale: CGFloat = 1.15

    /// Scale an inline literal (corner radius, padding, box dimension) by the
    /// toolbar zoom factor so the container chrome and insets grow together.
    static func scaled(_ base: CGFloat) -> CGFloat { base * toolbarScale }

    /// Glyphs and text render a touch smaller than a pure box zoom would make
    /// them, so the SF Symbols and labels sit lighter inside the (box-scaled)
    /// controls. A <1 trim on top of `toolbarScale`; tune this independently of
    /// the box scale. Applies ONLY to icon/text point sizes, never to boxes.
    static let toolbarGlyphTrim: CGFloat = 0.92
    static func scaledGlyph(_ base: CGFloat) -> CGFloat { base * toolbarScale * toolbarGlyphTrim }

    static let toolbarHeight: CGFloat = 40 * toolbarScale
    static let recordButtonWidth: CGFloat = 118 * toolbarScale

    // MARK: Compact icon-toolbar metrics
    //
    // The whole toolbar is now ONE rounded container (replacing the old
    // two-container chip layout): a two-segment mode switch (Ask | Dev), a
    // vertical hairline divider, the model/mic/(dev-settings) icon buttons, then
    // the Record pill. Icons are far narrower than the old labeled chips, which
    // also resolves the narrow-selection overflow we'd deferred.
    static let modeSegmentWidth: CGFloat = 34 * toolbarScale   // each mode-switch segment
    static let modeSwitchWidth: CGFloat = modeSegmentWidth * 2   // 68 (pre-scale)
    static let iconButtonWidth: CGFloat = 46 * toolbarScale     // icon + chevron control
    // The MODEL control is NOT a bare icon button — it shows the selected model
    // name between the sparkles icon and the chevron, so its width is dynamic.
    static let modelLabelFont = NSFont.systemFont(ofSize: scaledGlyph(12), weight: .medium)
    private static let modelButtonHPad: CGFloat = 9 * toolbarScale   // each side of the button
    private static let modelLabelGap: CGFloat = 5 * toolbarScale     // icon→label and label→chevron
    private static let modelIconWidth: CGFloat = 14 * toolbarScale   // sparkles glyph
    private static let modelChevronWidth: CGFloat = 8 * toolbarScale // chevron glyph
    /// Fixed chrome around the model label (pads + icon + two gaps + chevron);
    /// the measured label width is added to this to size the model button.
    private static let modelButtonChromeWidth: CGFloat =
        modelButtonHPad * 2 + modelIconWidth + modelLabelGap * 2 + modelChevronWidth
    // container edge → first/last control. Matched to the components' vertical
    // inset (`scaled(4)`) so the gap to the toolbar edge is uniform on all four
    // sides; with the capsule container this nests the controls concentrically.
    private static let containerHPad: CGFloat = 4 * toolbarScale
    private static let dividerGap: CGFloat = 8 * toolbarScale        // breathing room each side of the divider
    private static let dividerWidth: CGFloat = 1 * toolbarScale
    private static let controlGap: CGFloat = 4 * toolbarScale        // gap between adjacent icon buttons
    private static let recordGap: CGFloat = 8 * toolbarScale         // gap before the Record pill
    private static let toolbarGap: CGFloat = 14 * toolbarScale       // vertical gap, selection → toolbar
    private static let toolbarMargin: CGFloat = 8 * toolbarScale
    /// Comfort margin used to decide whether the toolbar fits centered inside an
    /// area selection (each side), and the breathing room the full-screen toolbar
    /// floats above the Dock.
    private static let areaCenterPad: CGFloat = 24 * toolbarScale
    static let fullScreenDockGap: CGFloat = 12 * toolbarScale

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
    private static let modelLabelMaxWidth: CGFloat = 150 * toolbarScale

    /// X-offsets (relative to the container's leading edge) of every control in
    /// the compact toolbar, computed once so the frame helpers and the renderer
    /// share one source of truth. Dev-settings exists only in Dev Mode; in
    /// Ask mode `devSettingsX` is unused and Record slides left into its
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

    /// Ask segment (left half of the mode switch). Clicking sets Dev OFF.
    static func modeAskSegmentFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
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

    // MARK: - Walkthrough geometry (first-run toolbar tour)
    //
    // The walkthrough spotlights one toolbar control at a time and floats a
    // callout (step indicator + title + copy + Back/Next) next to it. All
    // frames live in static helpers for the same reason the toolbar controls'
    // do: the SwiftUI tree is hit-test-disabled, so the controller (Phase 3)
    // must hit-test the EXACT rects the view renders — one source of truth
    // here keeps render and hit-test in lockstep. Anchors REUSE the controls'
    // own frame helpers verbatim; no new control geometry is invented.

    /// Padding between a spotlighted control's frame and the scrim cutout /
    /// accent ring around it.
    static let walkthroughSpotlightPad: CGFloat = 6
    static let walkthroughSpotlightCorner: CGFloat = 10
    /// Vertical gap between the spotlight ring and the callout panel — room
    /// for the caret plus breathing space clear of the ring's stroke.
    static let walkthroughCalloutGap: CGFloat = 14
    static let walkthroughCalloutWidth: CGFloat = 300
    /// Inner inset of the callout's content (all four sides).
    static let walkthroughCalloutPad: CGFloat = 14
    /// Fixed height of the "1 of 5" step-indicator / badge row.
    static let walkthroughIndicatorHeight: CGFloat = 18
    /// Vertical gaps: indicator → title, title → body, body → footer.
    static let walkthroughTitleGap: CGFloat = 4
    static let walkthroughBodyGap: CGFloat = 6
    static let walkthroughFooterGap: CGFloat = 14
    static let walkthroughButtonHeight: CGFloat = 28
    /// Horizontal padding inside the Next capsule / hit slop around Back.
    static let walkthroughNextHPad: CGFloat = 14
    static let walkthroughBackHPad: CGFloat = 8
    /// Copy is MEASURED with these NSFonts and rendered with the matching
    /// `.system` fonts (same pattern as `toolbarTooltip`'s multi-line branch),
    /// so the measured panel height is the rendered height.
    static let walkthroughTitleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let walkthroughBodyFont = NSFont.systemFont(ofSize: 13)
    static let walkthroughNextFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let walkthroughBackFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// The toolbar-control frame a walkthrough step points at. `.agent` maps
    /// to `devSettingsIconFrame`, which takes no `devMode` — the icon only
    /// exists in the Dev layout, which Phase 1's state machine forces on
    /// (display-only) for the agent/record steps, so callers passing
    /// `devMode: state.isDevMode` resolve every anchor in the layout actually
    /// on screen.
    static func walkthroughAnchorFrame(
        for step: ToolbarWalkthroughStep,
        forSelection rect: CGRect, in bounds: CGSize,
        fullScreen: Bool, devMode: Bool
    ) -> CGRect {
        switch step {
        case .mode:
            return devToggleFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        case .model:
            return modelChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        case .mic:
            return micChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        case .agent:
            return devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)
        case .record:
            return recordButtonFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        }
    }

    /// The scrim's spotlight rect: the step's anchor padded out on every side.
    static func walkthroughSpotlightRect(
        for step: ToolbarWalkthroughStep,
        forSelection rect: CGRect, in bounds: CGSize,
        fullScreen: Bool, devMode: Bool
    ) -> CGRect {
        walkthroughAnchorFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            .insetBy(dx: -walkthroughSpotlightPad, dy: -walkthroughSpotlightPad)
    }

    /// Measured panel height for a step's copy at the fixed callout width.
    static func walkthroughCalloutHeight(for step: ToolbarWalkthroughStep) -> CGFloat {
        let textW = walkthroughCalloutWidth - walkthroughCalloutPad * 2
        func measured(_ text: String, font: NSFont) -> CGFloat {
            ceil((text as NSString).boundingRect(
                with: CGSize(width: textW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height)
        }
        return walkthroughCalloutPad
            + walkthroughIndicatorHeight + walkthroughTitleGap
            + measured(step.title, font: walkthroughTitleFont) + walkthroughBodyGap
            + measured(step.body, font: walkthroughBodyFont) + walkthroughFooterGap
            + walkthroughButtonHeight + walkthroughCalloutPad
    }

    /// Callout panel frame: centered on the spotlight, preferring ABOVE it
    /// (caret pointing down at the control), flipping below when there isn't
    /// room, clamped inside the overlay by `toolbarMargin` — the same
    /// hang-and-flip `toolbarFrame`/`anchoredMenuFrame` use.
    static func walkthroughCalloutFrame(
        for step: ToolbarWalkthroughStep,
        forSelection rect: CGRect, in bounds: CGSize,
        fullScreen: Bool, devMode: Bool
    ) -> CGRect {
        let spot = walkthroughSpotlightRect(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let size = CGSize(width: walkthroughCalloutWidth, height: walkthroughCalloutHeight(for: step))
        var originY = spot.minY - walkthroughCalloutGap - size.height
        if originY < toolbarMargin {
            originY = spot.maxY + walkthroughCalloutGap
        }
        if originY + size.height + toolbarMargin > bounds.height {
            originY = max(toolbarMargin, bounds.height - size.height - toolbarMargin)
        }
        var originX = spot.midX - size.width / 2
        originX = min(max(originX, toolbarMargin), bounds.width - size.width - toolbarMargin)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// "Next" on every step but the last, which reads "Got it" and ends the tour.
    static func walkthroughNextLabel(for step: ToolbarWalkthroughStep) -> String {
        step == .record ? "Got it" : "Next"
    }

    /// The Next/Got-it capsule: bottom-right corner of the panel's content
    /// inset, sized to its label.
    static func walkthroughNextButtonFrame(
        for step: ToolbarWalkthroughStep,
        forSelection rect: CGRect, in bounds: CGSize,
        fullScreen: Bool, devMode: Bool
    ) -> CGRect {
        let panel = walkthroughCalloutFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let w = ceil((walkthroughNextLabel(for: step) as NSString)
            .size(withAttributes: [.font: walkthroughNextFont]).width) + walkthroughNextHPad * 2
        return CGRect(
            x: panel.maxX - walkthroughCalloutPad - w,
            y: panel.maxY - walkthroughCalloutPad - walkthroughButtonHeight,
            width: w, height: walkthroughButtonHeight
        )
    }

    /// The quiet Back label's rect: bottom-left corner of the content inset,
    /// with `walkthroughBackHPad` slop around the text. `.zero` on the first
    /// step — Back is hidden there (nowhere to go back to).
    static func walkthroughBackButtonFrame(
        for step: ToolbarWalkthroughStep,
        forSelection rect: CGRect, in bounds: CGSize,
        fullScreen: Bool, devMode: Bool
    ) -> CGRect {
        guard step != .mode else { return .zero }
        let panel = walkthroughCalloutFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        let w = ceil(("Back" as NSString)
            .size(withAttributes: [.font: walkthroughBackFont]).width) + walkthroughBackHPad * 2
        return CGRect(
            x: panel.minX + walkthroughCalloutPad - walkthroughBackHPad,
            y: panel.maxY - walkthroughCalloutPad - walkthroughButtonHeight,
            width: w, height: walkthroughButtonHeight
        )
    }

    /// Which walkthrough callout button `point` lands on, or nil for any
    /// other point (all inert while the tour runs).
    enum WalkthroughHit { case next, back }

    /// THE dispatch decision for a press while the walkthrough is active —
    /// the controller's mouse monitor routes on exactly this. Pure + static
    /// so the routing is testable without driving NSEvent. Back is only
    /// hittable past the first step (it's hidden at `.mode`, where its frame
    /// is `.zero` anyway — the explicit step guard keeps the intent legible).
    static func walkthroughHit(
        at point: CGPoint, for step: ToolbarWalkthroughStep,
        forSelection rect: CGRect, in bounds: CGSize,
        fullScreen: Bool, devMode: Bool
    ) -> WalkthroughHit? {
        if walkthroughNextButtonFrame(
            for: step, forSelection: rect, in: bounds,
            fullScreen: fullScreen, devMode: devMode
        ).contains(point) {
            return .next
        }
        if step != .mode,
           walkthroughBackButtonFrame(
            for: step, forSelection: rect, in: bounds,
            fullScreen: fullScreen, devMode: devMode
           ).contains(point) {
            return .back
        }
        return nil
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
    /// Fixed height of the static credit-cost notice at the very top of the
    /// toolbar model menu (above the "Model" header). FIXED so the row hit-test
    /// math (`modelMenuRowIndex`) stays exact — the wrapping text + divider are
    /// pinned into this band. Only the standard model menu carries it.
    static let modelMenuNoticeHeight: CGFloat = 72
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
        // The notice band sits above the "Model" header, so it adds to the panel
        // height (and shifts the rows down — mirrored in `modelMenuRowIndex`).
        let height = modelMenuNoticeHeight + menuSectionHeaderHeight + CGFloat(itemCount) * modelMenuRowHeight + menuVPad * 2
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
        // Skip the top inset, the static notice band, AND the "Model" header to
        // land on row 0 (the notice + header are non-interactive).
        let localY = point.y - frame.minY - menuVPad - modelMenuNoticeHeight - menuSectionHeaderHeight
        guard localY >= 0 else { return nil }
        let idx = Int(localY / modelMenuRowHeight)
        guard idx >= 0, idx < itemCount else { return nil }
        return idx
    }

    // MARK: - Upgrade popup geometry (trial model-lock)
    //
    // A small card anchored to the model chip exactly like the model dropdown
    // (shared `anchoredMenuFrame` → flips above when there's no room below,
    // clamps horizontally), drawn through `menuPanel` + `menuCaret` so it wears
    // the same panel fill / hairline / shadow / caret. Fixed height so the
    // Upgrade button's hit-rect (bottom-anchored, computed below) matches where
    // the view renders it.

    static let upgradeMenuWidth: CGFloat = 264
    static let upgradeMenuHeight: CGFloat = 152
    /// Inset inside the popup panel (matches the button's left/right inset).
    static let upgradeMenuPad: CGFloat = 14
    static let upgradeButtonHeight: CGFloat = 34

    /// Panel frame for the upgrade popup, anchored under the model chip.
    static func upgradeMenuFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let icon = modelChipFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        return anchoredMenuFrame(under: icon, width: upgradeMenuWidth, height: upgradeMenuHeight, in: bounds)
    }

    /// The Upgrade button's hit-rect: full-width (inset `upgradeMenuPad` each
    /// side) and pinned to the panel's bottom inset — the same place the view's
    /// bottom-aligned button renders, so render == hit-test.
    static func upgradeButtonFrame(forSelection rect: CGRect, in bounds: CGSize, fullScreen: Bool = false, devMode: Bool = false) -> CGRect {
        let panel = upgradeMenuFrame(forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
        return CGRect(
            x: panel.minX + upgradeMenuPad,
            y: panel.maxY - upgradeMenuPad - upgradeButtonHeight,
            width: panel.width - upgradeMenuPad * 2,
            height: upgradeButtonHeight
        )
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
    /// The Model section caps at this many visible rows; beyond it the section
    /// becomes a scrollable viewport. Cursor lists ~25–30 curated models, which
    /// would otherwise push the menu off the bottom of the screen. Kept compact so
    /// the whole panel (Agent + capped Model viewport + Permissions + Project) stays
    /// well within a typical `visibleFrame`. The Agent section stays full height
    /// (it's only ~3 rows — no need to scroll it).
    static let maxVisibleModelRows = 5
    /// The Permissions section's fixed row count (Ask Permission / Auto-Approve /
    /// Unrestricted) — the dev-settings menu's permission-tier picker, between
    /// Model and Project.
    static let devPermissionRowCount = DevPermissionTier.allCases.count
    /// Size of the non-interactive safety indicator (git-shield / ⚠) on the
    /// collapsed Permissions SUMMARY row, and its hover sub-rect
    /// (`devSettingsPermissionSafetyIconRect`). It sits to the LEFT of the chevron.
    static let permissionTrailingIconSize: CGFloat = 16
    /// Hover-tooltip copy for the fenced tiers' git-shield (verbatim the old
    /// bottom-row reassurance line).
    static let permissionGitSnapshotTooltip = "Snapshots with git before each change, so you can undo anything."
    /// Hover-tooltip copy for the Unrestricted ⚠.
    static let permissionUnrestrictedTooltip = "Can make changes outside the git snapshot that Zerro may not be able to undo."
    /// Width of the disclosure chevron box on each collapsed summary row (Agent /
    /// Model / Permissions). The chevron is the RIGHTMOST trailing element, pinned
    /// to the row's right inset edge; shared by the renderer and the safety-icon
    /// hit-test so both agree on where the safety icon lands (to the chevron's left).
    static let devSummaryChevronWidth: CGFloat = 12
    /// Spacing between trailing summary-row elements (the HStack spacing): label↔
    /// value, value↔safety-icon, safety-icon↔chevron all use this.
    static let devSummaryTrailingGap: CGFloat = 6

    // MARK: Auto-Detect Project toggle row (Project section)
    //
    // The Project section leads with an "Auto-Detect Project" toggle row (the
    // opt-in that requests browser permission) above the folder/"Change…" row. Its
    // label width is measured (+2pt slop so the SwiftUI Text never truncates) and
    // SHARED by the renderer and the info-icon hit-test, so the info glyph lands
    // exactly where hover is detected — the same render==hit-test discipline the
    // rest of this menu lives by.
    static let autoDetectRowLabel = "Auto-Detect Project"
    /// Horizontal padding inside dev-menu rows (matches the rows' `.padding(.horizontal, 12)`).
    static let devMenuRowHPad: CGFloat = 12
    /// Gap between the Auto-Detect label and its info icon.
    static let autoDetectInfoGap: CGFloat = 6
    /// The info-icon hover/hit sub-rect size.
    static let autoDetectInfoIconSize: CGFloat = 16
    /// Width reserved for the Auto-Detect label (measured + 2pt), shared by the
    /// renderer's `.frame(width:)` and the info-icon hit-test.
    static let autoDetectLabelWidth: CGFloat =
        ((autoDetectRowLabel as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width).rounded(.up) + 2
    /// Custom-tooltip copy for the Auto-Detect info icon. Shown via `tooltipInfo`/
    /// `toolbarTooltip` (NOT `.help`, which can't fire through the hit-test-disabled
    /// overlay).
    static let autoDetectInfoTooltip =
        "Auto-matches your project folder to the localhost site you’re recording, by reading your browser’s address. Turning this on asks for browser permission once."

    // MARK: Dev-settings accordion layout (compact summary rows)
    //
    // Agent / Model / Permissions each collapse to ONE summary row; clicking opens
    // that section's option list inline (one open at a time). `DevMenuLayout` is the
    // SINGLE source of truth for every vertical anchor — the height calc AND every
    // hit-test offset derive from it, so the top-down render and the AppKit hit-test
    // stay in lockstep across the collapsed/expanded states.

    /// Vertical anchors of the dev-settings menu for a given expansion state.
    struct DevMenuLayout {
        let frame: CGRect
        let agentSummaryTop: CGFloat
        let agentOptionsTop: CGFloat
        let agentOptionRows: Int       // 0 unless Agent is expanded
        let modelSummaryTop: CGFloat
        let modelOptionsTop: CGFloat
        let modelOptionRows: Int       // 0 unless Model is expanded (capped)
        let permissionsSummaryTop: CGFloat
        let permissionsOptionsTop: CGFloat
        let permissionOptionRows: Int  // 0 unless Permissions is expanded
        let projectHeaderTop: CGFloat
        let autoDetectTop: CGFloat
        let projectRowTop: CGFloat
    }

    /// Compute the menu's frame + all section anchors for `expanded`. The Model
    /// option list is CAPPED at `maxVisibleModelRows` (scrolls beyond).
    static func devMenuLayout(
        forSelection rect: CGRect,
        in bounds: CGSize,
        agentCount: Int,
        modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection?,
        fullScreen: Bool = false
    ) -> DevMenuLayout {
        let agentOpt = expanded == .agent ? agentCount : 0
        let modelOpt = expanded == .model ? min(modelCount, maxVisibleModelRows) : 0
        let permOpt = expanded == .permissions ? devPermissionRowCount : 0
        let rowH = devMenuRowHeight

        let height = menuVPad
            + rowH + CGFloat(agentOpt) * rowH        // Agent summary (+ options)
            + devMenuDividerBand
            + rowH + CGFloat(modelOpt) * rowH         // Model summary (+ options)
            + devMenuDividerBand
            + rowH + CGFloat(permOpt) * rowH          // Permissions summary (+ options)
            + devMenuDividerBand
            + menuSectionHeaderHeight + 2 * rowH       // Project (header + Auto-Detect + Change…)
            + menuVPad
        let icon = devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: fullScreen)
        let frame = anchoredMenuFrame(under: icon, width: devMenuWidth, height: height, in: bounds)

        let agentSummaryTop = frame.minY + menuVPad
        let modelSummaryTop = agentSummaryTop + rowH + CGFloat(agentOpt) * rowH + devMenuDividerBand
        let permissionsSummaryTop = modelSummaryTop + rowH + CGFloat(modelOpt) * rowH + devMenuDividerBand
        let projectHeaderTop = permissionsSummaryTop + rowH + CGFloat(permOpt) * rowH + devMenuDividerBand
        return DevMenuLayout(
            frame: frame,
            agentSummaryTop: agentSummaryTop,
            agentOptionsTop: agentSummaryTop + rowH,
            agentOptionRows: agentOpt,
            modelSummaryTop: modelSummaryTop,
            modelOptionsTop: modelSummaryTop + rowH,
            modelOptionRows: modelOpt,
            permissionsSummaryTop: permissionsSummaryTop,
            permissionsOptionsTop: permissionsSummaryTop + rowH,
            permissionOptionRows: permOpt,
            projectHeaderTop: projectHeaderTop,
            autoDetectTop: projectHeaderTop + menuSectionHeaderHeight,
            projectRowTop: projectHeaderTop + menuSectionHeaderHeight + rowH
        )
    }

    /// The anchored menu frame (thin wrapper over `devMenuLayout`). `expanded`
    /// defaults to nil (all collapsed) so non-render call sites stay terse.
    static func devSettingsMenuFrame(forSelection rect: CGRect, in bounds: CGSize, agentCount: Int, modelCount: Int, expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false) -> CGRect {
        devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen).frame
    }

    /// Full-width frame of a collapsed section's SUMMARY row (always present),
    /// whose click toggles that section's expansion.
    static func devSettingsSummaryRowFrame(
        _ section: AreaSelectorState.DevMenuSection,
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection?, fullScreen: Bool = false
    ) -> CGRect {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        let top: CGFloat
        switch section {
        case .agent:       top = l.agentSummaryTop
        case .model:       top = l.modelSummaryTop
        case .permissions: top = l.permissionsSummaryTop
        }
        return CGRect(x: l.frame.minX, y: top, width: l.frame.width, height: devMenuRowHeight)
    }

    /// Index of the Agent OPTION row under `point` (only when Agent is expanded),
    /// else nil.
    static func devSettingsAgentRowIndex(
        at point: CGPoint, forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> Int? {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        guard l.agentOptionRows > 0 else { return nil }
        let localY = point.y - l.agentOptionsTop
        guard localY >= 0 else { return nil }
        let idx = Int(localY / devMenuRowHeight)
        guard idx >= 0, idx < l.agentOptionRows else { return nil }
        return idx
    }

    /// The Model OPTION viewport rect (only non-empty when Model is expanded) — the
    /// scrollable band of up to `maxVisibleModelRows` rows. Single source of truth
    /// for both the hit-test and the scroll-wheel region.
    static func devSettingsModelViewportRect(
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> CGRect {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        return CGRect(x: l.frame.minX, y: l.modelOptionsTop, width: l.frame.width, height: CGFloat(l.modelOptionRows) * devMenuRowHeight)
    }

    /// ABSOLUTE index of the Model OPTION row under `point` (only when Model is
    /// expanded), folding in `scrollOffset`; nil outside the viewport.
    static func devSettingsModelRowIndex(
        at point: CGPoint, forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int, scrollOffset: Int = 0,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> Int? {
        let viewport = devSettingsModelViewportRect(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        guard viewport.height > 0, viewport.contains(point) else { return nil }
        let visibleCount = min(modelCount, maxVisibleModelRows)
        let visibleIndex = Int((point.y - viewport.minY) / devMenuRowHeight)
        guard visibleIndex >= 0, visibleIndex < visibleCount else { return nil }
        let index = visibleIndex + scrollOffset
        guard index >= 0, index < modelCount else { return nil }
        return index
    }

    /// Index of the Permissions OPTION row under `point` (0 = Ask Permission …
    /// 2 = Unrestricted), only when Permissions is expanded, else nil.
    static func devSettingsPermissionRowIndex(
        at point: CGPoint, forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> Int? {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        guard l.permissionOptionRows > 0 else { return nil }
        let localY = point.y - l.permissionsOptionsTop
        guard localY >= 0 else { return nil }
        let idx = Int(localY / devMenuRowHeight)
        guard idx >= 0, idx < l.permissionOptionRows else { return nil }
        return idx
    }

    /// The non-interactive safety-icon hover sub-rect on the Permissions SUMMARY
    /// row: a `permissionTrailingIconSize` box sitting to the LEFT of the disclosure
    /// chevron at the row's right inset edge, vertically centered. Uses the SAME
    /// trailing math the renderer lays the icon out with, so the rect and the drawn
    /// glyph stay in lockstep. Hover-only — it never affects the row's toggle click.
    static func devSettingsPermissionSafetyIconRect(
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> CGRect {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        let size = permissionTrailingIconSize
        // chevron occupies the rightmost slot; the safety icon sits to its left.
        let x = l.frame.maxX - devMenuRowHPad - devSummaryChevronWidth - devSummaryTrailingGap - size
        let y = l.permissionsSummaryTop + (devMenuRowHeight - size) / 2
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// The per-tier safety-icon hover sub-rect on EXPANDED permission OPTION row
    /// `rowIndex` (0 = Ask Permission … 2 = Unrestricted). Column-aligned with the
    /// summary row's safety icon (the option icon is trailing-padded by chevron +
    /// gap), so the rect and the drawn glyph stay in lockstep. Only meaningful when
    /// Permissions is expanded; hover-only — it never affects tier selection.
    static func devSettingsPermissionOptionSafetyIconRect(
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int, rowIndex: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> CGRect {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        let size = permissionTrailingIconSize
        let rowTop = l.permissionsOptionsTop + CGFloat(rowIndex) * devMenuRowHeight
        let x = l.frame.maxX - devMenuRowHPad - devSummaryChevronWidth - devSummaryTrailingGap - size
        let y = rowTop + (devMenuRowHeight - size) / 2
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// Frame of the Auto-Detect Project toggle row (first Project row).
    static func devSettingsAutoDetectRowFrame(
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> CGRect {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        return CGRect(x: l.frame.minX, y: l.autoDetectTop, width: l.frame.width, height: devMenuRowHeight)
    }

    /// The info-icon hover sub-rect inside the Auto-Detect row (unchanged copy/UX).
    static func devSettingsAutoDetectInfoIconRect(
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> CGRect {
        let row = devSettingsAutoDetectRowFrame(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        let x = row.minX + devMenuRowHPad + autoDetectLabelWidth + autoDetectInfoGap
        let y = row.midY - autoDetectInfoIconSize / 2
        return CGRect(x: x, y: y, width: autoDetectInfoIconSize, height: autoDetectInfoIconSize)
    }

    /// Frame of the Project ("Change…") row — clicking it opens the folder picker.
    static func devSettingsProjectRowFrame(
        forSelection rect: CGRect, in bounds: CGSize,
        agentCount: Int, modelCount: Int,
        expanded: AreaSelectorState.DevMenuSection? = nil, fullScreen: Bool = false
    ) -> CGRect {
        let l = devMenuLayout(forSelection: rect, in: bounds, agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fullScreen)
        return CGRect(x: l.frame.minX, y: l.projectRowTop, width: l.frame.width, height: devMenuRowHeight)
    }

    // MARK: - CleanShot-style dropdown chrome
    //
    // The model/mic/dev-settings menus share one look: a dark rounded panel
    // (`menuFill`), an overlay border, a caret pointing at the anchor icon, and a
    // small gray section header above the rows. The chrome is deliberately flat:
    // applying a shadow to this composite also shadows opaque hover/selection
    // rows inside it. Each menu function emits the panel + caret as siblings
    // positioned at the static frames the controller hit-tests against.

    /// Solid dark panel fill for the dropdowns (CleanShot reads as solid, not
    /// translucent — and a solid color also snapshots faithfully).
    static let menuFill = Color.vfDropdownBackground
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
                    .strokeBorder(Color.vfOverlayBorder, lineWidth: 1)
            )
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

    /// Static, non-interactive disclaimer at the top of the toolbar model menu:
    /// pricier models burn credits / usage limits faster. Pinned into a FIXED
    /// `modelMenuNoticeHeight` band (text top-aligned, a hairline divider pinned
    /// to the bottom) so the row hit-test geometry stays exact regardless of how
    /// the copy wraps. Muted tertiary text + smaller font, mirroring the section
    /// header treatment so it reads as helper text, not a selectable row.
    private var modelMenuNotice: some View {
        VStack(spacing: 0) {
            Text("More capable models produce more thorough responses, but use more credits and reach your usage limits faster.")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Spacer(minLength: 6)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)
        }
        .frame(height: Self.modelMenuNoticeHeight)
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

    /// Shared fill-only dropdown-row treatment, inset from the panel edges.
    /// Hover, persistent selection, and selected-hover are deliberately
    /// distinct. Selected rows have no stroke or outline.
    private func menuRowHighlight(selected: Bool = false, hovered: Bool) -> some View {
        let fill: Color
        if selected && hovered {
            fill = .vfDropdownRowSelectedHover
        } else if selected {
            fill = .vfDropdownRowSelected
        } else if hovered {
            fill = .vfDropdownRowHover
        } else {
            fill = .clear
        }

        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
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
                    modelMenuNotice
                    menuSectionHeader("Model")
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let selected = item.id == state.selectedModelID
                        let hovered = state.highlightedModelIndex == index && !item.gated
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.vfTextPrimary)   // neutral white check
                                .opacity(selected ? 1 : 0)
                                .frame(width: 14)
                            Text(item.name)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected || hovered ? Color.vfTextPrimary : Color.vfTextSecondary)
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
                        .background(menuRowHighlight(selected: selected, hovered: hovered))
                        .opacity(item.gated ? 0.45 : 1)
                    }
                }
                .padding(.vertical, Self.menuVPad)
            }

            menuCaret(centerX: icon.midX, edgeY: down ? frame.minY : frame.maxY, pointingUp: down, panel: frame)
        }
    }

    /// The trial model-lock upgrade popup: a small card (title + one line of body
    /// + a white Upgrade button) anchored to the model chip, drawn with the same
    /// panel chrome + caret as the model dropdown. Opening is intercepted by the
    /// controller in place of the model list while `isModelPickerLocked`; the
    /// button opens the voluntary-upgrade paywall (always presentable).
    @ViewBuilder
    private func upgradeMenu(in bounds: CGSize) -> some View {
        if state.isUpgradePopupOpen, let rect = state.confirmableSelectionRect {
            let icon = Self.modelChipFrame(forSelection: rect, in: bounds, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            let frame = Self.upgradeMenuFrame(forSelection: rect, in: bounds, fullScreen: state.mode == .fullScreen, devMode: state.isDevMode)
            let down = Self.menuOpensDownward(menuFrame: frame, iconFrame: icon)

            menuPanel(frame: frame) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upgrade to unlock premium models")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Premium models are only available on paid plans.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Text("Upgrade")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vfOnBrand)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.upgradeButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.vfBrandAccent)
                        )
                        // Subtle press/hover feedback on the accent fill.
                        .opacity(state.isUpgradeButtonHovered ? 0.9 : 1)
                }
                .padding(.horizontal, Self.upgradeMenuPad)
                .padding(.vertical, Self.upgradeMenuPad)
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
                        let hovered = state.highlightedMicIndex == index
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.vfTextPrimary)
                                .opacity(selected ? 1 : 0)
                                .frame(width: 14)
                            Text(item.name)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected || hovered ? Color.vfTextPrimary : Color.vfTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: Self.micMenuRowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(menuRowHighlight(selected: selected, hovered: hovered))
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
            let expanded = state.expandedDevSection
            let icon = Self.devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: state.mode == .fullScreen)
            let frame = Self.devSettingsMenuFrame(forSelection: rect, in: bounds, agentCount: agents.count, modelCount: models.count, expanded: expanded, fullScreen: state.mode == .fullScreen)
            let down = Self.menuOpensDownward(menuFrame: frame, iconFrame: icon)

            menuPanel(frame: frame) {
                VStack(spacing: 0) {
                    // Compact accordion: Agent / Model / Permissions each collapse to
                    // a single summary row showing the current selection; clicking
                    // expands that section's option list (one open at a time).

                    // Agent.
                    devSummaryRow(.agent, label: "Agent",
                                  value: agents.first { $0.id == state.selectedAgentID }?.name ?? "Select")
                    if expanded == .agent {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, item in
                            devAgentRow(
                                item,
                                selected: item.id == state.selectedAgentID,
                                hovered: state.highlightedDevAgentIndex == index
                            )
                        }
                    }

                    devMenuDivider

                    // Model — the selected agent's models, checkmark on the current
                    // pick. Capped to a scrollable viewport (the list can be long).
                    devSummaryRow(.model, label: "Model",
                                  value: models.first { $0.id == state.selectedDevModelID }?.name ?? "Default")
                    if expanded == .model {
                        devModelViewport(models)
                    }

                    devMenuDivider

                    // Permissions: the single trust dial — Ask Permission / Auto-Approve
                    // (fenced) / Unrestricted (fences off). The summary row carries the
                    // current tier's safety icon (green shield / amber ⚠) + tooltip.
                    devSummaryRow(.permissions, label: "Permissions",
                                  value: Self.devPermissionTitle(state.devPermissionTier))
                    if expanded == .permissions {
                        devPermissionRow(.askPermission, index: 0)
                        devPermissionRow(.autoApprove, index: 1)
                        devPermissionRow(.unrestricted, index: 2)
                    }

                    devMenuDivider

                    // Project section: the Auto-Detect toggle (the opt-in that
                    // requests browser permission) leads, then the folder /
                    // "Change…" row beneath it.
                    devProjectSectionHeader
                    devAutoDetectToggleRow
                    devProjectRow
                }
                .padding(.vertical, Self.menuVPad)
            }

            menuCaret(centerX: icon.midX, edgeY: down ? frame.minY : frame.maxY, pointingUp: down, panel: frame)
        }
    }

    /// A collapsed section's summary row: "[label] [current selection] … [safety
    /// icon (permissions only)] [chevron]". The whole row is one click target
    /// (`devSettingsSummaryRowFrame`) that toggles the section's expansion; the
    /// safety icon adds only a hover sub-rect (`devSettingsPermissionSafetyIconRect`)
    /// for its custom tooltip (the glyph's `.help` can't fire through the overlay).
    /// Trailing layout (HStack spacing == `devSummaryTrailingGap`) keeps the safety
    /// icon + chevron exactly where the hit-test math expects them.
    private func devSummaryRow(_ section: AreaSelectorState.DevMenuSection, label: String, value: String) -> some View {
        let expandedHere = state.expandedDevSection == section
        let highlighted = state.hoveredDevSummary == section
        return HStack(spacing: Self.devSummaryTrailingGap) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if section == .permissions {
                let unrestricted = state.devPermissionTier == .unrestricted
                Image(systemName: unrestricted ? "exclamationmark.triangle.fill" : "checkmark.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(unrestricted ? Color.vfWarningAmber : Color.vfDevAccent)
                    .frame(width: Self.permissionTrailingIconSize, height: Self.permissionTrailingIconSize)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vfTextTertiary)
                .rotationEffect(.degrees(expandedHere ? 180 : 0))
                .frame(width: Self.devSummaryChevronWidth, height: Self.devSummaryChevronWidth)
        }
        .padding(.horizontal, Self.devMenuRowHPad)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(menuRowHighlight(selected: expandedHere, hovered: highlighted))
    }

    /// The "Project" section header. Matches the collapsed summary rows' label
    /// style (size 13, `vfTextTertiary`) rather than the smaller shared
    /// `menuSectionHeader` (11pt) so the four section labels read consistently. The
    /// fixed `menuSectionHeaderHeight` band is unchanged, so the hit-test math is
    /// untouched.
    private var devProjectSectionHeader: some View {
        Text("Project")
            .font(.system(size: 13))
            .foregroundStyle(Color.vfTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.devMenuRowHPad)
            .padding(.bottom, 4)
            .frame(height: Self.menuSectionHeaderHeight, alignment: .bottom)
    }

    /// The Model section as a fixed-height, clipped viewport: shows the
    /// `min(count, maxVisibleModelRows)` rows starting at `devModelScrollOffset`,
    /// so a long list (Cursor) scrolls instead of growing the panel off-screen.
    /// Rows are rendered with their ABSOLUTE indices, so the hover highlight + the
    /// controller's hit-test (`devSettingsModelRowIndex`, which folds in the same
    /// offset) stay in lockstep. A short list (≤ cap) renders all rows at offset
    /// 0 — identical to the pre-scroll layout.
    @ViewBuilder
    private func devModelViewport(_ models: [AreaSelectorState.DevModelMenuItem]) -> some View {
        let visibleCount = min(models.count, Self.maxVisibleModelRows)
        // Defensive re-clamp: the state keeps the offset in range, but never index
        // the array off a stale value.
        let offset = min(max(state.devModelScrollOffset, 0), max(0, models.count - visibleCount))
        let window = models.enumerated().filter { offset <= $0.offset && $0.offset < offset + visibleCount }
        let viewportHeight = CGFloat(visibleCount) * Self.devMenuRowHeight
        VStack(spacing: 0) {
            ForEach(window, id: \.element.id) { index, item in
                devModelRow(
                    item,
                    selected: item.id == state.selectedDevModelID,
                    hovered: state.highlightedDevModelIndex == index
                )
            }
        }
        .frame(height: viewportHeight, alignment: .top)
        .clipped()
        // Scrollability affordance: a thin scroll indicator (only when the list
        // exceeds the cap) whose height + position reflect the visible window, so
        // it's discoverable that more rows exist and where you are in the list.
        .overlay(alignment: .topTrailing) {
            if models.count > visibleCount {
                devModelScrollIndicator(viewportHeight: viewportHeight, count: models.count,
                                        visibleCount: visibleCount, offset: offset)
            }
        }
    }

    /// A slim, non-interactive scroll thumb pinned to the Model viewport's right
    /// edge. Height ∝ visible fraction; vertical offset ∝ scroll position.
    private func devModelScrollIndicator(viewportHeight: CGFloat, count: Int, visibleCount: Int, offset: Int) -> some View {
        let thumbHeight = max(28, viewportHeight * CGFloat(visibleCount) / CGFloat(count))
        let maxOffset = CGFloat(count - visibleCount)
        let thumbY = maxOffset > 0 ? (viewportHeight - thumbHeight) * CGFloat(offset) / maxOffset : 0
        return Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 3, height: thumbHeight)
            .padding(.trailing, 3)
            .offset(y: thumbY)
            .allowsHitTesting(false)
    }

    /// One Model-section row: green checkmark on the current pick, a model icon,
    /// the display name. Mirrors `devAgentRow` (CleanShot style).
    private func devModelRow(
        _ item: AreaSelectorState.DevModelMenuItem,
        selected: Bool,
        hovered: Bool
    ) -> some View {
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfDevAccent)
                .opacity(selected ? 1 : 0)
                .frame(width: 16)
            Image(systemName: "cpu")
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextSecondary)
            Text(item.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || hovered ? Color.vfTextPrimary : Color.vfTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(menuRowHighlight(selected: selected, hovered: hovered))
    }

    private func devAgentRow(
        _ item: AreaSelectorState.DevAgentMenuItem,
        selected: Bool,
        hovered: Bool
    ) -> some View {
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfDevAccent)   // green check on the active agent
                .opacity(selected ? 1 : 0)
                .frame(width: 16)
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .foregroundStyle(item.installed ? Color.vfTextSecondary : Color.vfTextTertiary)
            Text(item.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(
                    item.installed
                        ? (selected || hovered ? Color.vfTextPrimary : Color.vfTextSecondary)
                        : Color.vfTextTertiary
                )
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
        .background(menuRowHighlight(selected: selected, hovered: hovered))
    }

    /// One Permissions OPTION row (shown when the Permissions section is expanded):
    /// green checkmark on the active tier, the per-tier type icon (hand / lightning
    /// / unlock), the title, and the per-tier SAFETY icon (green shield for the
    /// fenced tiers / amber ⚠ for Unrestricted) at the trailing edge. The trailing
    /// icon is column-aligned with the collapsed summary row's safety icon (it sits
    /// where the chevron would be reserved). Non-interactive — the whole row selects
    /// the tier (`devSettingsPermissionRowIndex`); uniform `devMenuRowHeight` keeps
    /// render == hit-test.
    private func devPermissionRow(_ tier: DevPermissionTier, index: Int) -> some View {
        let active = state.devPermissionTier == tier
        let hovered = state.highlightedDevPermissionIndex == index
        let unrestricted = tier == .unrestricted
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfDevAccent)   // green check on the active tier
                .opacity(active ? 1 : 0)
                .frame(width: 16)
            Image(systemName: Self.devPermissionIcon(tier))
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextSecondary)
                // Fixed width so the differently-sized glyphs don't shift labels.
                .frame(width: 16)
            Text(Self.devPermissionTitle(tier))
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active || hovered ? Color.vfTextPrimary : Color.vfTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            // Per-tier safety icon, trailing-padded by (chevron + gap) so it lines
            // up with the summary row's safety-icon column above.
            Image(systemName: unrestricted ? "exclamationmark.triangle.fill" : "checkmark.shield")
                .font(.system(size: 12))
                .foregroundStyle(unrestricted ? Color.vfWarningAmber : Color.vfDevAccent)
                .frame(width: Self.permissionTrailingIconSize, height: Self.permissionTrailingIconSize)
                .padding(.trailing, Self.devSummaryChevronWidth + Self.devSummaryTrailingGap)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(menuRowHighlight(selected: active, hovered: hovered))
    }

    /// SF Symbol for a permission tier's row glyph.
    private static func devPermissionIcon(_ tier: DevPermissionTier) -> String {
        switch tier {
        case .askPermission: return "hand.raised"
        case .autoApprove:   return "bolt"
        case .unrestricted:  return "lock.open"
        }
    }

    /// Row label for a permission tier.
    private static func devPermissionTitle(_ tier: DevPermissionTier) -> String {
        switch tier {
        case .askPermission: return "Ask Permission"
        case .autoApprove:   return "Auto-Approve"
        case .unrestricted:  return "Unrestricted"
        }
    }

    /// The Auto-Detect Project toggle row: the label, an info icon (custom-tooltip
    /// only — `.help` can't fire in this overlay), and a mini switch reflecting
    /// `autoDetectProjectEnabled`. The whole row is one click target (the controller
    /// hit-tests `devSettingsAutoDetectRowFrame`); the label width is pinned to
    /// `autoDetectLabelWidth` so the info glyph lands on its hover sub-rect.
    private var devAutoDetectToggleRow: some View {
        let on = state.autoDetectProjectEnabled
        return HStack(spacing: 0) {
            Text(Self.autoDetectRowLabel)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
                .frame(width: Self.autoDetectLabelWidth, alignment: .leading)
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextTertiary)
                .frame(width: Self.autoDetectInfoIconSize, height: Self.autoDetectInfoIconSize)
                .padding(.leading, Self.autoDetectInfoGap)
            Spacer(minLength: 8)
            devMiniSwitch(on: on)
        }
        .padding(.horizontal, Self.devMenuRowHPad)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A compact on/off switch drawn in-tree (the menu is custom-rendered + the
    /// controller owns clicks, so a SwiftUI `Toggle` can't be used). Green
    /// `vfDevAccent` track when ON, neutral when OFF — matching the menu's accent
    /// language.
    private func devMiniSwitch(on: Bool) -> some View {
        let trackW: CGFloat = 30, trackH: CGFloat = 17, knob: CGFloat = 13
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(on ? Color.vfDevAccent : Color.white.opacity(0.20))
            Circle()
                .fill(.white)
                .frame(width: knob, height: knob)
                .padding(2)
        }
        .frame(width: trackW, height: trackH)
        .animation(.easeInOut(duration: 0.15), value: on)
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
            // Phase 3: when the folder was auto-matched from the browser's
            // localhost port, a subtle accent badge says why (overridable via
            // "Change…").
            if state.projectAutoMatchedFromPort, let port = state.detectedLocalhostPort {
                // `String(port)` so the LocalizedStringKey interpolation doesn't
                // apply the locale's thousands separator (e.g. "localhost:5,173").
                Text("localhost:\(String(port))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.vfDevAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.vfDevAccent.opacity(0.14)))
                    .fixedSize()
            }
            Text("Change…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.vfAccentBlue)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.devMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
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

            // Mode switch (Ask | Dev) — the leading control.
            modeSwitchControl
                .frame(width: switchFrame.width, height: switchFrame.height)
                .position(x: switchFrame.midX, y: switchFrame.midY)

            // Vertical hairline separating the switch from the controls — inset
            // to the same vertical band as the well + icon buttons (4pt top/
            // bottom) so nothing spans the full container height.
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: Self.dividerWidth, height: container.height - Self.scaled(8))
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
           let info = tooltipInfo(forSelection: rect, in: bounds) {
            if let maxW = info.maxWidth {
                // Multi-line variant (the Auto-Detect info icon): a wider wrapped
                // bubble measured for height, with a downward caret pointing at the
                // icon. Drawn over the open dev-settings menu (this is the topmost
                // layer in the ZStack).
                let hPad: CGFloat = 10, vPad: CGFloat = 7, caretH: CGFloat = 6, gap: CGFloat = 7
                let textMaxW = maxW - hPad * 2
                let nsFont = NSFont.systemFont(ofSize: 11, weight: .medium)
                let measured = (info.text as NSString).boundingRect(
                    with: CGSize(width: textMaxW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: nsFont]
                )
                let textW = min(ceil(measured.width), textMaxW)
                let bubbleW = textW + hPad * 2
                let bubbleH = ceil(measured.height) + vPad * 2
                let cx = min(max(info.anchor.midX, bubbleW / 2 + Self.toolbarMargin),
                             bounds.width - bubbleW / 2 - Self.toolbarMargin)
                let bubbleCenterY = info.anchor.minY - gap - caretH - bubbleH / 2
                let bubbleRect = CGRect(x: cx - bubbleW / 2, y: bubbleCenterY - bubbleH / 2,
                                        width: bubbleW, height: bubbleH)
                Text(info.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(width: textW, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: bubbleW, height: bubbleH)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.menuFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.vfOverlayBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    .position(x: cx, y: bubbleCenterY)
                menuCaret(centerX: info.anchor.midX, edgeY: bubbleRect.maxY, pointingUp: false, panel: bubbleRect)
            } else {
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
                                .strokeBorder(Color.vfOverlayBorder, lineWidth: 1)
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
    }

    /// Text + anchor (+ optional wrap width) for the currently-hovered control, or
    /// nil when none is hovered (or when the hovered control — Record — carries its
    /// own label). A non-nil `maxWidth` selects the multi-line bubble variant.
    /// Internal (not private) so the geometry tests can exercise it.
    func tooltipInfo(forSelection rect: CGRect, in bounds: CGSize) -> (text: String, anchor: CGRect, maxWidth: CGFloat?)? {
        // While the walkthrough is active its callout owns the bubble layer —
        // suppress hover tooltips entirely so the two never collide (same
        // pattern as the open-menu suppression below).
        guard state.toolbarWalkthroughStep == nil else { return nil }

        let fs = state.mode == .fullScreen
        let dev = state.isDevMode

        // While the dev-settings menu is open, the only tooltips are the in-menu
        // icons' (the Permissions safety icon + the Auto-Detect info icon) — the
        // toolbar control tooltips are suppressed (they'd collide with the open menu).
        if state.isDevSettingsMenuOpen {
            guard dev else { return nil }
            let agentCount = state.devAgentMenuItems.count
            let modelCount = state.devModelMenuItems.count
            let expanded = state.expandedDevSection
            // The Permissions summary row's safety icon is hovered → the current
            // tier's reassurance / warning copy, anchored to the icon (multi-line).
            if state.isPermissionSafetyHovered {
                let anchor = Self.devSettingsPermissionSafetyIconRect(
                    forSelection: rect, in: bounds,
                    agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fs)
                let copy = state.devPermissionTier == .unrestricted
                    ? Self.permissionUnrestrictedTooltip
                    : Self.permissionGitSnapshotTooltip
                return (copy, anchor, 240)
            }
            // An EXPANDED option row's safety icon is hovered → THAT tier's copy,
            // anchored to its icon.
            if let row = state.hoveredPermissionOptionSafety,
               row >= 0, row < DevPermissionTier.allCases.count {
                let anchor = Self.devSettingsPermissionOptionSafetyIconRect(
                    forSelection: rect, in: bounds,
                    agentCount: agentCount, modelCount: modelCount, rowIndex: row, expanded: expanded, fullScreen: fs)
                let copy = DevPermissionTier.allCases[row] == .unrestricted
                    ? Self.permissionUnrestrictedTooltip
                    : Self.permissionGitSnapshotTooltip
                return (copy, anchor, 240)
            }
            guard state.isAutoDetectInfoHovered else { return nil }
            let anchor = Self.devSettingsAutoDetectInfoIconRect(
                forSelection: rect, in: bounds,
                agentCount: agentCount, modelCount: modelCount, expanded: expanded, fullScreen: fs)
            return (Self.autoDetectInfoTooltip, anchor, 240)
        }

        // Any other dropdown / the upgrade popup open → no toolbar tooltips
        // (they'd collide with the open surface).
        if state.isModelMenuOpen || state.isMicMenuOpen || state.isUpgradePopupOpen { return nil }

        if state.isModeAskHovered {
            return ("Ask", Self.modeAskSegmentFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev), nil)
        }
        if state.isModeDevHovered {
            return ("Dev Mode", Self.modeDevSegmentFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev), nil)
        }
        if state.isModelChipHovered {
            // The model name is shown in the button itself, so the tooltip is
            // just the control's purpose.
            return ("Model", Self.modelChipFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev), nil)
        }
        if state.isMicChipHovered {
            return ("Microphone: \(state.selectedMicrophoneName)", Self.micChipFrame(forSelection: rect, in: bounds, fullScreen: fs, devMode: dev), nil)
        }
        if dev, state.isDevSettingsHovered {
            return ("Agent & project", Self.devSettingsIconFrame(forSelection: rect, in: bounds, fullScreen: fs), nil)
        }
        return nil
    }

    // MARK: - Compact toolbar chrome
    //
    // One rounded container holds every control. Its background matches the
    // instruction pill (solid `vfPillBackground` + `vfOverlayBorder` stroke)
    // so the overlay chrome reads as one cohesive family. Green (`vfDevAccent`)
    // appears ONLY on the active Dev segment, the dev-settings readiness dot, and
    // inside the dev-settings menu; everything else is neutral and Record red.

    /// Shared opaque chrome for the toolbar container — same treatment as the
    /// instruction pill, with a soft drop shadow for legibility over arbitrary
    /// captured content.
    private var toolbarContainerChrome: some View {
        Capsule(style: .continuous)
            .fill(Color.vfPillBackground)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.vfOverlayBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: Self.scaled(18), y: Self.scaled(6))
    }

    // MARK: Mode switch

    /// The two-segment mode switch: Ask (wand) | Dev (`</>`), inside a
    /// recessed well. The active segment is highlighted — Ask → neutral
    /// neutral control fill, Dev → green `vfDevAccent` tint + green icon — and the inactive
    /// segment's icon is dimmed. Clicking maps to the mode (Part 5 hit-tests the
    /// two halves separately).
    private var modeSwitchControl: some View {
        HStack(spacing: Self.scaled(0)) {
            modeSegment(
                system: "wand.and.stars",
                active: !state.isDevMode, isDev: false,
                hovered: state.isModeAskHovered
            )
            modeSegment(
                system: "chevron.left.forwardslash.chevron.right",
                active: state.isDevMode, isDev: true,
                hovered: state.isModeDevHovered
            )
        }
        .padding(Self.scaled(3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        // Match the icon buttons' vertical inset so the recessed well doesn't
        // touch the container's top/bottom — equal breathing room on every
        // component. The hit-test frame stays full-height (rendering only).
        .padding(.vertical, Self.scaled(4))
    }

    private func modeSegment(system: String, active: Bool, isDev: Bool, hovered: Bool) -> some View {
        let fill: Color = active
            ? (isDev ? Color.vfDevAccent.opacity(0.22) : Color.vfControlBackground)
            : (hovered ? Color.white.opacity(0.06) : .clear)
        let iconColor: Color = active
            ? (isDev ? Color.vfDevAccent : Color.vfTextPrimary)
            : Color.vfTextTertiary
        // The active/hover highlight is a circular knob so the capsule well +
        // round knob read as a toggle switch.
        return Image(systemName: system)
            .font(.system(size: Self.scaledGlyph(14), weight: .medium))
            .foregroundStyle(iconColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Circle().fill(fill)
            )
    }

    // MARK: Icon buttons

    /// A neutral icon + chevron button (model / mic). The chevron flips when its
    /// dropdown is open; a subtle rounded fill brightens on hover/open.
    private func iconButton(system: String, menuOpen: Bool, hovered: Bool) -> some View {
        HStack(spacing: Self.scaled(3)) {
            Image(systemName: system)
                .font(.system(size: Self.scaledGlyph(14), weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
            Image(systemName: "chevron.down")
                .font(.system(size: Self.scaledGlyph(8), weight: .semibold))
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
                .font(.system(size: Self.scaledGlyph(14), weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
            Text(state.selectedModelName)
                .font(Font(Self.modelLabelFont))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize()
            // Locked (trial): a lock glyph where the dropdown chevron would be —
            // tapping opens the upgrade popup, not the model list. Same muted
            // tertiary treatment + ~8pt size as the chevron so the chip baseline
            // is unchanged.
            if state.isModelPickerLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: Self.scaledGlyph(8), weight: .semibold))
                    .foregroundStyle(Color.vfTextTertiary)
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: Self.scaledGlyph(8), weight: .semibold))
                    .foregroundStyle(Color.vfTextTertiary)
                    .rotationEffect(.degrees(state.isModelMenuOpen ? 180 : 0))
            }
        }
        .padding(.horizontal, Self.modelButtonHPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(iconButtonFill(active: state.isModelMenuOpen || state.isUpgradePopupOpen, hovered: state.isModelChipHovered))
    }

    /// Dev-settings icon (Dev Mode only): terminal + chevron with a readiness
    /// dot at the corner — green when an agent + folder are set, amber otherwise.
    private var devSettingsIconButton: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: Self.scaled(3)) {
                Image(systemName: "terminal")
                    .font(.system(size: Self.scaledGlyph(14), weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: Self.scaledGlyph(8), weight: .semibold))
                    .foregroundStyle(Color.vfTextTertiary)
                    .rotationEffect(.degrees(state.isDevSettingsMenuOpen ? 180 : 0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(iconButtonFill(active: state.isDevSettingsMenuOpen, hovered: state.isDevSettingsHovered))

            Circle()
                .fill(state.isDevReady ? Color.vfDevAccent : Color.vfWarningAmber)
                .frame(width: Self.scaled(7), height: Self.scaled(7))
                // Ring in the container color punches a gap so the dot reads as
                // separate from the now-opaque bar.
                .overlay(Circle().stroke(Color.vfPillBackground, lineWidth: 1.5))
                .padding(.top, Self.scaled(5))
                .padding(.trailing, Self.scaled(3))
        }
    }

    private func iconButtonFill(active: Bool, hovered: Bool) -> some View {
        let interactionOpacity = active ? 0.06 : (hovered ? 0.04 : 0)
        return RoundedRectangle(cornerRadius: Self.scaled(9), style: .continuous)
            .fill(Color.vfControlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Self.scaled(9), style: .continuous)
                    .fill(Color.white.opacity(interactionOpacity))
            )
            .padding(.vertical, Self.scaled(4))
            .padding(.horizontal, Self.scaled(1))
    }

    // MARK: Record pill

    /// The labeled Record button — a fully-rounded red capsule, inset slightly
    /// within the container. Its vertical inset (`scaled(4)`) matches the model/
    /// mic/dev dropdown buttons so it reads the same height as them. Always
    /// `vfRecordingRed`, never green; a subtle white tint on hover.
    private var recordPill: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.vfRecordingRed)
            Capsule(style: .continuous).fill(Color.white.opacity(state.isRecordButtonHovered ? 0.12 : 0))
            HStack(spacing: Self.scaled(8)) {
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.scaledGlyph(10), height: Self.scaledGlyph(10))
                Text("Record")
                    .font(.system(size: Self.scaledGlyph(13), weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, Self.scaled(4))
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

    /// "Selection too small" pill: red-tinted feedback anchored where the
    /// floating toolbar would otherwise sit (the toolbar hides below the
    /// minimum size — this is its stand-in, so the empty toolbar slot
    /// explains itself). Appears with the rest of the red feedback once an
    /// undersized rect settles (`isSelectionTooSmall` is quiet mid-drag).
    /// Chrome mirrors `devValidationBanner`; the icon bounces when Return
    /// is refused (`undersizedConfirmPulse`).
    @ViewBuilder
    private func tooSmallMessage(in bounds: CGSize) -> some View {
        if state.isSelectionTooSmall, let rect = state.selectionRect {
            // Measure the pill (same NSString sizing idiom as the tooltip) so
            // it can clamp inside the overlay the way the toolbar does.
            let text = Self.tooSmallMessageText
            let textW = ceil((text as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
            ).width)
            let iconW: CGFloat = 12
            let pillW = VFSpacing.sm * 2 + iconW + VFSpacing.xs + textW
            let pillH: CGFloat = 26

            // Hang below the selection, flip above if it would clip the
            // bottom, clamp inside the overlay — the same fallback math as
            // `toolbarFrame`.
            let originY: CGFloat = {
                var y = rect.maxY + Self.toolbarGap
                if y + pillH + Self.toolbarMargin > bounds.height {
                    y = rect.minY - Self.toolbarGap - pillH
                }
                if y < Self.toolbarMargin {
                    y = max(Self.toolbarMargin, bounds.height - pillH - Self.toolbarMargin)
                }
                return y
            }()
            let centerX = min(
                max(rect.midX, Self.toolbarMargin + pillW / 2),
                bounds.width - pillW / 2 - Self.toolbarMargin
            )

            HStack(spacing: VFSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfRecordingRed)
                    .symbolEffect(.bounce, value: state.undersizedConfirmPulse)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize()
            }
            .padding(.horizontal, VFSpacing.sm)
            .frame(height: pillH)
            .background(Color.vfPillBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.vfRecordingRed.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
            .position(x: centerX, y: originY + pillH / 2)
        }
    }

    /// Copy for the too-small pill, built from `minimumSelectionSize` so the
    /// number can never drift from the actual confirm gate.
    static var tooSmallMessageText: String {
        let m = Int(AreaSelectorState.minimumSelectionSize)
        return "Selection too small. Drag at least \(m) \u{00D7} \(m) to record"
    }

    /// One-time, NON-BLOCKING post-denial explainer (Phase 3): a floating capsule
    /// above the toolbar — like `devValidationBanner`, it's NOT part of the menu's
    /// hit-test geometry. Shown only after the user denies the Automation prompt
    /// (there's no pre-prompt primer — enabling the toggle is the primer). Yields
    /// the slot to a record-time validation message (rarely coincident).
    /// Self-dismissing: cleared on the next action (menu close / folder pick / Dev
    /// off / toggle off / overlay dismiss).
    @ViewBuilder
    private func devLocalhostNoticeBanner(in bounds: CGSize) -> some View {
        if case .denied = state.localhostNotice, state.devValidationMessage == nil,
           let rect = state.confirmableSelectionRect {
            let toolbar = Self.toolbarFrame(
                forSelection: rect, in: bounds,
                fullScreen: state.mode == .fullScreen, devMode: state.isDevMode
            )
            HStack(alignment: .top, spacing: VFSpacing.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfDevAccent)
                Text("To auto-match folders, allow Zerro under System Settings ▸ Privacy ▸ Automation.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 280, alignment: .leading)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 6)
            .background(Color.vfPillBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.vfDevAccent.opacity(0.45), lineWidth: 0.5))
            .position(x: toolbar.midX, y: toolbar.minY - 36)
        }
    }

    // MARK: - Walkthrough rendering (scrim + spotlight + callout)
    //
    // Drawn only while `state.toolbarWalkthroughStep` is active AND the
    // toolbar is on screen (the same gate as `floatingToolbar` — the tour
    // anchors to toolbar controls, so no toolbar → no tour layers). The
    // Back/Next buttons are VISUAL ONLY in this phase: the overlay's SwiftUI
    // tree is hit-test-disabled, so Phase 3 routes their clicks through the
    // controller's mouse monitor against the same static frames rendered here.

    /// Full-overlay dim with a rounded-rect spotlight cutout around the
    /// current step's control (one even-odd path, like `dimCutout`), plus an
    /// accent ring on the cutout so the active control reads as highlighted.
    @ViewBuilder
    private func walkthroughScrim(in bounds: CGSize) -> some View {
        if let step = state.toolbarWalkthroughStep, let rect = state.confirmableSelectionRect {
            let spot = Self.walkthroughSpotlightRect(
                for: step, forSelection: rect, in: bounds,
                fullScreen: state.mode == .fullScreen, devMode: state.isDevMode
            )
            let corner = CGSize(width: Self.walkthroughSpotlightCorner, height: Self.walkthroughSpotlightCorner)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: bounds))
                path.addRoundedRect(in: spot, cornerSize: corner, style: .continuous)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            RoundedRectangle(cornerRadius: Self.walkthroughSpotlightCorner, style: .continuous)
                .stroke(Color.vfBrandAccent, lineWidth: 2)
                .frame(width: spot.width, height: spot.height)
                .position(x: spot.midX, y: spot.midY)
        }
    }

    /// The step callout: the shared menu panel chrome with a caret pointing
    /// at the spotlighted control, carrying the step indicator, title, body
    /// copy, and the (visual-only) Back / Next buttons rendered at their
    /// static hit frames.
    @ViewBuilder
    private func walkthroughCallout(in bounds: CGSize) -> some View {
        if let step = state.toolbarWalkthroughStep, let rect = state.confirmableSelectionRect {
            let fullScreen = state.mode == .fullScreen
            let devMode = state.isDevMode
            let anchor = Self.walkthroughAnchorFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let panel = Self.walkthroughCalloutFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let backFrame = Self.walkthroughBackButtonFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let nextFrame = Self.walkthroughNextButtonFrame(for: step, forSelection: rect, in: bounds, fullScreen: fullScreen, devMode: devMode)
            let below = Self.menuOpensDownward(menuFrame: panel, iconFrame: anchor)
            let textW = Self.walkthroughCalloutWidth - Self.walkthroughCalloutPad * 2

            menuPanel(frame: panel) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 0) {
                        Text("\(step.rawValue + 1) of \(ToolbarWalkthroughStep.allCases.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.vfTextTertiary)
                        Spacer(minLength: 8)
                        if step.isDevModeOnly {
                            Text("Dev Mode only")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.vfDevAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule(style: .continuous).fill(Color.vfDevAccent.opacity(0.14)))
                                .fixedSize()
                        }
                    }
                    .frame(width: textW, height: Self.walkthroughIndicatorHeight, alignment: .leading)
                    Text(step.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                        .frame(width: textW, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Self.walkthroughTitleGap)
                    Text(step.body)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vfTextSecondary)
                        .frame(width: textW, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Self.walkthroughBodyGap)
                }
                .padding(Self.walkthroughCalloutPad)
            }

            // Back — hidden on the first step; quiet text button.
            if step != .mode {
                Text("Back")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                    .frame(width: backFrame.width, height: backFrame.height)
                    .position(x: backFrame.midX, y: backFrame.midY)
            }

            // Next / Got it — the filled primary capsule.
            Text(Self.walkthroughNextLabel(for: step))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfOnBrand)
                .frame(width: nextFrame.width, height: nextFrame.height)
                .background(Capsule(style: .continuous).fill(Color.vfBrandAccent))
                .position(x: nextFrame.midX, y: nextFrame.midY)

            menuCaret(centerX: anchor.midX, edgeY: below ? panel.minY : panel.maxY, pointingUp: below, panel: panel)
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
/// section with the green-checked Claude Code + Detected badge, the Permissions
/// rows with their trailing git-shield / ⚠ indicators, and the Project row with
/// the folder path + Change….
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
            s.setAutoDetectProjectEnabled(true)   // show the Auto-Detect toggle ON
            s.toggleDevSettingsMenu()
            return s
        }())
    }
    .frame(width: 1200, height: 760)
}

/// Dev Mode with Cursor selected and a LONG (~14-row) model list: the Model
/// section caps at `maxVisibleModelRows` and scrolls, with top/bottom fades
/// hinting more rows. Forced to a mid-scroll offset so BOTH fades show; the
/// Agent / Project / git rows stay fixed below the capped viewport.
#Preview("Dev Mode — long model list (scrolls)") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.setDevState(
                isDevMode: true, agentID: "cursor", agentName: "Cursor",
                projectURL: URL(fileURLWithPath: "/Users/you/dev/my-site", isDirectory: true)
            )
            seedDevAgentsLongModelList(s)
            s.setProjectGitRepo(true)
            s.toggleDevSettingsMenu()
            s.setDevModelScrollOffset(4)   // mid-scroll → both fades visible
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

/// Walkthrough step 1 (mode switch): scrim + spotlight on the whole mode
/// switch, callout above with no Back button.
#Preview("Walkthrough — 1 mode") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeSettledPreviewState()
            s.startToolbarWalkthrough()
            return s
        }())
    }
    .frame(width: 1000, height: 640)
}

/// Walkthrough step 4 (agent settings): the state machine borrows Dev Mode
/// for display, so the toolbar grows the dev-settings icon and the spotlight
/// lands on it. Back + Next both visible.
#Preview("Walkthrough — 4 agent (Dev revealed)") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeWalkthroughPreviewState()
            s.advanceToolbarWalkthrough() // model
            s.advanceToolbarWalkthrough() // mic
            s.advanceToolbarWalkthrough() // agent — Dev layout revealed
            return s
        }())
    }
    .frame(width: 1000, height: 640)
}

/// Walkthrough step 5 (record): still in the Dev layout, spotlight on the
/// Record pill, and the primary button reads "Got it".
#Preview("Walkthrough — 5 record (Got it)") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView(state: {
            let s = makeWalkthroughPreviewState()
            s.advanceToolbarWalkthrough() // model
            s.advanceToolbarWalkthrough() // mic
            s.advanceToolbarWalkthrough() // agent
            s.advanceToolbarWalkthrough() // record — "Got it"
            return s
        }())
    }
    .frame(width: 1000, height: 640)
}

/// Settled state + agent/folder seeded (green readiness dot once the tour
/// reveals the Dev layout) with the walkthrough started at step 1.
@MainActor
private func makeWalkthroughPreviewState() -> AreaSelectorState {
    let s = makeSettledPreviewState()
    // Dev OFF pre-tour (the walkthrough borrows it for display); agent +
    // folder chosen so the dev-settings icon's readiness dot shows green.
    s.setDevState(
        isDevMode: false, agentID: "claude-code", agentName: "Claude Code",
        projectURL: URL(fileURLWithPath: "/Users/you/dev/my-site", isDirectory: true)
    )
    seedDevAgents(s)
    s.startToolbarWalkthrough()
    return s
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

/// Cursor selected + a long, curated model list (mirrors the live `cursor-agent
/// models` shape) so the scroll preview exercises the capped Model viewport.
@MainActor
private func seedDevAgentsLongModelList(_ s: AreaSelectorState) {
    s.setDevAgentMenuItems([
        .init(id: "cursor", name: "Cursor", installed: true),
        .init(id: "claude-code", name: "Claude Code", installed: true),
        .init(id: "codex", name: "Codex", installed: false),
    ])
    s.setSelectedAgent(id: "cursor", name: "Cursor")
    s.setDevModelMenuItems([
        .init(id: "auto", name: "Auto"),
        .init(id: "composer-2.5-fast", name: "Composer 2.5 Fast"),
        .init(id: "claude-opus-4-8-high", name: "Opus 4.8 1M"),
        .init(id: "gpt-5.5-high", name: "GPT-5.5 1M High"),
        .init(id: "claude-4.6-sonnet-medium", name: "Sonnet 4.6 1M"),
        .init(id: "gpt-5.4-high", name: "GPT-5.4 1M"),
        .init(id: "claude-opus-4-7-high", name: "Opus 4.7 1M High"),
        .init(id: "gemini-3.1-pro", name: "Gemini 3.1 Pro"),
        .init(id: "grok-4.3", name: "Grok 4.3 1M"),
        .init(id: "claude-4.5-sonnet", name: "Sonnet 4.5"),
        .init(id: "gpt-5.1", name: "GPT-5.1"),
        .init(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash"),
        .init(id: "claude-4-sonnet", name: "Sonnet 4"),
        .init(id: "kimi-k2.5", name: "Kimi K2.5"),
    ], selectedID: "auto")
}
