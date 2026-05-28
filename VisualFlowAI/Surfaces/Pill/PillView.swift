//
//  PillView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  Unified pill — one view that morphs through five states in place.
//  The outer chrome (rounded shape, fill, hairline, shadow) is shared;
//  only the inner content swaps based on `PillState`. Height is content-
//  driven so the compact ↔ expanded morph in Phase 2.75 can animate
//  cleanly without a structural rewrite.
//

import SwiftUI

// MARK: - PillState

enum PillState: Equatable {
    case recording(elapsed: String, totalDisplay: String)
    case wrappingUp(elapsed: String, totalDisplay: String)
    case processing(stepLabel: String)
    case resultCompact
    case resultExpanded
    case error(message: String)
}

// MARK: - PillView

struct PillView: View {
    let state: PillState

    /// Action closures default to no-ops so `#Preview` blocks can keep
    /// passing literal `PillState` values without ceremony. Production
    /// call sites bind these to `AppState` transitions.
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onCopy: () -> Void = {}
    var onToggleExpand: () -> Void = {}
    var onSendChip: (String) -> Void = { _ in }
    var onDismissError: () -> Void = {}

    /// The generated structured prompt, displayed in the .resultExpanded
    /// body. Threaded from AppState.generatedPrompt via PillWindowController
    /// so the pure-renderer PillView doesn't need to know about AppState.
    /// `nil` falls back to a placeholder so previews and the brief
    /// transition window (state flips to .done before the markdown view
    /// can re-render) don't render an empty card.
    var generatedPrompt: String? = nil

    var body: some View {
        content
            .frame(width: lockedCapsuleWidth, height: lockedCapsuleHeight)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.vfPillBackground)
            )
            .overlay(
                // `.stroke` (not `.strokeBorder`) so the hairline sits ON
                // the rounded edge rather than inset 0.25pt inside it —
                // closes the antialiasing gap at the corners that was
                // showing through as transparent notches.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.vfHairline, lineWidth: 0.5)
            )
            // No chrome-level `.clipShape` here: clipping the chrome
            // caused `.shadow` below to render its dark falloff into
            // the four corner regions outside the rounded silhouette
            // but inside the bounding rect, producing square notches.
            // The chrome's rounded background already defines the
            // visible shape; the only state that needed clipping was
            // `.resultExpanded` (body-card fill), which now clips
            // itself inside `ResultPillContent`.
            .shadow(color: .black.opacity(0), radius: 20, y: 8)
    }

    /// All four capsule states (`.recording`, `.wrappingUp`, `.processing`,
    /// `.resultCompact`) share one fixed width and height so size never
    /// changes between them — the only morph allowed inside the lock is
    /// content cross-fades and the chrome's corner radius. Sized to
    /// `.recording`'s natural dimensions (the widest+tallest capsule):
    /// dot + timer + waveform + Cancel + Stop. Narrower states absorb
    /// the difference via internal Spacers as breathing room.
    /// `.resultExpanded` is the one capsule-to-non-capsule morph allowed
    /// and keeps its content-driven sizing.
    private var lockedCapsuleWidth: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .resultCompact, .error:
            return Self.capsuleWidth
        case .resultExpanded:
            return nil
        }
    }

    private var lockedCapsuleHeight: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .resultCompact, .error:
            return Self.capsuleHeight
        case .resultExpanded:
            return nil
        }
    }

    private static let capsuleWidth: CGFloat = 392
    private static let capsuleHeight: CGFloat = 50

    @ViewBuilder
    private var content: some View {
        switch state {
        case .recording(let elapsed, let total):
            RecordingPillContent(
                elapsed: elapsed,
                totalDisplay: total,
                dotColor: .vfRecordingRed,
                accentColor: .vfTextPrimary,
                middleLabel: nil,
                pulsingDot: true,
                onCancel: onCancel,
                onStop: onStop
            )
        case .wrappingUp(let elapsed, let total):
            // middleLabel is intentionally suppressed: its ~110pt text
            // doesn't fit alongside the timer + waveform + Cancel + Stop
            // inside the .recording-sized chrome. The amber tint
            // (dotColor + accentColor) carries the "wrapping up soon"
            // signal on its own. If a textual reinforcement is needed
            // in a later phase, redesign it to swap the waveform's slot
            // rather than adding alongside.
            RecordingPillContent(
                elapsed: elapsed,
                totalDisplay: total,
                dotColor: .vfWarningAmber,
                accentColor: .vfWarningAmber,
                middleLabel: nil,
                pulsingDot: false,
                onCancel: onCancel,
                onStop: onStop
            )
        case .processing(let stepLabel):
            ProcessingPillContent(stepLabel: stepLabel, onCancel: onCancel)
        case .resultCompact:
            ResultPillContent(
                expanded: false,
                markdown: generatedPrompt ?? ResultPillContent.placeholderMarkdown,
                onCopy: onCopy,
                onToggleExpand: onToggleExpand,
                onSendChip: onSendChip
            )
        case .resultExpanded:
            ResultPillContent(
                expanded: true,
                markdown: generatedPrompt ?? ResultPillContent.placeholderMarkdown,
                onCopy: onCopy,
                onToggleExpand: onToggleExpand,
                onSendChip: onSendChip
            )
        case .error(let message):
            ErrorPillContent(message: message, onDismiss: onDismissError)
        }
    }

    private var cornerRadius: CGFloat {
        switch state {
        case .resultExpanded: return 18
        default:              return 28
        }
    }
}

