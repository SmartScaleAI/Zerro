//
//  RecordingPillView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct RecordingPillView: View {
    enum Variant: String, CaseIterable, Identifiable {
        case recording = "Recording"
        case wrappingUp = "Wrapping up (>2:30)"
        case autoStop = "Auto-stop \u{2192} Processing"
        var id: String { rawValue }
    }

    @State private var variant: Variant = .recording

    var body: some View {
        VStack(spacing: VFSpacing.xl) {
            pillContent
                .padding(.horizontal, VFSpacing.lg)
                .padding(.vertical, VFSpacing.md)
                .background(Color.vfPillBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)

            Picker("Variant", selection: $variant) {
                ForEach(Variant.allCases) { v in Text(v.rawValue).tag(v) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 500)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.vfPanelBackground)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch variant {
        case .recording:  recordingVariant
        case .wrappingUp: wrappingUpVariant
        case .autoStop:   autoStopVariant
        }
    }

    // MARK: - Variant 1: Recording

    private var recordingVariant: some View {
        HStack(spacing: VFSpacing.md) {
            Circle()
                .fill(Color.vfRecordingRed)
                .frame(width: 8, height: 8)

            HStack(spacing: 0) {
                Text("2:06")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.vfTextPrimary)
                    .monospacedDigit()
                Text(" / 3:00")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.vfTextSecondary)
                    .monospacedDigit()
            }

            WaveformView(bars: Array(WaveformView.sampleBarsLong.prefix(25)), color: .vfTextPrimary)

            HStack(spacing: 4) {
                Image(systemName: "film.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                Text("25")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
            }

            pauseButton

            stopPillButton

            cancelInlineButton
        }
    }

    // MARK: - Variant 2: Wrapping up

    private var wrappingUpVariant: some View {
        HStack(spacing: VFSpacing.md) {
            Circle()
                .fill(Color.vfWarningAmber)
                .frame(width: 8, height: 8)

            HStack(spacing: 0) {
                Text("2:56")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.vfWarningAmber)
                    .monospacedDigit()
                Text(" / 3:00")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.vfTextSecondary)
                    .monospacedDigit()
            }

            WaveformView(bars: WaveformView.sampleBarsShort, color: .vfWarningAmber)

            Text("Wrapping up soon")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vfWarningAmber)

            HStack(spacing: 4) {
                Image(systemName: "film.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                Text("35")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
            }

            pauseButton

            stopPillButton

            cancelInlineButton
        }
    }

    // MARK: - Variant 3: Auto-stop → Processing

    private var autoStopVariant: some View {
        HStack(spacing: VFSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.vfSuccessGreen)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recorded 3:00 \u{00B7} at the cap")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Handing off to processing\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextSecondary)
                }
            }

            Spacer()

            Image(systemName: "arrow.right")
                .font(.system(size: 14))
                .foregroundStyle(Color.vfTextSecondary)
        }
        .frame(minWidth: 320)
    }

    // MARK: - Shared sub-elements

    private var pauseButton: some View {
        Button {
            print("Tapped: Pause")
        } label: {
            Image(systemName: "pause.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var stopPillButton: some View {
        Button {
            print("Tapped: Stop")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.vfRecordingRed)
            .clipShape(Capsule())
            .shadow(color: .vfRecordingRed.opacity(0.5), radius: 12)
        }
        .buttonStyle(.plain)
    }

    private var cancelInlineButton: some View {
        Button {
            print("Tapped: Cancel")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RecordingPillView()
        .frame(width: 900, height: 400)
}
