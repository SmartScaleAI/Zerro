//
//  IdleStateView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct IdleStateView: View {
    private struct RecentPrompt: Identifiable {
        let id = UUID()
        let accentColor: Color
        let title: String
        let timestamp: String
    }

    private let recentPrompts: [RecentPrompt] = [
        RecentPrompt(accentColor: .vfBrandBlue, title: "Polish the Pulse logi\u{2026}", timestamp: "10:24 AM"),
        RecentPrompt(accentColor: Color(red: 0.93, green: 0.36, blue: 0.78), title: "Debug the React hyd\u{2026}", timestamp: "Yesterday"),
        RecentPrompt(accentColor: .vfWarningAmber, title: "Summarize Tuesday\u{2019}\u{2026}", timestamp: "Mon")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            header
            primaryCard
            sectionLabel("RECENT PROMPTS")
            VStack(spacing: VFSpacing.sm) {
                ForEach(recentPrompts) { prompt in
                    recentPromptRow(prompt)
                }
            }
            Divider().background(Color.vfHairline)
            VStack(spacing: VFSpacing.sm) {
                footerRow(icon: "rectangle.split.2x1", label: "Open library", keys: ["\u{2318}", "L"])
                footerRow(icon: "gearshape", label: "Preferences\u{2026}", keys: ["\u{2318}", ","])
            }
        }
        .padding(VFSpacing.lg)
    }

    private var header: some View {
        HStack(spacing: VFSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.vfBrandBlue)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("VisualFlow AI")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.vfSuccessGreen)
                        .frame(width: 6, height: 6)
                    Text("Ready \u{00B7} 24 credits left")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfTextSecondary)
                }
            }
            Spacer()
        }
    }

    private var primaryCard: some View {
        Button {
            print("Tapped: Start Recording")
        } label: {
            HStack(spacing: VFSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.15))
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Up to 3:00 \u{00B7} auto-stops")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                HStack(spacing: 3) {
                    KeyCapView(label: "\u{2318}")
                    KeyCapView(label: "\u{21E7}")
                    KeyCapView(label: "R")
                }
            }
            .padding(VFSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.lg)
                    .fill(Color.vfBrandBlue)
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.vfTextTertiary)
            .padding(.top, VFSpacing.xs)
    }

    private func recentPromptRow(_ prompt: RecentPrompt) -> some View {
        Button {
            print("Tapped: \(prompt.title)")
        } label: {
            HStack(spacing: VFSpacing.md) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(prompt.accentColor)
                    .frame(width: 8, height: 8)
                Text(prompt.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                Spacer()
                Text(prompt.timestamp)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footerRow(icon: String, label: String, keys: [String]) -> some View {
        Button {
            print("Tapped: \(label)")
        } label: {
            HStack(spacing: VFSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(keys, id: \.self) { key in
                        KeyCapView(label: key)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    IdleStateView()
        .frame(width: 280)
        .background(Color.vfPanelBackground)
}
