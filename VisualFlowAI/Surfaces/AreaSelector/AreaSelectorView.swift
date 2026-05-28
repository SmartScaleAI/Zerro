//
//  AreaSelectorView.swift
//  VisualFlowAI
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
            let selection = state.selectionRect

            ZStack(alignment: .topLeading) {
                dimCutout(bounds: bounds, selection: selection)
                if let selection {
                    selectionBorder(at: selection)
                    selectionHandles(at: selection)
                    dimensionsLabel(at: selection)
                }
                instructionPill(in: bounds)
            }
            .frame(width: bounds.width, height: bounds.height)
        }
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
            .stroke(Color.vfBrandBlue, lineWidth: 1.5)
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
                .overlay(Rectangle().strokeBorder(Color.vfBrandBlue, lineWidth: 1))
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

    private static let pillWidth: CGFloat = 392
    private static let pillHeight: CGFloat = 50
    private static let pillTopGap: CGFloat = 24

    private func instructionPill(in bounds: CGSize) -> some View {
        HStack(spacing: VFSpacing.sm) {
            Circle()
                .stroke(Color.vfTextSecondary, lineWidth: 1.2)
                .frame(width: 8, height: 8)
            Text("Drag to select an area to narrate")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()
            Text("\u{00B7}")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextTertiary)
            KeyCapView(label: "esc")
            Text("cancel")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
        }
        .frame(width: Self.pillWidth, height: Self.pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 0.5))
        .position(
            x: bounds.width / 2,
            y: topInset + Self.pillTopGap + Self.pillHeight / 2
        )
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
                .foregroundStyle(Color.vfBrandBlue)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.vfBrandBlue)
                .frame(height: 34)
                .overlay(
                    Text("Sign in")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
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

@MainActor
private func makePreviewState() -> AreaSelectorState {
    let s = AreaSelectorState()
    s.beginDrag(at: CGPoint(x: 80, y: 130))
    s.updateDrag(to: CGPoint(x: 560, y: 370))
    return s
}
