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
    /// A failed recording rendered as the shared failure card (same 760-wide
    /// chrome as `.failureExpanded`): the reason's short `headline` in bold on
    /// top, the `detail` sentence as wrapped prose below, and a Cancel + Retry
    /// footer. `retryable` selects the Retry action — when true the bridge wires
    /// it to re-run the API stage against the processed recording on disk; when
    /// false it falls back to reopening the screen-region selector to record
    /// again (the user fixes the underlying cause: Settings, free up disk, etc.).
    case error(headline: String, detail: String, retryable: Bool)
    /// M5 — a PAID-blocked failure (trial credits exhausted / out of credits /
    /// inactive subscription) that still has a held recording on disk. Rendered
    /// as the shared failure card (same 760-wide chrome as `.error` /
    /// `.failureExpanded`): the reason's `headline` on top, the paid-block
    /// `detail` below, and a Discard + primary footer. The primary's single
    /// action refreshes entitlement then resumes-or-paywalls; its LABEL reads
    /// "Upgrade" until the user is entitled and "Generate" after. `entitled`
    /// carries `EntitlementStore.canGenerate` so the label flips live (read in
    /// the bridge so Observation tracks it). Mapped from `.failed` by the bridge
    /// when `AppState.canResumePaidGeneration` is true.
    case paidBlockResume(headline: String, detail: String, entitled: Bool)
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

    // MARK: Dev Mode (Phase 1) — dispatch tail (design §8)

    /// Progress capsule for checkpointing → dispatching → agentRunning → (M7)
    /// reverting. `label` is the current substatus ("Checkpointing…", "editing
    /// App.css", "Reverting…"). `cancellable` shows the Cancel control on the
    /// in-flight dispatch states (a cancel triggers the safe terminate→revert)
    /// and hides it while reverting (interrupting a revert is unsafe).
    case devProgress(label: String, cancellable: Bool)
    /// Terminal success — the expandable result card (reusing `ArtifactCardView`
    /// in its dev-result configuration). `card` carries the title, the
    /// human-readable summary, and the readable git diff; `expanded` drives the
    /// compact summary pill ↔ full card morph (shares the result expand flag).
    /// Footer is a single "Undo" (reverts to the checkpoint); the X keeps the
    /// changes. No Retry, no Done.
    case devDone(card: DevResultCard, expanded: Bool)
    /// Terminal failure. `detail` is the single-line reason; `canRevert` gates
    /// the Revert button (a failure before the checkpoint has nothing to undo).
    /// Renders [Revert] + Retry (M7).
    case devFailed(detail: String, canRevert: Bool)
    /// Phase 2 (M6) — the low-confidence anchor confirm gate (§7/§8). Shows the
    /// resolved label(s) the agent will act on (low-confidence ones flagged) so a
    /// wrong anchor is catchable before any edit, with Confirm / Cancel.
    case confirmAnchors(anchors: [ConfirmAnchorRow])
}

/// One resolved-anchor row in the confirmAnchors card: the label the agent will
/// act on, and whether it's the low-confidence one the user most needs to check.
struct ConfirmAnchorRow: Equatable {
    let label: String
    let isLow: Bool
}

/// What the Dev Mode success card (`.devDone`) renders: the header `title`, the
/// human-readable `summary` (agent text or a generated fallback, decided in the
/// bridge), and the readable, pre-capped unified `diffText`. Assembled by
/// `AppState.devResultCard` so `PillView` stays a pure renderer.
struct DevResultCard: Equatable {
    let title: String
    let summary: String
    let diffText: String
    /// Diff stat counts for the COLLAPSED pill's "Changes applied (+a −r)" label.
    /// The EXPANDED card uses `summary`/`diffText` instead. Defaulted so literal
    /// `#Preview` constructions stay terse.
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var filesChanged: Int = 0
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
    /// The error pill's "Retry" when there's no re-runnable recording on disk
    /// (a non-retryable failure): dismisses the pill and reopens the screen-
    /// region selector to record again. Wired in `PillWindowController` to
    /// `AppState.retryRecordingFromRegion`. Default no-op for #Preview blocks.
    var onErrorRetryRegion: () -> Void = {}
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

    /// Dev Mode (M7) terminal-card actions. `onDevRevert` restores the working
    /// tree to the pre-run checkpoint (offered on `.devDone`, and on `.devFailed`
    /// when `canRevert`); `onDevRetry` re-dispatches the same prompt. The "Done"
    /// button and the failed card's dismiss reuse `onDismissResult` (reset to
    /// idle). Default no-ops so `#Preview` blocks can pass literal dev states.
    var onDevRevert: () -> Void = {}
    var onDevRetry: () -> Void = {}

