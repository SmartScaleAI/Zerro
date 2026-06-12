//
//  ArtifactCardView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/12/26.
//
//  Phase 5 of the typed-artifact refactor — the artifact card in the
//  expanded result pill, per the approved design:
//
//    • header: green check + the model's dynamic title (no type badge),
//      Hide chevron on the right (collapses the whole pill to compact);
//    • body: auto-expanded, monospace for `snippet`
//      (ArtifactType.rendersMonospace), markdown otherwise;
//    • a collapsed Attached Context drawer row (AttachedContextRow),
//      absent when the recording captured nothing;
//    • footer: ONE primary filled copy button, bottom-right, labeled per
//      `ArtifactType.buttonLabel` — the §2 per-type table's single
//      affordance. The clipboard payload itself lives upstream in
//      `AppState.resultCopyPayload`; this view only fires `onCopy`.
//
//  Pure renderer: everything it shows arrives via `ResultPresentation`
//  pieces, every effect leaves via a closure.
//

import SwiftUI

struct ArtifactCardView: View {
    let artifact: Artifact
    /// Drawer payload; nil hides the row entirely.
    let context: AttachedContext?
    /// Writes the per-type payload to the clipboard (wired to
    /// `AppState.resultCopyPayload` via the pill's onCopy).
    let onCopy: () -> Void
    /// The header's Hide chevron — collapses the expanded pill back to the
    /// compact capsule (the same `onToggleExpand` the old header used).
    let onCollapse: () -> Void

    /// Transient "Copied" confirmation — same pattern and timing as the
    /// compact header's copy button: flips on tap, reverts after 1.6s, a
    /// re-tap restarts the window.
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private static let copyFeedbackDuration: Duration = .seconds(1.6)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.vfHairline)
            bodyScroll
            if let context {
                Divider().overlay(Color.vfHairline)
                AttachedContextRow(
                    context: context,
                    includedInCopy: artifact.type.includesContextInCopy
                )
            }
            Divider().overlay(Color.vfHairline)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md + 2, style: .continuous)
                .fill(Color.black.opacity(0.4))
        )
        .clipShape(RoundedRectangle(cornerRadius: VFRadius.md + 2, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: VFSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.vfSuccessGreen)

            // The model-written title (§2 caps it at 80 chars; an over-long
            // one that slipped past the warning truncates here).
            Text(artifact.title.isEmpty ? "Untitled" : artifact.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: VFSpacing.xxl)

            collapseToggle
        }
        .padding(.horizontal, VFSpacing.xl)
        .padding(.vertical, VFSpacing.md)
    }

    private var collapseToggle: some View {
        Button(action: onCollapse) {
            HStack(spacing: 4) {
                Text("Hide")
                    .font(.system(size: 12))
                    .fixedSize()
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.vfTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: Body

    private var bodyScroll: some View {
        HeightCappedScroll(maxHeight: 320) {
            Group {
                if artifact.type.rendersMonospace {
                    // snippet — exact text, code voice. (agent_prompt is
                    // "mono-leaning" via HighlightedMarkdownView's own
                    // monospaced base font, not this branch.)
                    Text(artifact.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.vfTextPrimary)
                        .textSelection(.enabled)
                } else {
                    HighlightedMarkdownView(markdown: artifact.body)
                }
            }
            .padding(.horizontal, VFSpacing.xl)
            .padding(.vertical, VFSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: VFSpacing.md)
            copyButton
        }
        .padding(.horizontal, VFSpacing.xl)
        .padding(.vertical, VFSpacing.md)
    }

    private var copyButton: some View {
        Button(action: handleCopy) {
            HStack(spacing: 5) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(didCopy ? "Copied" : artifact.type.buttonLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(didCopy ? Color.white : Color.vfOnBrand)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(didCopy ? Color.vfSuccessGreen : Color.vfBrandAccent, in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(.easeInOut(duration: 0.15), value: didCopy)
    }

    private func handleCopy() {
        onCopy()
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: Self.copyFeedbackDuration)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
