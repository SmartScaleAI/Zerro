//
//  MenuBarIconView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  Two static glyph variants for the menu-bar status item.
//  Phase 2.5 is visual-only — both variants render in `#Preview` for
//  the visual spec. The runtime icon swap (driven by recording state)
//  wires in during Phase 2.75 alongside the rest of the state-machine
//  reconnection.
//
//  Template-rendering note (read before Phase 2.75 wires this in)
//  -------------------------------------------------------------
//  In `#Preview`, both `.foregroundStyle(.primary)` and
//  `.foregroundStyle(.vfRecordingRed)` are honored — the red shows
//  as red. In production, `MenuBarExtra` treats SF Symbol icons as
//  template images by default; macOS strips the foreground color
//  and renders the glyph in the system's menu-bar text color
//  (white on dark menu bars, dark on light, wallpaper-adaptive in
//  Sonoma+). For the idle variant this is desired. For the recording
//  variant, the red tint will silently disappear unless we opt out
//  of template rendering — either via `.renderingMode(.original)`
//  on the underlying `Image`, by providing a custom `Image(nsImage:)`
//  with `isTemplate = false`, or by wiring through `MenuBarExtra`'s
//  asset-driven API. Phase 2.75 needs to handle this transition; the
//  preview here only captures the visual target, not the production
//  rendering path.
//

import SwiftUI

struct MenuBarIconView: View {
    let isRecording: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRecording {
                // .renderingMode(.original) opts the recording icon out
                // of menu-bar template rendering so .vfRecordingRed
                // actually shows. The idle variant below keeps default
                // (template) rendering so it adapts to light/dark menu
                // bars per system convention.
                Image(systemName: "waveform")
                    .renderingMode(.original)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfRecordingRed)

                PulsingDot(color: .vfRecordingRed, size: 5)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                    .offset(x: 3, y: 2)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
        }
    }
}

// MARK: - Preview
//
// Both variants side by side against a dark menu-bar-strip backdrop.
// The strip's height (~24pt) and dark fill approximate how the icons
// will actually appear in the live macOS menu bar.

private struct MenuBarStripBackdrop<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: VFSpacing.xxl) {
            content()
        }
        .padding(.horizontal, VFSpacing.lg)
        .frame(height: 24)
        .background(Color(red: 0.10, green: 0.10, blue: 0.12))
    }
}

#Preview("Menu Bar Icon \u{00B7} Both states") {
    VStack(spacing: VFSpacing.xxl) {
        VStack(spacing: VFSpacing.sm) {
            MenuBarStripBackdrop {
                MenuBarIconView(isRecording: false)
            }
            Text("IDLE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.vfTextTertiary)
        }

        VStack(spacing: VFSpacing.sm) {
            MenuBarStripBackdrop {
                MenuBarIconView(isRecording: true)
            }
            Text("RECORDING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.vfTextTertiary)
        }
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}
