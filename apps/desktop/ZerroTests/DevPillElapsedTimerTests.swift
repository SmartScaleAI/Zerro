//
//  DevPillElapsedTimerTests.swift
//  ZerroTests
//
//  The processing pill's live "· Xs" elapsed counter must stay alive across the
//  Dev Mode handoff. Ask mode keeps it for the whole request (it's baked
//  into `processingStageLabel`); Dev Mode hands `.processing` off to the
//  dispatch tail (`.devCheckpointing` → `.reviewingPrompt` →
//  `.devAgentDispatching` → `.devAgentRunning`), and the counter must follow —
//  continuous from generation start through the agent run, then disappear when
//  the `.devDone`/`.devFailed` card replaces the progress pill.
//
//  One continuous clock spans that whole window. `RecordingState.keepsElapsedTimer`
//  is its membership test (started on entry, stopped on exit, driven from
//  `state`'s `didSet`); `AppState.processingElapsedSuffix` is what the dev pill
//  appends via `PillStateBridge`. These tests pin both.
//

import XCTest
@testable import Zerro

@MainActor
final class DevPillElapsedTimerTests: XCTestCase {

    private static let middot = "\u{00B7}"

    // MARK: - keepsElapsedTimer membership

    func testKeepsElapsedTimerSpansProcessingAndDevTail() {
        // The continuous-clock window: generation + the dev dispatch tail.
        let keep: [RecordingState] = [
            .processing,
            .devCheckpointing,
            .reviewingPrompt,
            .devAgentDispatching,
            .devAgentRunning,
        ]
        for s in keep {
            XCTAssertTrue(s.keepsElapsedTimer, "\(s) must keep the elapsed clock")
        }
    }

    func testKeepsElapsedTimerExcludesTerminalAndRevertStates() {
        // Outside the window — the run is over (or never started): no clock.
        let drop: [RecordingState] = [
            .idle, .recording, .wrappingUp, .autoStopped, .done,
            .confirmingRecovery, .confirmingDevRecovery,
            .devReverting, .devDone, .devFailed,
        ]
        for s in drop {
            XCTAssertFalse(s.keepsElapsedTimer, "\(s) must NOT keep the elapsed clock")
        }
    }

    // MARK: - The counter follows the dev tail

    func testElapsedSuffixSurvivesTheHandoffAndWholeDevTail() {
        let app = AppState()

        // Generation: clock starts, suffix present.
        app.state = .processing
        XCTAssertNotNil(app.processingElapsedSuffix, "clock should run during .processing")

        // The handoff and every subsequent step keep the suffix — and the dev
        // progress label carries it (the "· Xs" the pill renders).
        for s: RecordingState in [.devCheckpointing, .reviewingPrompt,
                                  .devAgentDispatching, .devAgentRunning] {
            app.state = s
            XCTAssertNotNil(app.processingElapsedSuffix,
                            "\(s) must keep the elapsed suffix alive (no handoff reset)")
            // `.reviewingPrompt` renders its own card (no progress pill), so only
            // assert the label-carrying progress states.
            if case .devProgress(let label, _)? = app.pillState {
                XCTAssertTrue(label.contains(Self.middot),
                              "\(s) progress label must include the '· Xs' counter, got: \(label)")
            }
        }
    }

    // MARK: - The counter stops at the right moment

    func testElapsedSuffixGoesAwayWhenChangesAppliedCardShows() {
        let app = AppState()
        app.state = .processing
        app.state = .devAgentRunning
        XCTAssertNotNil(app.processingElapsedSuffix)

        // The agent finished — the "Changes applied" card replaces the progress
        // pill, and the clock stops in the same breath.
        app.state = .devDone
        XCTAssertNil(app.processingElapsedSuffix, "clock must stop when .devDone shows")
        if case .devDone? = app.pillState {} else {
            XCTFail("expected the .devDone result card")
        }
    }

    func testElapsedSuffixGoesAwayOnDevFailure() {
        let app = AppState()
        app.state = .processing
        app.state = .devAgentRunning
        app.state = .devFailed
        XCTAssertNil(app.processingElapsedSuffix, "clock must stop on .devFailed")
    }

    // MARK: - Reverting carries no timer

    func testRevertingProgressLabelHasNoCounter() {
        let app = AppState()
        // Reverting is reached after the run is over (Undo from the result card),
        // so the clock is already stopped and the label stays bare.
        app.state = .devReverting
        XCTAssertNil(app.processingElapsedSuffix)
        if case .devProgress(let label, let cancellable)? = app.pillState {
            XCTAssertFalse(label.contains(Self.middot),
                           "the Reverting label must not carry a '· Xs' counter, got: \(label)")
            XCTAssertFalse(cancellable, "Reverting is not cancellable")
        } else {
            XCTFail("expected a .devProgress pill for .devReverting")
        }
    }

    // MARK: - Ask mode is unchanged

    func testAskModeStopsCounterAtResult() {
        let app = AppState()
        app.state = .processing
        XCTAssertNotNil(app.processingElapsedSuffix)
        // A normal recording lands in `.done` (the clipboard result pill) — the
        // clock stops exactly as before.
        app.state = .done
        XCTAssertNil(app.processingElapsedSuffix, "ask mode must stop the clock at .done")
    }
}
