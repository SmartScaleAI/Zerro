//
//  RecordingStateView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct RecordingStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            header
            waveformCard
            stopButton
            cancelRow
            Divider().background(Color.vfHairline)
            sectionLabel("LIVE")
            micInputRow
        }
        .padding(VFSpacing.lg)
    }

    private var header: some View {
        HStack(spacing: VFSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.vfRecordingRed.opacity(0.2))
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.vfRecordingRed)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording in progress")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfRecordingRed)
                Text("1:29 / 3:00 \u{00B7} 17 frames")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
            }
            Spacer()
        }
    }

    private var waveformCard: some View {
        HStack(spacing: VFSpacing.md) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            WaveformView(bars: WaveformView.sampleBarsLong, color: .vfRecordingRed)
                .frame(maxWidth: .infinity)
            Text("\u{2013}9 dB")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.vfTextSecondary)
        }
        .padding(VFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md)
                .fill(Color.vfCardBackground)
        )
    }

    private var stopButton: some View {
        Button {
            print("Tapped: Stop & process")
        } label: {
            HStack(spacing: VFSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.18))
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop & process")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Generate prompt now")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                HStack(spacing: 3) {
                    KeyCapView(label: "\u{2318}")
                    KeyCapView(label: "\u{21B5}")
                }
            }
            .padding(VFSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.lg)
                    .fill(Color.vfRecordingRed)
            )
        }
        .buttonStyle(.plain)
    }

    private var cancelRow: some View {
        Button {
            print("Tapped: Cancel \u{2014} discard recording")
        } label: {
            HStack(spacing: VFSpacing.md) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.vfRecordingRed)
                    .frame(width: 16)
                Text("Cancel \u{2014} discard recording")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfRecordingRed)
                Spacer()
                KeyCapView(label: "esc")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.vfTextTertiary)
    }

    private var micInputRow: some View {
        HStack {
            Text("Mic input")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Spacer()
            Text("MacBook Pro Mic")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextPrimary)
        }
    }
}

#Preview {
    RecordingStateView()
        .frame(width: 280)
        .background(Color.vfPanelBackground)
}
