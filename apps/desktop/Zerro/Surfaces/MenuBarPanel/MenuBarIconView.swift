//
//  MenuBarIconView.swift
//  Zerro
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
import AppKit

struct MenuBarIconView: View {
    let isRecording: Bool

    // `MenuBarExtra` ignores SwiftUI `.frame` when sizing the status item;
    // it uses the image's intrinsic size. So we render the glyph into a
    // fixed-size NSImage — NSStatusItem honors NSImage.size exactly.
    private static let iconSize = NSSize(width: 18, height: 18)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Idle: template so macOS adapts it to the bar color
            // (light/dark/wallpaper). Recording: original, since the red
            // is already baked into the pixels. Staging: always original,
            // since the amber tint is baked in (see `glyph`).
            Image(nsImage: Self.glyph(recording: isRecording))
                .renderingMode(Self.renderingMode(recording: isRecording))

            if isRecording {
                PulsingDot(color: .vfRecordingRed, size: 5)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                    .offset(x: 3, y: 2)
            }

            // Staging idle: a small static amber dot reinforces the amber glyph
            // so the build is identifiable at a glance even when not recording.
            // (While recording, the red dot above takes the corner.) Absent from
            // the production binary.
            #if STAGING
            if !isRecording {
                Circle()
                    .fill(Color.vfStagingAccent)
                    .frame(width: 5, height: 5)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                    .offset(x: 3, y: 2)
            }
            #endif
        }
    }

    private static func renderingMode(recording: Bool) -> Image.TemplateRenderingMode {
        #if STAGING
        return .original
        #else
        return recording ? .original : .template
        #endif
    }

    private static func glyph(recording: Bool) -> NSImage {
        guard let base = NSImage(named: "MenuBarLogo") else { return NSImage() }
        let image = NSImage(size: iconSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: iconSize)
        base.draw(in: rect)
        #if STAGING
        // Staging: always tint the glyph amber and bake it in (non-template) so
        // the menu-bar icon is unmistakably the staging build at a glance —
        // whether or not a recording is in progress.
        NSColor(Color.vfStagingAccent).set()
        rect.fill(using: .sourceAtop)
        #else
        if recording {
            // Tint the drawn glyph red and bake it into the pixels so it
            // survives the menu bar (template rendering would strip color).
            NSColor(Color.vfRecordingRed).set()
            rect.fill(using: .sourceAtop)
        }
        #endif
        image.unlockFocus()
        #if STAGING
        image.isTemplate = false
        #else
        image.isTemplate = !recording
        #endif
        return image
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
