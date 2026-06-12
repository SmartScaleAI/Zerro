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
            return .error(message: reason.userMessage, retryable: canRetryFailure)
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
        case .resultCompact?, .resultExpanded?: return true
        default: return false
        }
    }
}