    /// Dev Mode (M6) confirmAnchors actions: Confirm proceeds with the dispatch;
    /// Cancel aborts before the agent runs (safe teardown). Default no-ops.
    var onConfirmAnchors: () -> Void = {}
    var onDeclineAnchors: () -> Void = {}

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
        case .recording, .wrappingUp, .processing, .devProgress:
            return Self.capsuleWidth
        // `.error` and `.paidBlockResume` are now the 760-wide failure card
        // (content-driven, like `.failureExpanded`), not locked capsules.
        case .resultCompact, .resultExpanded, .failureExpanded, .confirmRecovery,
             .error, .paidBlockResume, .devDone, .devFailed, .confirmAnchors:
            return nil
        }
    }

    private var lockedCapsuleHeight: CGFloat? {
        switch state {
        case .recording, .wrappingUp, .processing, .resultCompact, .confirmRecovery,
             .devProgress:
            return Self.capsuleHeight
        // `.error` and `.paidBlockResume` are now the failure card: the title +
        // wrapped detail prose drive the card's own height (it grows down for a
        // long message instead of wrapping inside a fixed capsule).
        case .resultExpanded, .failureExpanded, .error, .paidBlockResume, .devFailed, .confirmAnchors:
            return nil
        // Compact dev-result is the locked-height summary capsule (like
        // .resultCompact); expanded is the content-driven card.
        case .devDone(_, let expanded):
            return expanded ? nil : Self.capsuleHeight
        }
    }

    fileprivate static let capsuleWidth: CGFloat = 440
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
        case .error(let headline, let detail, let retryable):
            // Same failure card as `.failureExpanded`, now with a Cancel + Retry
            // footer. The single primary action re-runs the API stage when the
            // failure is retryable, else reopens the screen-region selector to
            // record again (preserving the prior `onRetry ?? onRetryRegion`).
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
                failure: ArtifactCardView.FailureConfig(
                    headline: headline,
                    detail: detail,
                    secondaryTitle: "Cancel",
                    onSecondary: onDismissError,
                    primaryTitle: "Retry",
                    primaryIcon: "arrow.clockwise",
                    primaryRole: .warning
                ),
                onRetry: retryable ? onRetryError : onErrorRetryRegion
            )
            .frame(width: 760)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .paidBlockResume(let headline, let detail, let entitled):
            // Same failure card, Discard + (Upgrade/Generate) footer. The single
            // primary action refreshes entitlement then resumes-or-paywalls; its
            // label flips with `entitled`. Once entitled the card switches from
            // the amber paid-block warning to a blue "you're all set" success
            // confirmation (blue checkmark badge + blue Generate); Discard stays.
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
                failure: ArtifactCardView.FailureConfig(
                    headline: headline,
                    detail: detail,
                    secondaryTitle: "Discard",
                    onSecondary: onDismissError,
                    primaryTitle: entitled ? "Generate" : "Upgrade",
                    primaryIcon: nil,
                    primaryRole: entitled ? .reversible : .warning,
                    badgeTint: entitled ? .vfAccentBlue : .vfWarningAmber,
                    badgeSymbol: entitled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                ),
                onRetry: onResumePaidGeneration
            )
            .frame(width: 760)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        // Dev Mode (Phase 1) dispatch tail. Progress reuses the processing
        // capsule (Cancel hidden while reverting); the terminal states render
        // the full card with Revert/Done and Revert/Retry (Milestone 7).
        case .devProgress(let label, let cancellable):
            ProcessingPillContent(stepLabel: label, onCancel: cancellable ? onCancel : nil)
        case .devDone(let card, let expanded):
            // The Dev Mode result reuses the success card in its dev-result
            // configuration: a "Hide changes" toggle on top (no X), the summary +
            // readable diff, and the Undo/Accept footer. Expanded gets the same
            // 760-wide / clipped chrome as .resultExpanded; compact is the summary
            // pill (View changes / Undo / Accept) that expands to it.
            if expanded {
                ArtifactCardView(
                    artifact: nil,
                    chatText: "",
                    chargeLine: nil,
                    noNarration: false,
                    stoppedBySleep: false,
                    conversion: .hidden,
                    onCopy: {},
                    onCollapse: onToggleExpand,
                    onDismiss: onDismissResult,
                    onConvert: {},
                    devResult: ArtifactCardView.DevResultConfig(
                        title: card.title, summary: card.summary, diffText: card.diffText
                    ),
                    onUndo: onDevRevert
                )
                .frame(width: 760)
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                DevResultSummaryPill(
                    linesAdded: card.linesAdded,
                    linesRemoved: card.linesRemoved,
                    filesChanged: card.filesChanged,
                    onExpand: onToggleExpand,
                    onRevert: onDevRevert,
                    onDismiss: onDismissResult
                )
                // Same determinate-width treatment as `.resultCompact`: fixedSize
                // makes the capsule's width its ideal (content hug; the summary is
                // capped inside) so NSHostingView gets a determinate width instead
                // of a negotiable range that loops update-constraints.
                .fixedSize(horizontal: true, vertical: false)
            }
        case .devFailed(let detail, let canRevert):
            DevResultPillContent(
                symbol: "exclamationmark.triangle.fill",
                tint: .vfWarningAmber,
                text: detail,
                buttons: [
                    canRevert ? DevResultPillContent.Button(title: "Revert", role: .secondary, action: onDevRevert) : nil,
                    DevResultPillContent.Button(title: "Retry", role: .primary, action: onDevRetry),
                ].compactMap { $0 },
                // Keep the partial edits and close (no auto-revert, §8).
                onDismiss: onDismissResult
            )
        case .confirmAnchors(let anchors):
            ConfirmAnchorsPillContent(
                anchors: anchors,
                onConfirm: onConfirmAnchors,
                onCancel: onDeclineAnchors
            )
        }
    }

    private var cornerRadius: CGFloat {
        switch state {
        // The failure-card family (error / paid-block / generation-failure) all
        // share the 18pt card radius, not the 28pt capsule radius.
        case .resultExpanded, .failureExpanded, .error, .paidBlockResume:
            return 18
        case .devDone(_, let expanded):            return expanded ? 18 : 28
        default:                                    return 28
        }
    }
}

