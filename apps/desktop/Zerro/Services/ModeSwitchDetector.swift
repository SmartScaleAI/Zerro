//
//  ModeSwitchDetector.swift
//  Zerro
//
//  Created by Colin Breeding on 5/31/26.
//
//  Phase 17 — the seam for catching the case where the user verbally asks
//  for the opposite output mode from the one they selected on the overlay
//  (e.g. picked Instruct, then narrated "actually, just explain this").
//  When matched, AppState pauses before prompt composition and shows the
//  confirmation pill (PillState.confirmSwitch) so the user can accept a
//  per-recording override or keep their selection.
//
//  This phase ships the FINAL signature with a no-op stub so the whole
//  pill flow is wired and testable now. Phase 18 fills in the real
//  string-match detection behind the same signature — it only supplies the
//  predicate that decides whether to show the pill, with zero changes to
//  the override plumbing in AppState.
//

import Foundation

/// The outcome of a mode-switch intent check.
struct ModeSwitchDetection: Equatable {
    /// True when the narration appears to ask for a different output mode
    /// than the one selected on the overlay.
    let didMatch: Bool

    /// The mode the user appears to be asking for — the opposite of the
    /// selected mode. `nil` whenever `didMatch` is false.
    let suggestedMode: OutputMode?

    /// The canonical "nothing detected" result. The Phase 17 stub always
    /// returns this; Keep / dismiss / inaction all resolve to it too.
    static let noMatch = ModeSwitchDetection(didMatch: false, suggestedMode: nil)
}

enum ModeSwitchDetector {

    /// Inspects the narration for an explicit request to switch output
    /// modes mid-recording, returning the opposite mode to suggest when
    /// matched.
    ///
    /// - Parameters:
    ///   - transcript: the full narration text (raw speech).
    ///   - selectedMode: the mode chosen on the overlay for this recording.
    /// - Returns: `.noMatch` in Phase 17.
    ///
    /// DEFERRED Phase 18: real string-match detection. The implementation
    /// will scan `transcript` for a direct, explicit opposite-mode request
    /// (the base prompt's OUTPUT MODE rule describes the same bar) and
    /// return `.init(didMatch: true, suggestedMode: selectedMode.opposite)`
    /// on a hit. Until then this always returns `.noMatch`; the pill flow
    /// is exercised via the debug manual trigger
    /// (`AppState.debugForceModeSwitchPill`).
    static func detect(transcript: String, selectedMode: OutputMode) -> ModeSwitchDetection {
        // DEFERRED Phase 18: real string-match detection.
        .noMatch
    }
}
