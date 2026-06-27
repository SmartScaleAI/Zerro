//
//  StagingOverlayMarker.swift
//  Zerro
//
//  The amber "this is the Staging build" marker for full-screen capture
//  overlays — the area selector and the recording-focus dim. Renders a 2.5pt
//  amber border tracing the overlay's edge plus a small "STAGING" pill in the
//  top-trailing corner, so a Staging capture surface can never be mistaken for
//  production at the moment of capture.
//
//  Both elements sit at the periphery (screen edge + corner) and are
//  click-through (`allowsHitTesting(false)`), so they never obstruct the
//  capture area or intercept clicks. Neither overlay window is itself captured:
//  the area selector is torn down before capture and the recording-focus dim is
//  excluded from the capture filter, so these markers are purely an on-screen
//  "you're recording against staging" reminder and never bleed into output.
//
//  Compiled ONLY in the Staging configuration. The whole file is behind
//  `#if STAGING`, so it does not exist in the Production binary.
//

#if STAGING

import SwiftUI

// MARK: - StagingBadge

/// The amber "STAGING" pill. Reused by the capture overlays and the menu-bar
/// dropdown header so every surface shows the same badge.
struct StagingBadge: View {
    /// Text point size. Defaults to the overlay size; the menu header passes a
    /// smaller value.
    var fontSize: CGFloat = 11

    var body: some View {
        Text("STAGING")
            .font(.system(size: fontSize, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(Color.vfOnBrand)
            .padding(.horizontal, fontSize * 0.8)
            .padding(.vertical, fontSize * 0.34)
            .background(Capsule().fill(Color.vfStagingAccent))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.35), radius: fontSize * 0.35, y: 1)
    }
}

// MARK: - StagingOverlayMarker

private struct StagingOverlayMarker: ViewModifier {
    /// Distance from the top of the overlay bounds down to the visible
    /// (menu-bar-excluded) area, so the corner badge clears the menu bar. The
    /// area selector threads its own `topInset`; other overlays pass 0.
    var topInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .topTrailing) {
                // 2.5pt amber border tracing the full overlay edge. `strokeBorder`
                // draws inside the bounds so the whole stroke stays on screen.
                Rectangle()
                    .strokeBorder(Color.vfStagingAccent, lineWidth: 2.5)

                StagingBadge()
                    .padding(.top, topInset + 14)
                    .padding(.trailing, 18)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Overlays the amber staging border + "STAGING" badge. No-op in any build
    /// other than Staging (the modifier only exists under `#if STAGING`).
    func stagingOverlayMarker(topInset: CGFloat = 0) -> some View {
        modifier(StagingOverlayMarker(topInset: topInset))
    }
}

#endif
