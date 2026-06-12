//
//  AttachedContextRow.swift
//  Zerro
//
//  Created by Colin Breeding on 6/12/26.
//
//  Phase 5 of the typed-artifact refactor — the artifact card's Attached
//  Context drawer. Collapsed, it is a single quiet row: paperclip, a
//  summary of what the recording captured ("screen text, 4 clicks"), and a
//  tag answering the one question that matters — does the Copy button
//  include this? (`INCLUDED IN COPY` for agent_prompt, `FOR REFERENCE`
//  for every other type, per `ArtifactType.includesContextInCopy`.)
//  Expanding reveals the assembled §2 context block itself. The row is
//  never rendered when there's nothing attached — the card omits it
//  entirely (`AttachedContext` is nil).
//

import SwiftUI

struct AttachedContextRow: View {
    let context: AttachedContext
    /// Drives the tag copy. Threaded from the owning artifact's
    /// `type.includesContextInCopy` so this view doesn't need the artifact.
    let includedInCopy: Bool

    /// Drawer state, local by design: it resets with the view (each new
    /// result starts collapsed) and nothing outside the card cares.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow
            if isExpanded {
                blockView
            }
        }
    }

    private var toggleRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)

                Text("Attached context: \(context.summary)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                copyTag

                Spacer(minLength: VFSpacing.md)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.vfTextSecondary)
            }
            .padding(.horizontal, VFSpacing.xl)
            .padding(.vertical, VFSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Small caps-style chip in the eyebrow voice (10pt-and-under semibold
    /// with tracking, like the old "STRUCTURED PROMPT" eyebrow). Green when
    /// the context ships with the copy; neutral when it's reference-only.
    private var copyTag: some View {
        Text(includedInCopy ? "INCLUDED IN COPY" : "FOR REFERENCE")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(includedInCopy ? Color.vfSuccessGreen : Color.vfTextTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((includedInCopy ? Color.vfSuccessGreen : Color.white).opacity(0.12))
            )
            .fixedSize()
    }

    private var blockView: some View {
        HeightCappedScroll(maxHeight: 180) {
            Text(context.block)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.vfTextSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VFSpacing.xl)
                .padding(.bottom, VFSpacing.md)
        }
    }
}

// MARK: - HeightCappedScroll
//
// A ScrollView that hugs its content's height up to `maxHeight`, then
// scrolls. Plain `ScrollView` can't do this: its ideal height is its
// content's full intrinsic height, so a fixed `.frame(height:)` either
// over-allocates short content (a one-line snippet floating in 300pt of
// card) or requires knowing the content height up front. Measuring via
// `onGeometryChange` and clamping gives short bodies a snug card and long
// ones an internal scroll. The pill window re-fits itself when the
// measured height lands (see PillWindowController's content-size
// observation).

struct HeightCappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    /// Measured content height; starts at 0 (the view renders effectively
    /// collapsed for the first layout pass, then snaps to the measurement
    /// before draw).
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}
