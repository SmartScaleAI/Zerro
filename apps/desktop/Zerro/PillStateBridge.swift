//
//  PillStateBridge.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Single seam between the recording state machine (AppState) and the
//  pill renderer (PillView). The mapping is deliberately one-way:
//  AppState owns truth, the pill is a pure renderer that reads what
//  the bridge produces. Elapsed-seconds-to-"M:SS" formatting and the
//  6-case → 5-case collapse (`.autoStopped` reuses `.wrappingUp`'s
//  visual) live here so PillView never has to know about RecordingState.
//

import SwiftUI

// MARK: - ResultPresentation

/// The result pill's render model (Phase 5 of the typed-artifact refactor):
/// chat text and the optional typed artifact it introduces. Assembled by
/// `AppState.resultPresentation` from the parsed response so `PillView`
/// stays a pure renderer — it never sees `ParsedResponse`'s parse
/// bookkeeping (validity, recovery, warnings), only what gets drawn.
struct ResultPresentation: Equatable {
    /// Conversational text rendered above the card. Never nil — a parse
    /// fail-safe degrades the whole raw output into this. May be empty when
    /// the model led straight into an artifact.
    let chatText: String
    /// The typed artifact, when one was attached. nil → chat-only layout
    /// (no card).
    let artifact: Artifact?

    /// Neutral, content-free presentation. Used by `PillView` as the
    /// production fallback when `result` is briefly nil during teardown
    /// (the `.done → .idle` frame, before the window orders out) so the
    /// pill renders an EMPTY card rather than substituting heavyweight
    /// sample content. The rich sample lives in
    /// `ResultPillContent.placeholderResult`, which is preview-only.
    static let empty = ResultPresentation(chatText: "", artifact: nil)
}

extension AppState {

    /// `nil` means the pill window should be hidden.
    var pillState: PillState? {
        switch state {
        case .idle:
            return nil

        case .recording:
            return .recording(elapsed: elapsedDisplay, totalDisplay: totalDisplay)

        case .wrappingUp, .autoStopped:
            return .wrappingUp(elapsed: elapsedDisplay, totalDisplay: totalDisplay)

        case .processing:
            return .processing(stepLabel: processingStageLabel)

        case .confirmingRecovery:
            // M2 (rev 3) — the sleep-interrupted-recording recovery offer.
            return .confirmRecovery

        case .done:
            return isResultExpanded ? .resultExpanded : .resultCompact

        case .failed(let reason):
            // Retryable failures get the expanded card so the user can read
            // the real error and retry from there; everything else keeps the
            // compact amber capsule unchanged. `canRetryFailure` is re-evaluated
            // on every render, so a retry that exhausts the cap degrades to the
            // small pill (no Retry button) on the next pass.
            if canRetryFailure {
                return .failureExpanded(
                    headline: reason.headline,
                    detail: lastFailureDetail ?? reason.detail
                )
            }
            // M5: a paid-blocked failure (trial credits exhausted / out of
            // credits / inactive subscription) with a held recording gets the
            // dedicated resume pill so the user can pay and continue the SAME
            // recording. `entitled` is read from the entitlement store HERE so
            // Observation tracks it — when the user activates a license and
            // entitlement flips to `.byok`/`.managed`, the primary button's label
            // re-renders from "Upgrade" to "Generate" without any extra plumbing.
            if canResumePaidGeneration {
                // Once the user is entitled (subscription active / credits added),
                // the held recording is ready — flip from the amber paid-block
                // warning to a calm blue "you're all set" confirmation (themed in
                // PillView off `entitled`). Discard stays as the secondary.
                let entitled = entitlements?.canGenerate == true
                if entitled {
                    return .paidBlockResume(
                        headline: "You\u{2019}re all set",
                        detail: "Your subscription is active and the recording you set aside is ready to generate. Pick up right where you left off.",
                        entitled: true
                    )
                }
                return .paidBlockResume(
                    headline: reason.headline,
                    detail: reason.detail,
                    entitled: false
                )
            }
            return .error(headline: reason.headline, detail: reason.detail, retryable: false)

        // Dev Mode (Phase 1) — the dispatch tail. Reached only for a Dev Mode
        // recording; normal mode never produces these.
        case .devCheckpointing:
            return .devProgress(label: "Checkpointing\u{2026}", cancellable: true)
        case .devAgentDispatching:
            return .devProgress(label: "Dispatching to the agent\u{2026}", cancellable: true)
        case .devAgentRunning:
            return .devProgress(label: devRunSubstatus?.label ?? "Working\u{2026}", cancellable: true)
        case .devReverting:
            // Restoring the tree — not cancellable (interrupting a revert is the
            // dangerous case we're guarding against).
            return .devProgress(label: "Reverting\u{2026}", cancellable: false)
        case .confirmAnchors:
            // M6 — the low-confidence anchor confirm gate. Show the resolved
            // labels (low ones flagged) so a wrong anchor is catchable.
            return .confirmAnchors(anchors: devConfirmAnchorSummaries.map {
                ConfirmAnchorRow(label: $0.label, isLow: $0.isLow)
            })
        case .devDone:
            // The expandable dev-result card: human summary on top, the readable
            // diff in the body well, Undo + X. Shares the result expand flag (the
            // two states never coexist); lands expanded (set in applyDevOutcome).
            return .devDone(card: devResultCard, expanded: isResultExpanded)
        case .devFailed:
            // Offer Revert only when a checkpoint exists (failures before the
            // checkpoint — non-git folder, missing agent — have nothing to undo).
            return .devFailed(detail: devFailure?.userMessage ?? "Dev Mode run failed.",
                              canRevert: devCanRevert)
        }
    }

