//
//  AreaSelectorView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  Static SwiftUI surface for the drag-to-select crosshair overlay
//  that runs before recording begins. Phase 2.5 is visual-only — no
//  mouse-drag interaction, no AppKit / NSEvent wiring, no actual
//  screen capture. A real implementation will replace the hardcoded
//  selection rect with state driven by NSEvent.localMonitor in a
//  later phase.
//
//  Visual-state note: the 8-handle layout (4 corners + 4 edge midpoints)
//  rendered here represents the *settled* selection — the moment after
//  the user releases the mouse, when the rectangle is ready to confirm
//  or resize. The *during-drag* state, per native macOS convention,
//  shows only the 4 corner handles. Phase 2.5 captures the settled
//  state; the drag-in-progress variant comes when interaction wires in.
//

import SwiftUI

struct AreaSelectorView: View {
    /// Fixed selection rectangle for the static preview. The "480 × 240"
    /// label in the mockup is derived from these dimensions.
    private let selectionSize = CGSize(width: 480, height: 240)

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.size
            let selection = centeredSelection(in: bounds)

            ZStack(alignment: .topLeading) {
                dimCutout(bounds: bounds, selection: selection)
                selectionBorder(at: selection)
                selectionHandles(at: selection)
                dimensionsLabel(at: selection)
                instructionPill(in: bounds)
            }
            .frame(width: bounds.width, height: bounds.height)
        }
    }

    private func centeredSelection(in bounds: CGSize) -> CGRect {
        CGRect(
            x: (bounds.width - selectionSize.width) / 2,
            y: (bounds.height - selectionSize.height) / 2 + 20,
            width: selectionSize.width,
            height: selectionSize.height
        )
    }

    // MARK: - Dim cutout
    //
    // Single `Path` with the outer bounds and the inner selection,
    // filled with `.eoFill` (even-odd) so the area inside the
    // selection stays clear of the dim color. One path is cheaper
    // than four positioned rectangles and avoids subpixel seams.

    private func dimCutout(bounds: CGSize, selection: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: bounds))
            path.addRect(selection)
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    // MARK: - Selection border

    private func selectionBorder(at rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.vfBrandBlue, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    // MARK: - 8 handles
    //
    // 4 corners + 4 edge midpoints, per the mockup's settled state.

    private func selectionHandles(at rect: CGRect) -> some View {
        let positions: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY), // top-left
            CGPoint(x: rect.midX, y: rect.minY), // top-mid
            CGPoint(x: rect.maxX, y: rect.minY), // top-right
            CGPoint(x: rect.maxX, y: rect.midY), // right-mid
            CGPoint(x: rect.maxX, y: rect.maxY), // bottom-right
            CGPoint(x: rect.midX, y: rect.maxY), // bottom-mid
            CGPoint(x: rect.minX, y: rect.maxY), // bottom-left
            CGPoint(x: rect.minX, y: rect.midY)  // left-mid
        ]
        return ForEach(positions.indices, id: \.self) { i in
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().strokeBorder(Color.vfBrandBlue, lineWidth: 1))
                .frame(width: 8, height: 8)
                .position(positions[i])
        }
    }

    // MARK: - Dimensions label

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
    // KeyCapView for the `esc` token — this is the surface where
    // keyboard cues deserve visual weight (the user is being taught
    // how to dismiss).

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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 0.5))
        .position(x: bounds.width / 2, y: 40)
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

#Preview("Area Selector") {
    ZStack {
        PulseLoginBackdrop()
        AreaSelectorView()
    }
    .frame(width: 640, height: 480)
}
