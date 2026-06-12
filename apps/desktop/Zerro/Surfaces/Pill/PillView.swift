//
//  PillView.swift
//  Zerro
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

/// Phase 6 — the "Write agent prompt" conversion affordance on artifact-less
/// results, as the pill renders it. `.hidden` (a card is present, or the
/// feature doesn't apply), `.available` (ghost button), `.running` (inline
/// spinner), `.failed` (quiet retry note + the button again). Mapped from
/// `AppState.conversionStatus` by PillHostView so the pill stays a pure
/// renderer.
enum ConversionAffordance: Equatable {
    case hidden, available, running, failed
}

enum PillState: Equatable {
    case recording(elapsed: String, totalDisplay: String)
    case wrappingUp(elapsed: String, totalDisplay: String)
    case processing(stepLabel: String)
    case resultCompact
    case resultExpanded
    /// `retryable` drives whether the error pill renders a Retry button
    /// alongside Dismiss. Set by the bridge from
    /// `AppState.canRetryFailure` — combines the failure reason's
    /// `isRetryable` (network / rate-limit / provider) with the
    /// per-failure-chain attempt cap. False means the only affordance is
    /// Dismiss (the user has to fix the underlying cause: Settings, free
    /// up disk, re-record, etc.).
    case error(message: String, retryable: Bool)
    /// M2 — recovery confirmation. Offered at wake/launch when a recording that
    /// a system sleep interrupted is recoverable on disk. Reads "Recording
    /// stopped when your Mac slept — generate a prompt from it?" with exactly
    /// two outcomes: Generate (run the recovered recording, spending the credit
    /// with consent) and Discard (delete it). Dismissing the pill any other way
    /// also resolves to Discard. Recovery NEVER auto-generates — it always asks.
    case confirmRecovery
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
    var onDismissError: () -> Void = {}
    /// Re-runs the API stage against the already-processed recording on
    /// disk. Wired in `PillWindowController` to `AppState.retryFailedPrompt`;
    /// only invoked when the active `.error` state has `retryable == true`.
    /// Default no-op so #Preview blocks can keep passing literal states
    /// without ceremony.
    var onRetryError: () -> Void = {}
    /// Closes the result pill from either compact or expanded state. The
    /// affordance is a small "x" badge tucked into the chrome's top-right
    /// corner so users can dismiss after copying without having to wait
    /// for the next hotkey press.
    var onDismissResult: () -> Void = {}

    /// M2 recovery-pill resolutions — exactly two outcomes. `onRecoveryGenerate`
    /// runs the recovered recording (spends the credit, with consent);
    /// `onRecoveryDiscard` deletes it. Dismissing the pill by any other means
    /// also routes to Discard (wired in PillWindowController) — there is no
    /// leave-on-disk path. Default no-ops so `#Preview` blocks can pass a
    /// literal `.confirmRecovery` state without ceremony.
    var onRecoveryGenerate: () -> Void = {}
    var onRecoveryDiscard: () -> Void = {}

    /// The parsed result the pill renders (Phase 5): chat text, optional
    /// artifact card, optional Attached Context drawer. Threaded from
    /// AppState.resultPresentation via PillWindowController so the
    /// pure-renderer PillView doesn't need to know about AppState.
    /// `nil` falls back to a placeholder so previews and the brief
    /// transition window (state flips to .done before the result view
    /// can re-render) don't render an empty card.
    var result: ResultPresentation? = nil

    /// Phase 6 — the conversion ghost-button state for artifact-less results.
    /// Defaults `.hidden` so previews/legacy call sites render no affordance.
    var conversion: ConversionAffordance = .hidden
    /// Kicks off the conversion (wired to `AppState.convertToAgentPrompt`).
    var onConvert: () -> Void = {}

    /// True when the result was generated from the screen alone (no
    /// usable narration). Drives the amber "no narration detected" note
    /// in the result pill. Threaded from AppState.resultHadNoNarration
    /// via PillWindowController so PillView stays a pure renderer.
    var resultHadNoNarration: Bool = false