    /// The `.devDone` success card's render model: a fixed title, the summary
    /// (agent text when present, else a generated change line), the readable diff
    /// text, and the diff stat counts (the collapsed pill renders "Changes applied
    /// (+a −r)" from these; the expanded card uses summary/diffText).
    var devResultCard: DevResultCard {
        DevResultCard(
            title: "Changes applied",
            summary: devResultSummary,
            diffText: devDiffText ?? "",
            linesAdded: devDiffStat?.added ?? 0,
            linesRemoved: devDiffStat?.removed ?? 0,
            filesChanged: devDiffStat?.filesChanged ?? 0
        )
    }

    /// The dev-result summary shown in the card's text region (and, collapsed to
    /// one line, in the compact pill): the agent's own summary when it gave one,
    /// otherwise a generated fallback from the diff stat ("Updated N files (+x −y)").
    var devResultSummary: String {
        if let summary = devSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        guard let stat = devDiffStat, stat.filesChanged > 0 else { return "Changes applied." }
        let files = stat.filesChanged == 1 ? "1 file" : "\(stat.filesChanged) files"
        return "Updated \(files) (+\(stat.added) \u{2212}\(stat.removed))."
    }
}

extension PillState {

    /// Spring tuned per the wrap-up: result morph is the visible one
    /// (corner radius 28 → 18, body slide-in), so it gets a slightly
    /// softer spring than the recording/wrappingUp/processing capsule
    /// shuffle.
    static func morphAnimation(from old: PillState?, to new: PillState?) -> Animation {
        if Self.isResult(old) || Self.isResult(new) {
            return .spring(response: 0.20, dampingFraction: 0.82)
        }
        return .spring(response: 0.16, dampingFraction: 0.85)
    }

    private static func isResult(_ state: PillState?) -> Bool {
        switch state {
        // `.failureExpanded` and the dev-result card (`.devDone`) are the same big
        // card morph as the result states, so they get the softer result spring too.
        case .resultCompact?, .resultExpanded?, .failureExpanded?, .devDone?: return true
        default: return false
        }
    }
}
