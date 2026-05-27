//
//  ProgressStepRow.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct ProgressStepRow: View {
    enum Status {
        case done       // green filled circle with white checkmark
        case running    // blue spinner
        case pending    // dimmed empty circle
    }

    let label: String
    let status: Status
    var showProgressBar: Bool = false
    var trailingBadge: String? = nil

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            statusIcon
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfTextPrimary)
            if showProgressBar {
                progressBar
            } else {
                Spacer()
            }
            if let badge = trailingBadge {
                Text(badge)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .done:
            ZStack {
                Circle().fill(Color.vfSuccessGreen.opacity(0.2))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.vfSuccessGreen)
            }
            .frame(width: 22, height: 22)
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(Color.vfBrandBlue)
                .frame(width: 22, height: 22)
        case .pending:
            Circle()
                .strokeBorder(Color.vfTextTertiary, lineWidth: 1)
                .frame(width: 22, height: 22)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule().fill(Color.vfSuccessGreen).frame(width: geo.size.width)
            }
        }
        .frame(height: 3)
    }
}

#Preview {
    VStack(spacing: 12) {
        ProgressStepRow(label: "Listened to your narration", status: .done, showProgressBar: true)
        ProgressStepRow(label: "Looked at your screen", status: .done, showProgressBar: true)
        ProgressStepRow(label: "Writing your prompt\u{2026}", status: .running, trailingBadge: "running")
        ProgressStepRow(label: "Pending step", status: .pending)
    }
    .padding()
    .background(Color.vfPanelBackground)
    .frame(width: 400)
}