// MARK: - DevResultPillContent (Dev Mode — terminal failure capsule)
//
// The terminal dev-dispatch FAILURE capsule. `.devFailed` shows the failure
// reason with [Revert] (when a checkpoint exists) and [Retry], plus a dismiss
// "x" to keep the partial edits and close. A compact amber capsule (badge +
// reason + actions) so the dispatch tail reads as a continuation of the
// recording flow, not a separate surface. (`.devDone` no longer uses this — it
// renders the expandable `ArtifactCardView` dev-result card.)

private struct DevResultPillContent: View {
    /// One trailing action. `.primary` is filled (Retry); `.secondary`
    /// is a plain text button (Revert).
    struct Button: Identifiable {
        enum Role { case primary, secondary }
        let id = UUID()
        let title: String
        let role: Role
        let action: () -> Void
    }

    let symbol: String
    let tint: Color
    let text: String
    let buttons: [Button]
    /// The "x" affordance (keep & close). nil → no separate dismiss (a primary
    /// "Done" button already closes).
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: VFSpacing.md) {
            PillLeadingIconBadge(systemImage: symbol, tint: tint)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: VFSpacing.md)

            ForEach(buttons) { button in
                actionButton(button)
            }

            if let onDismiss {
                PillDismissButton(action: onDismiss)
            }
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
        .frame(maxWidth: PillView.capsuleWidth, minHeight: PillView.capsuleHeight)
    }

    /// `.primary` (Retry) is the filled positive button; `.secondary` (Revert)
    /// is the quiet gray-hover text button.
    @ViewBuilder
    private func actionButton(_ button: Button) -> some View {
        switch button.role {
        case .primary:
            PillPrimaryButton(title: button.title, role: .positive, action: button.action)
        case .secondary:
            PillSecondaryButton(title: button.title, action: button.action)
        }
    }
}

// MARK: - DevResultSummaryPill (Dev Mode result card — compact)
//
// The COLLAPSED form of the `.devDone` success card: green check + a fixed
// "Changes applied (+a −r)" label (the diff line counts — NOT the agent summary,
// which the expanded card keeps), then — on the right — a "View changes" expand
// toggle followed by the SAME destructive Undo + green Accept buttons the
// expanded footer shows (shared `DevUndoButton` / `DevAcceptButton`,
// compact-sized). No close X: Accept is the keep-and-close, Undo the revert.
// Expanding swaps in the full `ArtifactCardView` dev-result card.

private struct DevResultSummaryPill: View {
    let linesAdded: Int
    let linesRemoved: Int
    let filesChanged: Int
    let onExpand: () -> Void
    /// Undo → restore the pre-run checkpoint.
    let onRevert: () -> Void
    /// Accept → keep the changes and close (same close-and-keep as the expanded card).
    let onDismiss: () -> Void

