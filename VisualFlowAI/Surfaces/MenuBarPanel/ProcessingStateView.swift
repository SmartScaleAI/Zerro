//
//  ProcessingStateView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct ProcessingStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            header
            VStack(spacing: VFSpacing.sm) {
                ProgressStepRow(label: "Listening to your narration\u{2026}", status: .done)
                ProgressStepRow(label: "Looking at your screen\u{2026}", status: .done)
                ProgressStepRow(label: "Writing your prompt\u{2026}", status: .running, trailingBadge: "running")
            }
            Divider().background(Color.vfHairline)
            sectionLabel("WHILE YOU WAIT")
            VStack(spacing: VFSpacing.sm) {
                openLibraryRow
                cancelProcessingRow
            }
        }
        .padding(VFSpacing.lg)
    }

    private var header: some View {
        HStack(spacing: VFSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.vfBrandBlue.opacity(0.2))
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.vfBrandBlue)
            }
            .frame(width: 32, height: 32)

            Text("Building your prompt")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.vfBrandBlue)
            Spacer()
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.vfTextTertiary)
    }

    private var openLibraryRow: some View {
        Button {
            print("Tapped: Open library")
        } label: {
            HStack(spacing: VFSpacing.md) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .frame(width: 16)
                Text("Open library")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer()
                HStack(spacing: 3) {
                    KeyCapView(label: "\u{2318}")
                    KeyCapView(label: "L")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cancelProcessingRow: some View {
        Button {
            print("Tapped: Cancel processing")
        } label: {
            HStack(spacing: VFSpacing.md) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.vfRecordingRed)
                    .frame(width: 16)
                Text("Cancel processing")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfRecordingRed)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ProcessingStateView()
        .frame(width: 280)
        .background(Color.vfPanelBackground)
}
