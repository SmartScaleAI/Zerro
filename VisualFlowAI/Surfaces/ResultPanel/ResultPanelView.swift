//
//  ResultPanelView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct ResultPanelView: View {
    private let sampleMarkdown = """
    ## Context
    A 1:18 narrated walkthrough of the Pulse analytics login screen,
    captured while reviewing visual hierarchy and information density
    before handoff to engineering.

    ## Current State
    - Two-column form: email + password stacked on the left
    - Brand-blue "Sign in" primary CTA
    - Three social auth buttons below (Google, Microsoft, SSO)
    - Password helper text wraps to two lines at this viewport width
    - "Forgot password?" link sits adjacent to the password field

    ## Request
    1. Move "Forgot password?" into the Sign In button cluster
    2. Consolidate social auth buttons into a single dropdown menu
    3. Add inline validation for email field on blur
    """

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            header
            VStack(spacing: VFSpacing.md) {
                ProgressStepRow(label: "Listened to your narration", status: .done, showProgressBar: true)
                ProgressStepRow(label: "Looked at your screen", status: .done, showProgressBar: true)
                ProgressStepRow(label: "Wrote your prompt", status: .done, showProgressBar: true)
            }
            Divider().background(Color.vfHairline)
            promptReadyHeading
            structuredPromptCard
            copyButton
            sendToRow
        }
        .padding(VFSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.lg)
                .fill(Color.vfCardBackground)
        )
        .frame(width: 520)
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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.vfSuccessGreen)
                    Text("Prompt ready")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfTextSecondary)
                }
            }

            Spacer()

            Button {
                print("Tapped: Replay")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                    Text("Replay")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color.vfTextSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var promptReadyHeading: some View {
        HStack(spacing: VFSpacing.md) {
            ZStack {
                Circle().fill(Color.vfSuccessGreen.opacity(0.2))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.vfSuccessGreen)
            }
            .frame(width: 22, height: 22)

            Text("Prompt ready")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
        }
    }

    private var structuredPromptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfTextTertiary)
                Text("STRUCTURED PROMPT \u{00B7} MARKDOWN")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.vfTextTertiary)
            }
            .padding(VFSpacing.md)

            Divider().background(Color.vfHairline)

            ScrollView {
                HighlightedMarkdownView(markdown: sampleMarkdown)
                    .padding(VFSpacing.md)
            }
            .frame(maxHeight: 280)
        }
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md)
                .fill(Color.black.opacity(0.4))
        )
    }

    private var copyButton: some View {
        Button {
            print("Tapped: Copy to clipboard")
        } label: {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Copy to clipboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.lg)
                    .fill(Color.vfBrandBlue)
            )
        }
        .buttonStyle(.plain)
    }

    private var sendToRow: some View {
        HStack {
            Text("Or send directly to:")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Spacer()
            HStack(spacing: VFSpacing.sm) {
                sendPill(icon: "paperplane", label: "Cursor")
                sendPill(icon: "paperplane", label: "Windsurf")
                sendPill(icon: "paperplane", label: "v0")
                sendPill(icon: "doc.text", label: "Save snippet")
            }
        }
    }

    private func sendPill(icon: String, label: String) -> some View {
        Button {
            print("Tapped: \(label)")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.vfTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ResultPanelView()
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.vfPanelBackground)
}