    /// "Changes applied (+12 −3)". For a 0/0 stat (a non-line change) it never
    /// reads "(+0 −0)" — it falls back to the files-changed count, then to a bare
    /// "Changes applied". Matches the expanded header's "Changes applied" wording.
    private var label: String {
        if linesAdded > 0 || linesRemoved > 0 {
            return "Changes applied (+\(linesAdded) \u{2212}\(linesRemoved))"
        }
        if filesChanged > 0 {
            let files = filesChanged == 1 ? "1 file" : "\(filesChanged) files"
            return "Changes applied (\(files))"
        }
        return "Changes applied"
    }

    var body: some View {
        HStack(spacing: VFSpacing.xl) {
            HStack(spacing: VFSpacing.sm) {
                PillLeadingIconBadge(systemImage: "checkmark", tint: .vfSuccessGreen)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    // The label is short + fixed now, so it hugs (no truncation cap).
                    .fixedSize()
            }

            HStack(spacing: VFSpacing.sm) {
                expandToggle
                DevUndoButton(action: onRevert, compact: true)
                DevAcceptButton(action: onDismiss, compact: true)
            }
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
    }

    private var expandToggle: some View {
        Button(action: onExpand) {
            HStack(spacing: 4) {
                Text("View changes")
                    .font(.system(size: 12))
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.vfTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - ConfirmAnchorsPillContent (Dev Mode, Phase 2 — Milestone 6)
//
// The low-confidence anchor confirm gate (§7/§8). A checkpoint is already taken;
// the agent runs ONLY on Confirm. Shows the resolved label(s) the agent will act
// on so a wrong low-confidence anchor is catchable before any edit. Low-
// confidence rows are flagged amber (those are the ones to double-check).

private struct ConfirmAnchorsPillContent: View {
    let anchors: [ConfirmAnchorRow]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                PillLeadingIconBadge(systemImage: "scope", tint: .vfWarningAmber)
                Text("Edit these?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            // The resolved labels — low-confidence ones flagged so the user knows
            // which to scrutinize.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(anchors.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isLow ? "questionmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(row.isLow ? Color.vfWarningAmber : Color.vfTextSecondary)
                        Text(row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(row.isLow ? Color.vfTextPrimary : Color.vfTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            HStack(spacing: VFSpacing.sm) {
                Spacer(minLength: 0)
                PillSecondaryButton(title: "Cancel", action: onCancel)
                PillPrimaryButton(title: "Confirm", role: .positive, action: onConfirm)
            }
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, VFSpacing.md)
        .frame(maxWidth: PillView.capsuleWidth, minHeight: PillView.capsuleHeight)
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
            // the Cancel/Stop cluster to the trailing edge in both states.
            Spacer(minLength: VFSpacing.sm)

            // Keep Cancel and Stop tight together as one trailing button
            // cluster so they read as a pair rather than two stray controls.
            HStack(spacing: VFSpacing.sm) {
                PillSecondaryButton(title: "Cancel", action: onCancel)
                PillPrimaryButton(title: "Stop", systemImage: "stop.fill", role: .destructive, action: onStop)
            }
        }
        // Even 10pt inset on all four sides: the horizontal edge gap (left of
        // the record dot / right of the Stop button) now matches the vertical
        // gap above and below the Stop button, so the pill reads evenly padded.
        .padding(10)
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
    /// nil hides the Cancel control (e.g. the dev "Reverting…" state, where
    /// interrupting the restore is the unsafe case we're guarding against).
    let onCancel: (() -> Void)?

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

            if let onCancel { PillSecondaryButton(title: "Cancel", action: onCancel) }
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
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
            PillLeadingIconBadge(systemImage: "arrow.clockwise", tint: .vfAccentBlue)

            Text("Recording stopped \u{2014} generate a prompt from it?")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.vfTextPrimary)
                .fixedSize()

            Spacer(minLength: 40)

            PillSecondaryButton(title: "Discard", action: onDiscard)
            PillPrimaryButton(title: "Generate", role: .reversible, action: onGenerate)
        }
        .padding(.horizontal, VFSpacing.lg)
        .padding(.vertical, 10)
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
                    // within the locked capsule footprint). A negotiable
                    // 0…capsuleWidth range here (`.frame(maxWidth:)` on the chrome)
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
    /// title when one is attached (truncating inside the locked capsule width),
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
                // The amber badge carries the "heads up" signal in compact;
                // the expanded card spells it out in its no-narration note.
                PillLeadingIconBadge(
                    systemImage: noNarration ? "exclamationmark.triangle.fill" : "checkmark",
                    tint: noNarration ? .vfWarningAmber : .vfSuccessGreen
                )

                Text(compactLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Title cap = the locked capsule width minus the fixed
                    // chrome (paddings, check, spacings, View ⌄, divider,
                    // X). Capping HERE keeps the strip's ideal width
                    // determinate under the fixedSize above — short titles
                    // hug, long ones truncate at the cap.
                    .frame(maxWidth: 228, alignment: .leading)
            }

            HStack(spacing: VFSpacing.md) {
                expandToggle
                dismissDivider
                PillDismissButton(action: onDismiss)
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
    // A shorter failure — the card layout (title + elaborate detail + Cancel/
    // Retry), pulling both strings from the reason so the preview can't drift.
    PillView(state: .error(
        headline: RecordingFailureReason.captureInterrupted.headline,
        detail: RecordingFailureReason.captureInterrupted.detail,
        retryable: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Error \u{00B7} Long") {
    // The longest body — pulls the real copy from
    // `RecordingFailureReason.trialCreditsExhausted` (the source of truth in
    // AppState) rather than duplicating it, so the preview can't drift if the
    // copy changes. Exercises the full multi-line detail wrap in the card.
    PillView(state: .error(
        headline: RecordingFailureReason.trialCreditsExhausted.headline,
        detail: RecordingFailureReason.trialCreditsExhausted.detail,
        retryable: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Error \u{00B7} Retryable") {
    // Transient API failure — exercises the Retry-button affordance (re-runs
    // against the processed recording on disk). The detail copy says the
    // recording is saved and to press Retry.
    PillView(state: .error(
        headline: RecordingFailureReason.networkOffline.headline,
        detail: RecordingFailureReason.networkOffline.detail,
        retryable: true
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Paid block \u{00B7} Upgrade") {
    // M5 — paid-blocked failure, NOT yet entitled: the amber failure card with a
    // Discard + filled "Upgrade" footer (opens the paywall). Real copy from AppState.
    PillView(state: .paidBlockResume(
        headline: RecordingFailureReason.trialCreditsExhausted.headline,
        detail: RecordingFailureReason.trialCreditsExhausted.detail,
        entitled: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Paid block \u{00B7} Generate") {
    // M5 — once entitled, the card flips to the blue "you're all set"
    // confirmation: blue checkmark badge + blue "Generate" that resumes the held
    // recording. Copy mirrors the bridge's entitled branch.
    PillView(state: .paidBlockResume(
        headline: "You\u{2019}re all set",
        detail: "Your subscription is active and the recording you set aside is ready to generate. Pick up right where you left off.",
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

#Preview("Dev result \u{00B7} Expanded") {
    // The Dev Mode success card: human summary on top, the readable diff in the
    // body well, "Hide changes" up top (no X) + Undo/Accept footer. The expanded
    // card keeps the agent summary — the line counts drive the COLLAPSED pill only.
    PillView(state: .devDone(
        card: DevResultCard(
            title: "Changes applied",
            summary: "Reworked the Pulse login screen layout: moved \u{201C}Forgot "
                + "password?\u{201D} into the Sign In cluster and consolidated the social "
                + "auth buttons into a single dropdown.",
            diffText: """
            diff --git a/src/Login.css b/src/Login.css
            index 1a2b3c4..5d6e7f8 100644
            --- a/src/Login.css
            +++ b/src/Login.css
            @@ -12,7 +12,7 @@
             .login-form {
               display: flex;
            -  flex-direction: row;
            +  flex-direction: column;
               gap: 12px;
             }
            @@ -28,3 +28,8 @@
             .forgot-link {
            -  margin-top: 24px;
            +  margin-top: 8px;
            +  align-self: flex-end;
             }
            """,
            linesAdded: 3, linesRemoved: 2, filesChanged: 1
        ),
        expanded: true
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Dev result \u{00B7} Compact") {
    // Collapsed form — the fixed "Changes applied (+a −r)" counts pill that
    // expands to the card above. The agent summary is NOT shown here.
    PillView(state: .devDone(
        card: DevResultCard(
            title: "Changes applied",
            summary: "Reworked the login screen layout.",
            diffText: "",
            linesAdded: 12, linesRemoved: 3, filesChanged: 2
        ),
        expanded: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}

#Preview("Dev result \u{00B7} Compact (no line change)") {
    // 0/0 line stat (a non-line change, e.g. a rename/mode change): the pill
    // never reads "(+0 −0)" — it falls back to the files-changed count.
    PillView(state: .devDone(
        card: DevResultCard(
            title: "Changes applied",
            summary: "Renamed a file.",
            diffText: "",
            linesAdded: 0, linesRemoved: 0, filesChanged: 1
        ),
        expanded: false
    ))
        .padding(40)
        .background(Color.vfPanelBackground)
}
