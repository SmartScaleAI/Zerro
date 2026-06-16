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
    /// M5 — a PAID-blocked failure (trial credits exhausted / out of credits /
    /// inactive subscription) that still has a held recording on disk. Rendered
    /// in the same chrome as `.confirmRecovery` but amber: a warning badge, the
    /// paid-block copy, a plain "Discard" button, and a filled primary button
    /// that reads "Upgrade" until the user is entitled and "Generate" after.
    /// `entitled` carries `EntitlementStore.canGenerate` so the label flips live
    /// (read in the bridge so Observation tracks it). Mapped from `.failed` by
    /// the bridge when `AppState.canResumePaidGeneration` is true.
    case paidBlockResume(message: String, entitled: Bool)
    /// The expanded failure card — shown for RETRYABLE generation failures
    /// (`AppState.canRetryFailure == true`). Reuses the success card's chrome
    /// in an error configuration: amber caution badge, the `headline`
    /// ("Generation failed"), the underlying `detail` as scrollable prose, and
    /// a Retry button in place of Copy. Non-retryable failures keep the compact
    /// `.error` capsule. Mapped from `.failed` by the bridge.
    case failureExpanded(headline: String, detail: String)
    /// M2 — recovery confirmation. Offered at wake/launch when a recording that
    /// was interrupted (system sleep, app quit, network drop, etc.) is
    /// recoverable on disk. Reads "Recording stopped — generate a prompt from
    /// it?" with exactly
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
    /// M5 — the `.paidBlockResume` pill's primary action. Wired in
    /// `PillWindowController` to `AppState.resumePaidGeneration`, which re-checks
    /// entitlement and either re-runs the held recording (when entitled) or opens
    /// the paywall — so the one action backs both the "Generate" and "Upgrade"
    /// labels. Default no-op so #Preview blocks can pass literal states without
    /// ceremony.
    var onResumePaidGeneration: () -> Void = {}
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

    /// The parsed result the pill renders (Phase 5): chat text and the
    /// optional artifact card. Threaded from
    /// AppState.resultPresentation via PillWindowController so the
    /// pure-renderer PillView doesn't need to know about AppState.
    /// `nil` falls back to `ResultPresentation.empty` (a neutral, content-free
    /// card) during the brief teardown window when state flips `.done → .idle`
    /// before the result view re-renders. Previews pass a rich sample
    /// explicitly via `result: ResultPillContent.placeholderResult`.
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

    /// The recording-flow capsule states (`.recording`, `.wrappingUp`,
    /// `.processing`) share one fixed width and height so size never
    /// changes between them — the only morph allowed inside the lock is
    /// content cross-fades and the chrome's corner radius. Sized to
    /// `.recording`'s natural dimensions (the widest+tallest capsule):
    /// dot + timer + waveform + Cancel + Stop. Narrower states absorb
    /// the difference via internal Spacers as breathing room.
    /// `.resultCompact` hugs its content (check + title + View + X) like
    /// the recovery capsule, capped at `capsuleWidth` inside
    /// ResultPillContent so a long title truncates rather than growing the
    /// pill past the locked footprint. `.resultExpanded` is the one
    /// capsule-to-non-capsule morph and keeps its content-driven sizing.
    private var lockedCapsuleWidth: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .error:
            return Self.capsuleWidth
        case .resultCompact, .resultExpanded, .failureExpanded, .confirmRecovery,
             .paidBlockResume:
            return nil
        }
    }

    private var lockedCapsuleHeight: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .resultCompact, .confirmRecovery,
             .paidBlockResume:
            return Self.capsuleHeight
        // .error keeps the locked 392 width (so it still reads as the same
        // capsule it morphed from) but drives its own height: a long
        // message wraps to as many lines as it needs and grows the pill
        // down rather than truncating or overflowing the fixed frame.
        // ErrorPillContent floors itself at capsuleHeight so short messages
        // still render as the familiar 50pt capsule.
        case .resultExpanded, .failureExpanded, .error:
            return nil
        }
    }

    fileprivate static let capsuleWidth: CGFloat = 392
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
                result: result ?? .empty,
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
                result: result ?? .empty,
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
        case .paidBlockResume(let message, let entitled):
            PaidBlockResumePillContent(
                message: message,
                entitled: entitled,
                onPrimary: onResumePaidGeneration,
                onDiscard: onDismissError
            )
        case .failureExpanded(let headline, let detail):
            // Reuse the success card in its failure configuration, wrapped with
            // the same 760-wide / clipped chrome `.resultExpanded` uses so the
            // success ↔ failure layouts stay visually consistent.
            ArtifactCardView(
                artifact: nil,
                chatText: "",
                chargeLine: nil,
                noNarration: false,
                stoppedBySleep: false,
                conversion: .hidden,
                onCopy: {},
                onCollapse: {},
                onDismiss: onDismissError,
                onConvert: {},
                failure: ArtifactCardView.FailureConfig(headline: headline, detail: detail),
                onRetry: onRetryError
            )
            .frame(width: 760)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .confirmRecovery:
            ConfirmRecoveryPillContent(
                onGenerate: onRecoveryGenerate,
                onDiscard: onRecoveryDiscard
            )
        }
    }

    private var cornerRadius: CGFloat {
        switch state {
        case .resultExpanded, .failureExpanded: return 18
        default:                                return 28
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
        // Center-align so the amber icon and the Retry/Dismiss controls sit
        // at the vertical midpoint of the message, however many lines it
        // wraps to.
        HStack(alignment: .center, spacing: VFSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.vfWarningAmber)

            // Wrap within the locked 392 width and show the full message,
            // however many lines it takes, instead of `.fixedSize()`-ing to
            // the message's full intrinsic width (which overflowed the
            // chrome for the longer copy, e.g. "You've used all your free
            // trial credits…"). `fixedSize(vertical:)` lets the text claim
            // the height its wrapped layout needs so nothing is truncated.
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
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
        // the standard 50pt pill; multi-line copy grows past it.
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

    // The "thinking" label arrives as "<phrase>… \u{00B7} <elapsed>". Split
    // on the middot so the phrase can truncate while the elapsed timer stays
    // pinned and fully visible — a long phrase must never shove the timer,
    // spinner, or Cancel off the fixed-width capsule. Labels without a middot
    // (the earlier pipeline stages) render whole and truncate only if needed.
    private static let timeSeparator = " \u{00B7} "

    private var phrasePart: String {
        guard let range = stepLabel.range(of: Self.timeSeparator) else { return stepLabel }
        return String(stepLabel[..<range.lowerBound])
    }

    private var timePart: String? {
        guard let range = stepLabel.range(of: Self.timeSeparator) else { return nil }
        return String(stepLabel[range.upperBound...])
    }

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            HStack(spacing: VFSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.vfTextSecondary)

                // Truncates first so it yields space to everything else.
                Text(phrasePart)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Elapsed timer: pinned and never truncated so it stays
                // readable no matter how long the phrase is. Same gray as the
                // Cancel button so it reads as secondary metadata.
                if let timePart {
                    Text("\u{00B7} \(timePart)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vfTextSecondary)
                        .fixedSize()
                        .layoutPriority(1)
                }
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
// The recovery glyph ties it to the result's "recovered" note.

private struct ConfirmRecoveryPillContent: View {
    let onGenerate: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            iconBadge

            Text("Recording stopped \u{2014} generate a prompt from it?")
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
        Image(systemName: "arrow.clockwise")
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

// MARK: - PaidBlockResumePillContent
//
// M5 (resume after purchase). A paid-blocked failure that still has a held
// recording on disk, styled like `ConfirmRecoveryPillContent` but AMBER (the
// failure tint) instead of blue: a warning badge, the paid-block copy, a plain
// "Discard" button, and a filled primary button. The primary button is a single
// action (`resumePaidGeneration`, which refreshes entitlement then resumes-or-
// paywalls), but its LABEL is dynamic — "Upgrade" until the user is entitled,
// "Generate" after. `entitled` is read from `EntitlementStore.canGenerate` in
// the bridge, so activating a license flips the label live (both stores are
// @Observable). Discard maps to `dismissFailure()`, which for a paid block
// discards the held recording (deletes the working dir + clears the pointer).

private struct PaidBlockResumePillContent: View {
    let message: String
    let entitled: Bool
    let onPrimary: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            iconBadge

            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()

            Spacer(minLength: 40)

            discardButton
            primaryButton
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    private var iconBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.vfWarningAmber)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.vfWarningAmber.opacity(0.20)))
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

    private var primaryButton: some View {
        Button(action: onPrimary) {
            // Single action; the label reflects entitlement — "Upgrade" opens
            // the paywall, "Generate" resumes the held recording.
            Text(entitled ? "Generate" : "Upgrade")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.vfWarningAmber, in: Capsule())
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
// Compact keeps the Phase 2.75 capsule shape, titled by the result itself:
// green check + the artifact's dynamic title ("Response ready" for
// chat-only) + hero Copy + View chevron + close X.
//
// Expanded follows the approved design: a MINIMAL top strip (just the
// charge line, left, and the close X, right — no check, no label; the
// card's own check + title is the success signal), then the chat text as
// prose on the chrome, then the layered artifact card (ArtifactCardView),
// which owns the title row, the Hide chevron,
// and the single per-type copy button. A chat-only response renders no
// card at all — the strip keeps a Hide toggle in that case so the pill can
// still collapse to compact.

private struct ResultPillContent: View {
    let expanded: Bool
    /// The parsed result to render. Threaded from
    /// AppState.resultPresentation at the PillView level; falls back to
    /// `ResultPresentation.empty` in the transient teardown window and to
    /// `placeholderResult` in previews (passed explicitly).
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

    /// Tracks hover on the dismiss button itself (not the whole pill)
    /// so the circular dark-gray background fills in only when the
    /// cursor is on the X. The divider + glyph stay visible at rest.
    @State private var isHoveringDismiss = false

    var body: some View {
        Group {
            if expanded {
                // UI revision 2: the card IS the expanded pill — no outer
                // strip, no gutters. The chrome's rounded rect (drawn by
                // PillView) is the card surface, so the compact ↔ expanded
                // morph targets the card's own rounded rect directly.
                ArtifactCardView(
                    artifact: result.artifact,
                    chatText: result.chatText,
                    chargeLine: chargeLine,
                    noNarration: noNarration,
                    stoppedBySleep: stoppedBySleep,
                    conversion: conversion,
                    onCopy: onCopy,
                    onCollapse: onToggleExpand,
                    onDismiss: onDismiss,
                    onConvert: onConvert
                )
                // Phase 6: a converted artifact arrives AFTER the response
                // is already on screen — animate the body well in rather
                // than popping. (For a normal generation the card renders
                // complete from the first frame, so this is inert.)
                .animation(.spring(response: 0.30, dampingFraction: 0.85), value: result)
            } else {
                headerStrip
                    // The hosting view needs a DETERMINATE width: fixedSize
                    // makes the strip's width its ideal (content hug; the
                    // title is capped inside, so the whole capsule stays
                    // within the locked 392 footprint). A negotiable
                    // 0…392 range here (`.frame(maxWidth:)` on the chrome)
                    // sent NSHostingView into an update-constraints loop
                    // that AppKit aborts by crashing.
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        // In `.resultExpanded` the chrome is pinned to 760pt; compact width
        // is the strip's fixed ideal above.
        .frame(width: expanded ? 760 : nil)
        .fixedSize(horizontal: false, vertical: expanded)
        // Clip ONLY the expanded result content so the body-well fill
        // can't bleed past the chrome's rounded corners. The capsule
        // states don't need clipping (content fits inside the chrome
        // naturally), and clipping at the chrome level was producing
        // square shadow notches at the four corners.
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 18 : 28, style: .continuous))
    }

    /// What the compact capsule calls this result: the artifact's dynamic
    /// title when one is attached (truncating inside the locked 392 width),
    /// a neutral "Response ready" for chat-only. The expanded layout never
    /// shows a status label — the card's own check + title is the success
    /// signal there.
    private var compactLabel: String {
        if let artifact = result.artifact {
            return artifact.title.isEmpty ? "Untitled" : artifact.title
        }
        return "Response ready"
    }

    /// The COMPACT capsule's content (the expanded layout is
    /// ArtifactCardView): check + result title, then View ⌄ + divider +
    /// close X. Copying and the credits readout live ONLY in the expanded
    /// card now, so the title gets the freed width and the capsule hugs
    /// its content (fixed spacing, no Spacer — the maxWidth cap on the
    /// chrome is what makes a long title truncate).
    private var headerStrip: some View {
        HStack(spacing: VFSpacing.xxl) {
            HStack(spacing: VFSpacing.sm) {
                // The amber indicator carries the "heads up" signal in
                // compact; the expanded card spells it out in its
                // no-narration note.
                Image(systemName: noNarration ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(noNarration ? Color.vfWarningAmber : Color.vfSuccessGreen)

                Text(compactLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Title cap = the locked 392 capsule minus the fixed
                    // chrome (paddings, check, spacings, View ⌄, divider,
                    // X). Capping HERE keeps the strip's ideal width
                    // determinate under the fixedSize above — short titles
                    // hug, long ones truncate at the cap.
                    .frame(maxWidth: 228, alignment: .leading)
            }

            HStack(spacing: VFSpacing.md) {
                expandToggle
                dismissDivider
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

    /// Rich sample result for SwiftUI `#Preview` blocks ONLY. Production code
    /// never falls back to this — the `.resultCompact` / `.resultExpanded`
    /// cases use `ResultPresentation.empty` when `result` is nil, so the brief
    /// teardown frame (state flipping `.done → .idle` while `parsedResponse`
    /// nils out) renders an empty card rather than this heavyweight sample.
    /// Pass it explicitly to previews via `result: ResultPillContent.placeholderResult`.
    static let placeholderResult = ResultPresentation(
        chatText: "I watched you walk through the Pulse login screen \u{2014} "
            + "here\u{2019}s an agent prompt covering the three layout changes you asked for.",
        artifact: Artifact(
            type: .agentPrompt,
            rawType: "agent_prompt",
            title: "Rework the Pulse login screen layout",
            body: placeholderMarkdown
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
    PillView(state: .resultCompact, result: ResultPillContent.placeholderResult)
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Expanded \u{00B7} agent_prompt") {
    PillView(state: .resultExpanded, result: ResultPillContent.placeholderResult)
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
            )
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
            artifact: nil
        )
    )
    .padding(40)
    .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} No narration") {
    PillView(
        state: .resultExpanded,
        result: ResultPillContent.placeholderResult,
        resultHadNoNarration: true
    )
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Result \u{00B7} Convert button") {
    PillView(
        state: .resultExpanded,
        result: ResultPresentation(
            chatText: "That hydration error comes from rendering `Date.now()` during SSR \u{2014} the server and client markup disagree.",
            artifact: nil
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
            artifact: nil
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
    // The longest production message — pulls the real copy from
    // `RecordingFailureReason.trialCreditsExhausted.userMessage` (the source
    // of truth in AppState) rather than duplicating it, so the preview can't
    // drift if the copy changes. Exercises the full multi-line wrap at the
    // locked 392 width with no truncation.
    PillView(state: .error(
        message: RecordingFailureReason.trialCreditsExhausted.userMessage,
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

#Preview("Paid block \u{00B7} Upgrade") {
    // M5 — paid-blocked failure, NOT yet entitled: amber resume pill with the
    // filled "Upgrade" button (opens the paywall). Real copy from AppState.
    PillView(state: .paidBlockResume(
        message: RecordingFailureReason.trialCreditsExhausted.userMessage,
        entitled: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Paid block \u{00B7} Generate") {
    // M5 — same pill once the user is entitled: the primary button flips to
    // "Generate" and resumes the held recording on tap.
    PillView(state: .paidBlockResume(
        message: RecordingFailureReason.trialCreditsExhausted.userMessage,
        entitled: true
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Failure \u{00B7} Expanded") {
    // Retryable generation failure — the expanded card with a long, realistic
    // error detail to exercise the body scroll/wrap and the Retry button.
    PillView(state: .failureExpanded(
        headline: "Generation failed",
        detail: "The request to the generation service failed: A server with the "
            + "specified hostname could not be found. (NSURLErrorDomain, code -1003). "
            + "This usually means you\u{2019}re offline or the service is temporarily "
            + "unreachable \u{2014} your recording is still on disk, so Retry will run it "
            + "again without re-recording."
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}
