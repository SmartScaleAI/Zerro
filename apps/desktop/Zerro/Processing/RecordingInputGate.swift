//
//  RecordingInputGate.swift
//  Zerro
//
//  Layer 0 — the local "no input" gate. A cheap, pure check run BEFORE any
//  network/provider dispatch (and before the `generation_started` analytics
//  event) that answers one question: does this recording carry any on-device
//  signal a request could come from? When it doesn't — silent audio AND no
//  clicks — generation would be a guaranteed `ZERRO_NO_REQUEST`, so we skip it
//  entirely. That costs the user nothing (no provider call), and surfaces a
//  friendly "didn't catch that — nothing was charged" state instead of a
//  failure that looks like a billing event.
//
//  Why "no speech AND no clicks" has NO false negatives (never drops a real
//  request) — it's bounded to the model's own behavior, so we only short-circuit
//  a guaranteed no-op:
//   • `hasSpeech` is `AudioActivity`'s on-device RMS energy check, deliberately
//     biased toward `true` (any window above threshold, or any decode failure,
//     returns `true`). So `hasSpeech == false` means we're confident the clip is
//     silent.
//   • Normal mode carries the request in narration; with no narration the server
//     prompt's empty-narration rule already returns `ZERRO_NO_REQUEST`.
//   • Dev Mode resolves deixis/dwell anchors AROUND spoken phrases
//     (`DeixisResolver` windows on word timings), so with no speech there are no
//     anchors — the only remaining non-speech carrier of intent is the click
//     stream. "No speech AND no clicks" leaves the model nothing to act on.
//  Cursor dwell is intentionally NOT part of the condition: dwell is only
//  meaningful as a referent for a spoken phrase ("change this"), so it carries no
//  intent without speech.
//
//  Conservative by design. It does NOT try to catch the harder "spoke, but no
//  actionable request" case — that stays the server sentinel's job. Tightening to
//  also skip "no speech + clicks-only" or normal-mode "no speech regardless of
//  clicks" is a future change, not this one.
//
//  Design mirrors the sibling pure helpers (`AudioActivity`, `ProcessingConfig`):
//  a PURE function over primitives (`Bool`, `Int`) with no side effects and no
//  `AppState`/`ProcessedRecording` dependency, so its whole decision surface is
//  unit-testable with no fixtures. `nonisolated` (like `ProcessingConfig`) so it
//  opts out of the project's default MainActor isolation and can be called from
//  both the MainActor generation path and a nonisolated test.
//

nonisolated enum RecordingInputGate {

    /// True when a recording has no on-device signal a request could come from
    /// (silent audio AND no clicks), so dispatching generation would be a
    /// guaranteed `ZERRO_NO_REQUEST`. Skipping it avoids charging the user for an
    /// empty recording. Kept primitive (`Bool`/`Int`, not `ProcessedRecording`)
    /// so callers and tests don't have to build a full recording to exercise it.
    static func shouldSkipGeneration(hasSpeech: Bool, clickCount: Int) -> Bool {
        !hasSpeech && clickCount == 0
    }
}