    /// M2 — true when this result was recovered at launch from a recording a
    /// system sleep interrupted. Drives a one-line "recovered after sleep"
    /// note in the expanded result body. Threaded from AppState.stoppedBySleep
    /// via PillWindowController; PillView stays a pure renderer.
    var stoppedBySleep: Bool = false

    /// Multi-model 6B — the pre-formatted "−N credits · M left" toast line
    /// (CreditDisplay.chargeLine over the server's exact `credits_charged`,
    /// D2). `nil` for BYOK/local results and pre-D2 backends — the header then
    /// renders exactly as before. Threaded from AppState.lastGenerationCharge
    /// via PillWindowController; PillView stays a pure renderer.
    var chargeLine: String? = nil

    /// Live mic-input peak levels for the recording/wrappingUp waveform.
    /// 22-element rolling buffer threaded from AppState.audioLevels.
    /// `nil` falls back to the static sample bars so previews and the
    /// idle-pill-during-warmup window still render a plausible
    /// waveform.
    var audioLevels: [CGFloat]? = nil

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
        case .resultExpanded, .confirmRecovery:
            return nil
        }
    }

    private var lockedCapsuleHeight: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .resultCompact, .confirmRecovery:
            return Self.capsuleHeight
        // .error keeps the locked 392 width (so it still reads as the same
        // capsule it morphed from) but drives its own height: a long
        // message wraps to a second line and grows the pill down rather
        // than overflowing the fixed single-line frame. ErrorPillContent
        // floors itself at capsuleHeight so short messages still render as
        // the familiar 50pt capsule.
        case .resultExpanded, .error:
            return nil
        }
    }

    private static let capsuleWidth: CGFloat = 392
    fileprivate static let capsuleHeight: CGFloat = 50

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
                audioLevels: audioLevels,
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
                audioLevels: audioLevels,
                onCancel: onCancel,
                onStop: onStop
            )
        case .processing(let stepLabel):
            ProcessingPillContent(stepLabel: stepLabel, onCancel: onCancel)
        case .resultCompact:
            ResultPillContent(
                expanded: false,
                result: result ?? ResultPillContent.placeholderResult,
                noNarration: resultHadNoNarration,
                stoppedBySleep: stoppedBySleep,
                chargeLine: chargeLine,
                conversion: conversion,
                onCopy: onCopy,
                onToggleExpand: onToggleExpand,
                onDismiss: onDismissResult,
                onConvert: onConvert
            )
        case .resultExpanded:
            ResultPillContent(
                expanded: true,
                result: result ?? ResultPillContent.placeholderResult,
                noNarration: resultHadNoNarration,
                stoppedBySleep: stoppedBySleep,
                chargeLine: chargeLine,
                conversion: conversion,
                onCopy: onCopy,
                onToggleExpand: onToggleExpand,
                onDismiss: onDismissResult,
                onConvert: onConvert
            )
        case .error(let message, let retryable):
            ErrorPillContent(
                message: message,
                onRetry: retryable ? onRetryError : nil,
                onDismiss: onDismissError
            )
        case .confirmRecovery:
            ConfirmRecoveryPillContent(
                onGenerate: onRecoveryGenerate,
                onDiscard: onRecoveryDiscard
            )
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
// recording, wrap up").
//
// Phase 10: Retry button appears left of Dismiss when `onRetry` is
// non-nil — wired only for transient API failures (network / rate-limit
// / provider) that the bridge can re-run against the already-processed
// recording. For non-retryable errors (auth, permission, disk, capture)
// `onRetry` is nil and only the dismiss X renders.

