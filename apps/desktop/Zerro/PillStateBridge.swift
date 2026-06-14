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
                    headline: "Generation failed",
                    detail: lastFailureDetail ?? reason.userMessage
                )
            }
            return .error(message: reason.userMessage, retryable: false)
        }
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
        // `.failureExpanded` is the same big card morph as the result states,
        // so it gets the softer result spring too.
        case .resultCompact?, .resultExpanded?, .failureExpanded?: return true
        default: return false
        }
    }
}
