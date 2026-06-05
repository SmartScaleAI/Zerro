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
    /// Phase 17 — mode-switch confirmation. Fires in the dead time between
    /// `.processing` and the result when the (stubbed in Phase 17, real in
    /// Phase 18) detector thinks the user verbally asked for the opposite
    /// of the mode they selected on the overlay. `suggestedMode` is that
    /// opposite mode — the pill reads "Switch to [suggestedMode] for this
    /// one?" and offers a per-recording override. Same capsule chrome as
    /// `.processing`; resolved by Keep (use the selected mode) or Switch
    /// (use `suggestedMode` for this one generation only).
    case confirmSwitch(suggestedMode: OutputMode)
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
    /// Phase 17 confirm-pill resolutions. `onKeepMode` keeps the recording's
    /// selected mode (the safe default — also the effect of dismissing or
    /// ignoring the pill); `onSwitchMode` applies the suggested opposite
    /// mode to this one recording. Default no-ops so `#Preview` blocks can
    /// pass literal `.confirmSwitch` states without ceremony.
    var onKeepMode: () -> Void = {}
    var onSwitchMode: () -> Void = {}

    /// M2 recovery-pill resolutions — exactly two outcomes. `onRecoveryGenerate`
    /// runs the recovered recording (spends the credit, with consent);
    /// `onRecoveryDiscard` deletes it. Dismissing the pill by any other means
    /// also routes to Discard (wired in PillWindowController) — there is no
    /// leave-on-disk path. Default no-ops so `#Preview` blocks can pass a
    /// literal `.confirmRecovery` state without ceremony.
    var onRecoveryGenerate: () -> Void = {}
    var onRecoveryDiscard: () -> Void = {}

    /// The generated structured prompt, displayed in the .resultExpanded
    /// body. Threaded from AppState.generatedPrompt via PillWindowController
    /// so the pure-renderer PillView doesn't need to know about AppState.
    /// `nil` falls back to a placeholder so previews and the brief
    /// transition window (state flips to .done before the markdown view
    /// can re-render) don't render an empty card.
    var generatedPrompt: String? = nil

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
        // .confirmSwitch sizes to its content's natural width (it may widen
        // slightly to fit the mode name) while keeping the locked height —
        // see lockedCapsuleHeight. Per the locked mockup it stays one line.
        case .resultExpanded, .confirmSwitch, .confirmRecovery:
            return nil
        }
    }

    private var lockedCapsuleHeight: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .resultCompact, .confirmSwitch, .confirmRecovery:
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
                markdown: generatedPrompt ?? ResultPillContent.placeholderMarkdown,
                noNarration: resultHadNoNarration,
                stoppedBySleep: stoppedBySleep,
                onCopy: onCopy,
                onToggleExpand: onToggleExpand,
                onDismiss: onDismissResult
            )
        case .resultExpanded:
            ResultPillContent(
                expanded: true,
                markdown: generatedPrompt ?? ResultPillContent.placeholderMarkdown,
                noNarration: resultHadNoNarration,
                stoppedBySleep: stoppedBySleep,
                onCopy: onCopy,
                onToggleExpand: onToggleExpand,
                onDismiss: onDismissResult
            )
        case .error(let message, let retryable):
            ErrorPillContent(
                message: message,
                onRetry: retryable ? onRetryError : nil,
                onDismiss: onDismissError
            )
        case .confirmSwitch(let suggestedMode):
            ConfirmSwitchPillContent(
                suggestedMode: suggestedMode,
                onKeep: onKeepMode,
                onSwitch: onSwitchMode
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

// MARK: - ConfirmSwitchPillContent
//
// Phase 17 — the mode-switch confirmation, matching the approved Claude
// Design mockup. Reuses ProcessingPillContent's chrome geometry (locked
// capsule height, same vertical rhythm) so the morph out of `.processing`
// reads as the same pill changing its mind, not a new surface. Layout
// mirrors the recording pill: a left cluster (circular blue icon badge +
// bold question) and a right action cluster (secondary "Keep", primary
// blue "Switch"), separated by a Spacer so the buttons sit at the trailing
// edge. The pill is content-driven width (the Spacer's minLength fixes the
// airy gap) — it widens a touch for a longer mode name but stays one line
// and never changes height. Blue is `vfAccentBlue` (#0A84FF), the one
// locked saturated accent: the badge glyph and the primary fill.

private struct ConfirmSwitchPillContent: View {
    let suggestedMode: OutputMode
    let onKeep: () -> Void
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            iconBadge

            Text("Switch to \(suggestedMode.displayName) for this one?")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()

            // Airy gap between the question and the actions, pushing the
            // buttons to the trailing edge (per the mockup).
            Spacer(minLength: 120)

            keepButton
            switchButton
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    /// Double-arrow glyph in a soft blue disc — the mockup's left badge.
    private var iconBadge: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.vfAccentBlue)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.vfAccentBlue.opacity(0.20)))
    }

    private var keepButton: some View {
        Button(action: onKeep) {
            Text("Keep")
                // Matches the secondary text buttons across the other pill
                // steps (Cancel / View): 12pt regular, secondary tint.
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var switchButton: some View {
        Button(action: onSwitch) {
            Text("Switch")
                // Matches the primary filled buttons across the other pill
                // steps (Stop / Copy): 13pt semibold on a capsule fill.
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

// MARK: - ConfirmRecoveryPillContent
//
// M2 — the recovery confirmation, reusing ConfirmSwitchPillContent's chrome
// geometry (locked capsule height, content-driven width, left icon badge +
// question + trailing action cluster) so it reads as the same pill family. A
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
// (expanded == true). The header strip is identical between the two —
// green check, "Prompt ready", hero blue Copy button, expand/collapse
// chevron — only the chevron label and icon flip.
//
// In `.resultExpanded` this view adds the structured-prompt body below
// the header strip, and the Copy button moves into an overlay that
// punches the top edge of the body container. For `.resultCompact` the
// Copy button is fully contained within the pill — no overlay, no
// edge-punching.

private struct ResultPillContent: View {
    let expanded: Bool
    /// The structured Markdown prompt to render in the body. Threaded
    /// from AppState.generatedPrompt at the PillView level; falls back
    /// to `placeholderMarkdown` when the call site hasn't supplied one
    /// (previews; transient state windows).
    let markdown: String
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
    let onCopy: () -> Void
    let onToggleExpand: () -> Void
    /// Dismisses the result pill — wired to AppState.resetToIdle. Rendered
    /// as a circular close badge after the Hide/View toggle in the header
    /// strip, separated by a thin vertical hairline divider.
    let onDismiss: () -> Void

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
                // Bottom gutter matching the 20pt side gutters so the
                // chrome wraps the body card on all sides — otherwise the
                // body's dark fill runs flush to the pill's bottom edge.
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

    private var bodyContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if stoppedBySleep {
                stoppedBySleepNote
                Divider().overlay(Color.vfHairline)
            }
            if noNarration {
                noNarrationNote
                Divider().overlay(Color.vfHairline)
            }
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
        .padding(.horizontal, VFSpacing.xl)
        .padding(.vertical, VFSpacing.md)
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
        .padding(.horizontal, VFSpacing.xl)
        .padding(.vertical, VFSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview("Result \u{00B7} No narration") {
    PillView(state: .resultExpanded, resultHadNoNarration: true)
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

#Preview("Confirm \u{00B7} Switch to Explain") {
    // Selected mode was Instruct → the detected opposite is Explain.
    PillView(state: .confirmSwitch(suggestedMode: .explain))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Confirm \u{00B7} Switch to Instruct") {
    // Selected mode was Explain → the detected opposite is Instruct.
    PillView(state: .confirmSwitch(suggestedMode: .instruct))
        .padding(40)
        .background(Color.vfPanelBackground)
}