private struct ErrorPillContent: View {
    let message: String
    /// Non-nil only when the active failure is transient and the
    /// per-failure-chain attempt cap hasn't been hit. The bridge passes
    /// `PillView.onRetryError` through when `retryable == true` and `nil`
    /// otherwise; this view doesn't track the cap itself.
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.vfWarningAmber)

            // Wrap to at most two lines within the locked 392 width
            // instead of `.fixedSize()`-ing to the message's full
            // intrinsic width (which overflowed the chrome for the
            // longer copy, e.g. "Add your OpenAI API key in Settings to
            // generate prompts."). `fixedSize(vertical:)` lets the text
            // claim the height its wrapped layout needs.
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: VFSpacing.md)

            if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                        Text("Retry")
                            .font(.system(size: 12))
                            .fixedSize()
                    }
                    .foregroundStyle(Color.vfTextSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

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
        // Floor at the capsule height so a one-line error still reads as
        // the standard 50pt pill; two-line copy grows past it.
        .frame(minHeight: PillView.capsuleHeight)
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
    /// Live mic-input peak levels; `nil` falls back to the static
    /// sample so previews still render a plausible waveform.
    let audioLevels: [CGFloat]?
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
                bars: audioLevels ?? Array(WaveformView.sampleBarsLong.prefix(22)),
                color: accentColor,
                barWidth: 2,
                spacing: 2,
                maxHeight: 16
            )
            // Animate height changes between emits so the 12.5Hz feed
            // reads as a continuously breathing waveform instead of
            // stepping frame-to-frame. Duration slightly under the
            // emit interval so each value nearly finishes before the
            // next arrives.
            .animation(.easeOut(duration: 0.1), value: audioLevels)
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
        // Extra leading inset: the capsule's left cap is a 25pt-radius
        // curve, so the standard xl pad crowds the record dot into the
        // bend. Pad the leading edge out toward the cap radius so the dot
        // + timer read as centered against the rounded edge rather than
        // hugging it; the trailing edge keeps the standard xl inset.
        .padding(.leading, VFSpacing.xxl)
        .padding(.trailing, VFSpacing.xl)
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
}

// MARK: - ConfirmRecoveryPillContent
//
// M2 — the recovery confirmation: locked capsule height, content-driven
// width, left icon badge + question + trailing action cluster — the same
// pill-family chrome the processing capsule morphs between. A
// recording that a system sleep interrupted is recoverable on disk; rather
// than silently spending a credit, we ASK — exactly two outcomes, made
// self-evident by the two verbs: "Discard" (delete it, secondary) and the
// primary "Generate" (run it, spending the credit with consent). There is no
// separate dismiss affordance: dismissing the pill resolves to Discard (see
// PillWindowController), so a recovered recording is never silently retained.
// The moon glyph ties it to the result's "recovered after sleep" note.

private struct ConfirmRecoveryPillContent: View {
    let onGenerate: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            iconBadge

            Text("Recording stopped when your Mac slept \u{2014} generate a prompt from it?")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()

            Spacer(minLength: 40)