// MARK: - ErrorPillContent
//
// Same chrome geometry as the recording/processing capsules so the
// transition into .failed feels like a state morph, not a separate
// surface. Amber-tinted (per the C0 brief's "amber-tinted message"
// guidance — distinct from .vfRecordingRed so the user reads it as
// "something went wrong, the recording is over" rather than "still
// recording, wrap up"). Single-line message + dismiss X. C5 scope:
// non-actionable; if a later phase needs Retry / Open Settings it
// will add buttons here.

private struct ErrorPillContent: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.vfWarningAmber)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()

            Spacer(minLength: VFSpacing.md)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.vfTextSecondary)
                    .contentShape(Rectangle())
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }
}

// MARK: - PulsingDot
//
// Opacity loop (1.0 ↔ 0.6, 1.2s, autoreversing) — used by the recording
// pill's red dot and the menu-bar icon's recording variant so both
// indicators feel like one signal.

struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing ? 0.6 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

// MARK: - RecordingPillContent
//
// Shared between `.recording` and `.wrappingUp`. The tint colors the
// record dot, the elapsed-time digits, and the waveform. A non-nil
// `middleLabel` adds the "Wrapping up soon" sub-label between the
// waveform and the Cancel button.

private struct RecordingPillContent: View {
    let elapsed: String
    let totalDisplay: String
    let dotColor: Color
    let accentColor: Color
    let middleLabel: String?
    let pulsingDot: Bool
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            if pulsingDot {
                PulsingDot(color: dotColor, size: 8)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
            }

