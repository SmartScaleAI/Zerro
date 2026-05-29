//
//  MenuBarIconProposals.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  DEBUG-only proposal surface for the Checkpoint 5 "setup incomplete"
//  menu-bar indicator. Both options compose with the existing Phase 2.5
//  recording variant — when isRecording is true, the indicator yields
//  to the red pulsing dot.
//
//  Option A: small amber badge dot
//    Adds a static amber dot to the bottom-right of the idle waveform,
//    mirroring the PulsingDot position of the recording variant.
//    Familiar visual language with the existing icon family.
//
//  Option B: dimmed icon
//    No badge; renders the idle waveform at reduced opacity
//    (~0.45) to signal "not ready yet". Less busy, more subtle, but
//    risks being mistaken for a system-disabled menu item.
//
//  Open this file in Xcode and run the #Preview to compare side-by-side.
//

#if DEBUG

import SwiftUI

// MARK: - Option A: amber dot badge

struct MenuBarIconOptionA: View {
    let isRecording: Bool
    let setupComplete: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRecording {
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

                if !setupComplete {
                    // .renderingMode(.original) opts the badge out of
                    // menu-bar template rendering so the amber color
                    // actually shows. The dot is static (no pulse) to
                    // distinguish from the active-recording variant.
                    Circle()
                        .fill(Color.vfWarningAmber)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                        .offset(x: 3, y: 2)
                }
            }
        }
    }
}

// MARK: - Option B: dimmed icon

struct MenuBarIconOptionB: View {
    let isRecording: Bool
    let setupComplete: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRecording {
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
                    .opacity(setupComplete ? 1.0 : 0.45)
            }
        }
    }
}

// MARK: - Preview backdrop

private struct StripBackdrop<Content: View>: View {
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

private struct ProposalColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
            content()
                .padding(.leading, 4)
        }
    }
}

#Preview("Menu Bar Indicator \u{00B7} Proposals") {
    HStack(alignment: .top, spacing: VFSpacing.xxl) {
        // OPTION A
        ProposalColumn(title: "Option A \u{00B7} amber dot") {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                stateRow("Idle, setup complete") {
                    MenuBarIconOptionA(isRecording: false, setupComplete: true)
                }
                stateRow("Idle, setup INCOMPLETE") {
                    MenuBarIconOptionA(isRecording: false, setupComplete: false)
                }
                stateRow("Recording") {
                    MenuBarIconOptionA(isRecording: true, setupComplete: true)
                }
            }
        }

        // OPTION B
        ProposalColumn(title: "Option B \u{00B7} dimmed icon") {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                stateRow("Idle, setup complete") {
                    MenuBarIconOptionB(isRecording: false, setupComplete: true)
                }
                stateRow("Idle, setup INCOMPLETE") {
                    MenuBarIconOptionB(isRecording: false, setupComplete: false)
                }
                stateRow("Recording") {
                    MenuBarIconOptionB(isRecording: true, setupComplete: true)
                }
            }
        }
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}

private struct StateRow<Icon: View>: View {
    let label: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            StripBackdrop(content: icon)
                .frame(width: 60)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.vfTextTertiary)
        }
    }
}

private func stateRow<Icon: View>(_ label: String, @ViewBuilder icon: @escaping () -> Icon) -> StateRow<Icon> {
    StateRow(label: label, icon: icon)
}

#endif