            discardButton
            generateButton
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    private var iconBadge: some View {
        Image(systemName: "moon.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.vfAccentBlue)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.vfAccentBlue.opacity(0.20)))
    }

    private var discardButton: some View {
        Button(action: onDiscard) {
            Text("Discard")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var generateButton: some View {
        Button(action: onGenerate) {
            Text("Generate")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.vfAccentBlue, in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - ResultPillContent
//
// Shared by `.resultCompact` (expanded == false) and `.resultExpanded`
// (expanded == true).
//
// Compact keeps the Phase 2.75 capsule header unchanged: green check +
// "Prompt ready" + hero Copy + View chevron + close X.
//
// Expanded follows the Phase 5 approved design: a slim top strip (status +
// charge line on the left, close X on the right — no Copy/Hide there),
// then the chat text rendered directly on the chrome, then the artifact
// card (ArtifactCardView), which owns the title row, the Hide chevron, the
// Attached Context drawer, and the single per-type copy button. A
// chat-only response renders no card at all — the strip keeps a Hide
// toggle in that case so the pill can still collapse to compact.

private struct ResultPillContent: View {
    let expanded: Bool
    /// The parsed result to render. Threaded from
    /// AppState.resultPresentation at the PillView level; falls back to
    /// `placeholderResult` when the call site hasn't supplied one
    /// (previews; transient state windows).
    let result: ResultPresentation
    /// True when the prompt was generated from the screen alone because
    /// no usable narration was detected. Tints the header indicator amber
    /// and, in the expanded body, shows a note explaining why the prompt
    /// reads generically. The prompt is still real and copyable — this is
    /// a heads-up, not an error.
    let noNarration: Bool
    /// M2 — true when this result was recovered at launch from a sleep-
    /// interrupted recording. Shows an informational note in the expanded body.
    /// Unlike `noNarration`, this is NOT a quality caveat: the prompt is
    /// complete and valid, so the note stays neutral (no amber header tint) —
    /// it only explains why a result appeared on its own.
    let stoppedBySleep: Bool
    /// Multi-model 6B — the "−N credits · M left" toast, rendered as a small
    /// secondary line under "Prompt ready". `nil` (BYOK/local) keeps the
    /// single-line header exactly as before.
    let chargeLine: String?
    /// Phase 6 — the "Write agent prompt" affordance state. Rendered only in
    /// the expanded artifact-less layout.
    let conversion: ConversionAffordance
    let onCopy: () -> Void
    let onToggleExpand: () -> Void
    /// Dismisses the result pill — wired to AppState.resetToIdle. Rendered
    /// as a circular close badge after the Hide/View toggle in the header
    /// strip, separated by a thin vertical hairline divider.
    let onDismiss: () -> Void
    /// Phase 6 — starts (or retries) the conversion.
    let onConvert: () -> Void

    /// Transient "Copied" confirmation. Flips true on tap, reverts after
    /// `copyFeedbackDuration`. Local to this view — the clipboard write
    /// itself lives in `onCopy`; this is purely the visual acknowledgement
    /// the button previously lacked. Not persisted across the
    /// compact↔expanded morph (each is a distinct ResultPillContent), which
    /// is fine: the feedback is a sub-2s flash, not durable state.
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    /// Tracks hover on the dismiss button itself (not the whole pill)
    /// so the circular dark-gray background fills in only when the
    /// cursor is on the X. The divider + glyph stay visible at rest.
    @State private var isHoveringDismiss = false

    /// How long the "Copied" confirmation stays up before reverting.
    private static let copyFeedbackDuration: Duration = .seconds(1.6)

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            headerStrip
                .zIndex(1)
            if expanded {
                // Wrapper HStack with Spacers forces explicit centering
                // of the 720pt body inside the 760pt VStack, giving
                // 20pt of chrome on each side. (Relying on VStack's
                // default `.center` alignment via `.frame(width: 720)`
                // wasn't reliably producing the gutters in the running
                // app.)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    expandedBody
                    Spacer(minLength: 0)
                }
                // Bottom gutter matching the 20pt side gutters so the
                // chrome wraps the content on all sides — otherwise the
                // card's dark fill runs flush to the pill's bottom edge.
                .padding(.bottom, 20)
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
                // Title stays "Prompt ready" in both cases — the compact
                // pill's locked 392 width has no room for a longer string
                // alongside Copy + View. The amber indicator carries the
                // "heads up" signal in compact; the expanded body spells
                // it out in `noNarrationNote`.
                Image(systemName: noNarration ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(noNarration ? Color.vfWarningAmber : Color.vfSuccessGreen)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Prompt ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.vfTextPrimary)
                        .fixedSize()
                    // Multi-model 6B: the exact server charge (D2), quiet and
                    // secondary so the header keeps its compact footprint.
                    if let chargeLine {
                        Text(chargeLine)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.vfTextSecondary)
                            .fixedSize()
                    }
                }
            }

            // Collapses to `xxl` when the pill is content-sized (compact);
            // expands to fill when the pill has a fixed wide width (expanded).
            Spacer(minLength: VFSpacing.xxl)

            HStack(spacing: VFSpacing.md) {
                if !expanded {
                    // Compact keeps its hero Copy + View affordances.
                    copyButton
                    expandToggle
                    dismissDivider
                } else if result.artifact == nil {
                    // Expanded with a card: Copy and Hide moved INTO the
                    // card (per the Phase 5 design) — the strip carries
                    // only status + close. Chat-only has no card, so the
                    // Hide toggle stays here or the pill couldn't collapse.
                    expandToggle
                    dismissDivider
                }
                dismissButton
            }
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    /// Thin vertical hairline between the Hide/View toggle and the
    /// close X — visually groups dismiss as a separate affordance from
    /// expand/collapse. Always visible.
    private var dismissDivider: some View {
        Rectangle()
            .fill(Color.vfHairline)
            .frame(width: 1, height: 20)
    }

    /// Close X. The glyph is always visible; only the circular dark-gray
    /// background fills in when the cursor is over the button itself, so
    /// dismiss has a clear hover affordance without lighting up whenever
    /// the user moves over the rest of the pill.
    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                // Match the Hide/View label color at rest so the X reads
                // as a peer to the other header controls; bump to primary
                // (white) on hover to mirror the circular background fade
                // in and signal the button is active.
                .foregroundStyle(isHoveringDismiss ? Color.vfTextPrimary : Color.vfTextSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color(red: 0.28, green: 0.28, blue: 0.30))
                        .opacity(isHoveringDismiss ? 1 : 0)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringDismiss = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringDismiss)
    }

    private var copyButton: some View {
        Button(action: handleCopy) {
            HStack(spacing: 5) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(didCopy ? "Copied" : "Copy")
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
        // Cancel any in-flight reset so a second tap restarts the full
        // window rather than reverting early from the prior tap's timer.
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: Self.copyFeedbackDuration)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
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

    /// The Phase 5 expanded layout: notes, then chat text rendered directly
    /// on the chrome, then the artifact card. A chat-only response simply
    /// has no card — the pill is the chat text, which must read as
    /// intentional, not broken (hence no empty card stub, no divider).
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            if stoppedBySleep {
                stoppedBySleepNote
            }
            if noNarration {
                noNarrationNote
            }
            if !result.chatText.isEmpty {
                // Hugs short chat and scrolls long chat. With a card below,
                // the cap is tight (chat is the intro, the card is the
                // payload); chat-only gets the room the old body had.
                HeightCappedScroll(maxHeight: result.artifact == nil ? 420 : 160) {
                    HighlightedMarkdownView(markdown: result.chatText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let artifact = result.artifact {
                ArtifactCardView(
                    artifact: artifact,
                    context: result.context,
                    onCopy: onCopy,
                    onCollapse: onToggleExpand
                )
                // Phase 6: a converted artifact arrives AFTER the response is
                // already on screen — slide the card in under the chat text
                // rather than popping. (For a normal generation the card is
                // present from the first render, so the transition is inert.)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if result.artifact == nil, conversion != .hidden {
                conversionRow
            }
        }
        .frame(width: 720, alignment: .leading)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: result)
    }

    /// Phase 6 — the ghost "✎ Write agent prompt" affordance on artifact-less
    /// responses: a quiet stroked capsule (no fill — deliberately NOT the hero
    /// copy style), an inline spinner while the conversion runs, and an
    /// unobtrusive one-line retry note on failure. The existing chat text is
    /// never touched by any of these states.
    private var conversionRow: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            if conversion == .failed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfWarningAmber)
                    Text("Couldn\u{2019}t write the prompt \u{2014} try again")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextSecondary)
                        .fixedSize()
                }
            }
            Button(action: onConvert) {
                HStack(spacing: 6) {
                    if conversion == .running {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.vfTextSecondary)
                        Text("Writing prompt\u{2026}")
                            .fixedSize()
                    } else {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 11, weight: .medium))
                        Text("Write agent prompt")
                            .fixedSize()
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(conversion == .running)
        }
    }

    /// Amber heads-up shown above the prompt body when no usable
    /// narration was detected. Explains why the prompt reads generically
    /// (generated from the screen alone) without framing it as a failure
    /// — the prompt is real and copyable. Expanded-only: the compact pill
    /// has no vertical room, and the amber header icon already signals it.
    private var noNarrationNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfWarningAmber)
            Text("No narration detected \u{2014} this prompt was generated from your screen alone. For a sharper result, record again and describe what you want.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// M2 — neutral heads-up shown above the prompt body when this result was
    /// recovered at launch from a recording a system sleep interrupted.
    /// Explains why a result appeared on its own without framing it as a
    /// failure: the prompt below is complete and copyable, built from what was
    /// captured before the sleep. Expanded-only, mirroring `noNarrationNote`.
    private var stoppedBySleepNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "moon.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
            Text("Recovered from a recording that stopped when your Mac went to sleep \u{2014} this prompt was built from what you captured before then.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fallback result when none has been threaded in. Used by SwiftUI
    /// previews and for the brief transition window between state flipping
    /// to .done and the result view rendering. Production call sites always
    /// have a real result by the time the pill morphs into a result state.
    static let placeholderResult = ResultPresentation(
        chatText: "I watched you walk through the Pulse login screen \u{2014} "
            + "here\u{2019}s an agent prompt covering the three layout changes you asked for.",
        artifact: Artifact(
            type: .agentPrompt,
            rawType: "agent_prompt",
            title: "Rework the Pulse login screen layout",
            body: placeholderMarkdown
        ),
        context: AttachedContext(
            summary: "screen text, 3 clicks",
            block: """
            ## Attached Context
            **Screen text (OCR excerpts):** Sign in
            Email
            Password
            Forgot password?
            **Clicks:** clicked "Sign in", clicked "Forgot password?", clicked "SSO"
            """
        )
    )

    /// Body text for `placeholderResult`'s sample artifact.
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

#Preview("Result \u{00B7} Expanded \u{00B7} agent_prompt") {
    PillView(state: .resultExpanded)
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Expanded \u{00B7} snippet") {
    PillView(
        state: .resultExpanded,
        result: ResultPresentation(
            chatText: "That layout shift comes from the unsized avatar image \u{2014} here\u{2019}s the CSS that reserves its box.",
            artifact: Artifact(
                type: .snippet,
                rawType: "snippet",
                title: "Reserve space for the avatar image",
                body: ".avatar {\n  width: 40px;\n  height: 40px;\n  aspect-ratio: 1;\n  object-fit: cover;\n}"
            ),
            context: AttachedContext(summary: "screen text", block: "## Attached Context\n**Screen text (OCR excerpts):** Profile\nSettings")
        )
    )
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Expanded \u{00B7} chat-only") {
    PillView(
        state: .resultExpanded,
        result: ResultPresentation(
            chatText: "The error in your terminal is a stale lockfile \u{2014} "
                + "running `npm install` again after deleting `package-lock.json` clears it. "
                + "Nothing on screen needs a code change, so there\u{2019}s nothing to hand to an agent here.",
            artifact: nil,
            context: nil
        )
    )
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} No narration") {
    PillView(state: .resultExpanded, resultHadNoNarration: true)
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Convert button") {
    PillView(
        state: .resultExpanded,
        result: ResultPresentation(
            chatText: "That hydration error comes from rendering `Date.now()` during SSR \u{2014} the server and client markup disagree.",
            artifact: nil,
            context: nil
        ),
        conversion: .available
    )
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Convert failed") {
    PillView(
        state: .resultExpanded,
        result: ResultPresentation(
            chatText: "That hydration error comes from rendering `Date.now()` during SSR.",
            artifact: nil,
            context: nil
        ),
        conversion: .failed
    )
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Error \u{00B7} Short") {
    PillView(state: .error(message: "Recording was interrupted.", retryable: false))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Error \u{00B7} Long") {
    // The longest production message — exercises the two-line wrap.
    PillView(state: .error(
        message: "Add your OpenAI API key in Settings to generate prompts.",
        retryable: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Error \u{00B7} Retryable") {
    // Transient API failure — exercises the Retry-button affordance.
    PillView(state: .error(
        message: "Couldn\u{2019}t reach OpenAI \u{2014} check your connection.",
        retryable: true
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}