            HStack(spacing: 0) {
                Text(elapsed)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .monospacedDigit()
                    .fixedSize()
                Text(" / \(totalDisplay)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.vfTextSecondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            WaveformView(
                bars: Array(WaveformView.sampleBarsLong.prefix(22)),
                color: accentColor,
                barWidth: 2,
                spacing: 2,
                maxHeight: 16
            )
            .fixedSize()

            if let middleLabel {
                Text(middleLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .fixedSize()
            }

            // Absorbs the width difference between `.recording` (no
            // middleLabel) and `.wrappingUp` (with middleLabel). Pushes
            // Cancel/Stop to the trailing edge in both states.
            Spacer(minLength: VFSpacing.md)

            cancelButton

            stopButton
        }
        .padding(.horizontal, VFSpacing.xl)
        .padding(.vertical, 10)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                Text("Cancel")
                    .font(.system(size: 12))
                    .fixedSize()
            }
            .foregroundStyle(Color.vfTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var stopButton: some View {
        Button(action: onStop) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.vfRecordingRed, in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - ProcessingPillContent
//
// Replaces timer + waveform with a centered "spinner + label" pair and
// a separate Cancel affordance on the right. The spinner and label
// are intentionally tight-coupled (one unit) so the label reads as
// describing what the spinner is doing, not as a separate item.
//
// For Phase 2.5 the label is static. The cycling between the three
// strings ("Listening to your narration…" / "Looking at your screen…"
// / "Writing your prompt…") wires in during Phase 2.75.

private struct ProcessingPillContent: View {
    let stepLabel: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            HStack(spacing: VFSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.vfTextSecondary)

                Text(stepLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize()
            }

            // Pushes Cancel to the trailing edge so .processing's
            // overall layout matches .recording/.wrappingUp: left
            // cluster, right action.
            Spacer(minLength: VFSpacing.md)

            cancelButton
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                Text("Cancel processing")
                    .font(.system(size: 12))
                    .fixedSize()
            }
            .foregroundStyle(Color.vfTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - ResultPillContent
//
// Shared by `.resultCompact` (expanded == false) and `.resultExpanded`
// (expanded == true). The header strip is identical between the two —
// green check, "Prompt ready", hero blue Copy button, expand/collapse
// chevron — only the chevron label and icon flip.
//
// In `.resultExpanded` (next step) this view adds the structured-prompt
// body and the send-chips row below the header strip, and the Copy
// button moves into an overlay that punches the top edge of the body
// container. For `.resultCompact` the Copy button is fully contained
// within the pill — no overlay, no edge-punching.

private struct ResultPillContent: View {
    let expanded: Bool
    /// The structured Markdown prompt to render in the body. Threaded
    /// from AppState.generatedPrompt at the PillView level; falls back
    /// to `placeholderMarkdown` when the call site hasn't supplied one
    /// (previews; transient state windows).
    let markdown: String
    let onCopy: () -> Void
    let onToggleExpand: () -> Void
    let onSendChip: (String) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            headerStrip
                .zIndex(1)
            if expanded {
                // Wrapper HStack with Spacers forces explicit centering
                // of the 720pt body card inside the 760pt VStack, giving
                // 20pt of chrome on each side. (Relying on VStack's
                // default `.center` alignment via `.frame(width: 720)`
                // wasn't reliably producing the gutters in the running
                // app.) Body sits cleanly BELOW the header — the
                // Phase 2.5 `-24` slide-up has been retired; this design
                // wants the body on its own row, not punching through.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bodyContainer
                    Spacer(minLength: 0)
                }
                sendChipsRow
            }
        }
        // In `.resultExpanded` we pin the VStack (chrome) to 760pt: the
        // 720pt bodyContainer centers inside via the wrapper HStack
        // above, leaving 20pt gutters. In `.resultCompact` width is
        // owned by `PillView`'s locked frame and the header strip's
        // internal Spacer absorbs the slack.
        .frame(width: expanded ? 760 : nil)
        .fixedSize(horizontal: false, vertical: expanded)
        // Clip ONLY the expanded result content so the body-card fill
        // can't bleed past the chrome's rounded corners. The capsule
        // states don't need clipping (content fits inside the chrome
        // naturally), and clipping at the chrome level was producing
        // square shadow notches at the four corners.
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 18 : 28, style: .continuous))
    }

    private var headerStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfSuccessGreen)

                Text("Prompt ready")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .fixedSize()
            }

            // Collapses to `xxl` when the pill is content-sized (compact);
            // expands to fill when the pill has a fixed wide width (expanded).
            Spacer(minLength: VFSpacing.xxl)

            HStack(spacing: VFSpacing.md) {
                copyButton
                expandToggle
            }
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text("Copy")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.vfBrandBlue, in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var expandToggle: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 4) {
                Text(expanded ? "Hide" : "View")
                    .font(.system(size: 12))
                    .fixedSize()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.vfTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Expanded body

    private var bodyContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Divider().overlay(Color.vfHairline)
            markdownScroll
        }
        // Width is fixed; height is owned by the inner ScrollView so the
        // hard `.frame(height: 420)` survives `.fixedSize(vertical: true)`
        // propagation from the parent VStack. (A ScrollView's ideal height
        // is its content's intrinsic height, so without an explicit frame
        // on the ScrollView itself, fixedSize-propagation would expand the
        // body to fit the full markdown sample.)
        .frame(width: 720)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.4))
        )
    }

    private var eyebrow: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(Color.vfTextTertiary)
            Text("STRUCTURED PROMPT \u{00B7} MARKDOWN")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.vfTextTertiary)
                .fixedSize()
        }
        .padding(.horizontal, VFSpacing.xl)
        .padding(.top, VFSpacing.lg) // body sits cleanly below the header now — no overlap compensation needed
        .padding(.bottom, VFSpacing.md)
    }

    private var markdownScroll: some View {
        ScrollView {
            HighlightedMarkdownView(markdown: markdown)
                .padding(.horizontal, VFSpacing.xl + VFSpacing.xs)
                .padding(.vertical, VFSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Hard 420pt frame lives on the ScrollView itself — survives
        // `.fixedSize(vertical: true)` propagation from the parent VStack
        // so overflowing markdown scrolls inside the body instead of
        // expanding the pill.
        .frame(height: 420)
    }

    // Lives outside `bodyContainer` so the body card reads as a distinct
    // inset rectangle and the chrome's dark surface separates the body
    // bottom edge from the send-chips row (~20pt gap in the design).
    private var sendChipsRow: some View {
        HStack(spacing: VFSpacing.sm) {
            Text("Or send directly to:")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
            Spacer(minLength: VFSpacing.sm)
            sendChip(icon: "paperplane", label: "Cursor")
            sendChip(icon: "paperplane", label: "Windsurf")
            sendChip(icon: "paperplane", label: "v0")
            sendChip(icon: "doc.text", label: "Save snippet")
        }
        .padding(.horizontal, VFSpacing.lg + VFSpacing.xs) // aligns roughly with body card's left edge inside the chrome
        .padding(.top, VFSpacing.lg + VFSpacing.xs)         // ~20pt breathing room between body card bottom and the chips row
        .padding(.bottom, VFSpacing.md)
    }

    private func sendChip(icon: String, label: String) -> some View {
        Button {
            onSendChip(label)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
                    .fixedSize()
            }
            .foregroundStyle(Color.vfTextPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.vfHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Fallback markdown when no generatedPrompt has been threaded in.
    /// Used by SwiftUI previews and for the brief transition window
    /// between state flipping to .done and the result body rendering.
    /// Production call sites always have a real generatedPrompt by the
    /// time the pill morphs into a result state.
    static let placeholderMarkdown = """
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
}

// MARK: - Previews

#Preview("Recording") {
    PillView(state: .recording(elapsed: "1:44", totalDisplay: "3:00"))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Wrapping up") {
    PillView(state: .wrappingUp(elapsed: "2:59", totalDisplay: "3:00"))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Processing") {
    PillView(state: .processing(stepLabel: "Looking at your screen\u{2026}"))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Compact") {
    PillView(state: .resultCompact)
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Expanded") {
    PillView(state: .resultExpanded)
        .padding(40)
        .background(Color.vfPanelBackground)
}
